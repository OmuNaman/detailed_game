extends Node
## Calls Gemini 2.5 Flash for NPC dialogue generation.
## Falls back gracefully if API unavailable. Serializes requests via queue.

const MODEL: String = "gemini-2.5-flash"
const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"

var _api_key: String = ""
var _http: HTTPRequest
var _request_queue: Array[Dictionary] = []  # {system, message, callback}
var _is_requesting: bool = false

# Cost tracking
var total_input_tokens: int = 0
var total_output_tokens: int = 0
var total_requests: int = 0


func _ready() -> void:
	var file := FileAccess.open("user://.env", FileAccess.READ)
	if file:
		_api_key = file.get_line().strip_edges()
		if _api_key != "":
			print("[GeminiClient] API key loaded from user://.env")
		else:
			push_warning("GeminiClient: .env file is empty — dialogue generation disabled")
	else:
		push_warning("GeminiClient: No API key found at user://.env — dialogue generation disabled")

	_http = HTTPRequest.new()
	_http.timeout = 5.0
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func has_api_key() -> bool:
	return _api_key != ""


func generate(system_prompt: String, user_message: String, callback: Callable) -> void:
	## Queue a generation request. Callback receives (response_text: String, success: bool).
	if _api_key == "":
		callback.call("", false)
		return
	_request_queue.append({"system": system_prompt, "message": user_message, "callback": callback})
	if not _is_requesting:
		_process_queue()


func _process_queue() -> void:
	if _is_requesting or _request_queue.is_empty():
		return
	_is_requesting = true
	var req: Dictionary = _request_queue[0]

	var url: String = API_URL + MODEL + ":generateContent?key=" + _api_key
	var body: Dictionary = {
		"contents": [{"parts": [{"text": req["message"]}]}],
		"systemInstruction": {"parts": [{"text": req["system"]}]},
		"generationConfig": {"maxOutputTokens": 256, "temperature": 0.8, "thinkingConfig": {"thinkingBudget": 0}}
	}
	var json_body: String = JSON.stringify(body)
	var headers: PackedStringArray = ["Content-Type: application/json"]

	# Estimate input tokens for cost tracking
	total_input_tokens += (req["system"].length() + req["message"].length()) / 4
	total_requests += 1

	var err: Error = _http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_warning("GeminiClient: HTTP request failed: %s" % error_string(err))
		_is_requesting = false
		var failed_req: Dictionary = _request_queue.pop_front()
		failed_req["callback"].call("", false)
		_process_queue()


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	_is_requesting = false
	if _request_queue.is_empty():
		return
	var req: Dictionary = _request_queue.pop_front()

	if code != 200 or result != HTTPRequest.RESULT_SUCCESS:
		push_warning("GeminiClient: API error %d (result: %d)" % [code, result])
		req["callback"].call("", false)
		_process_queue()
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_warning("GeminiClient: Failed to parse response")
		req["callback"].call("", false)
		_process_queue()
		return

	var text: String = ""
	var candidates: Array = json.data.get("candidates", [])
	if not candidates.is_empty():
		var parts: Array = candidates[0].get("content", {}).get("parts", [])
		if not parts.is_empty():
			text = parts[0].get("text", "")
			total_output_tokens += text.length() / 4

	req["callback"].call(text.strip_edges(), text != "")
	_process_queue()
