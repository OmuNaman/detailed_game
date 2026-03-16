extends Node
## Calls Gemini 2.5 Flash for NPC dialogue generation.
## Parallel request pool (3 concurrent) for 61-NPC throughput.

const MODEL: String = "gemini-2.5-flash"
const MODEL_LITE: String = "gemini-2.5-flash-lite"
const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"
const MAX_CONCURRENT: int = 3

var _api_key: String = ""
var _request_queue: Array[Dictionary] = []  # {system, message, callback, model}
var _http_pool: Array[HTTPRequest] = []
var _active_requests: Dictionary = {}  # {HTTPRequest: Dictionary (queue entry)}

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

	# Create pool of HTTPRequest nodes for parallel requests
	for i: int in range(MAX_CONCURRENT):
		var http := HTTPRequest.new()
		http.timeout = 5.0
		http.name = "HTTPRequest_%d" % i
		add_child(http)
		http.request_completed.connect(_on_request_completed.bind(http))
		_http_pool.append(http)


func has_api_key() -> bool:
	return _api_key != ""


func generate(system_prompt: String, user_message: String, callback: Callable, model_override: String = "") -> void:
	## Queue a generation request. Callback receives (response_text: String, success: bool).
	## Optional model_override to use a different model (e.g., MODEL_LITE for analysis).
	if _api_key == "":
		callback.call("", false)
		return
	var model: String = model_override if model_override != "" else MODEL
	_request_queue.append({"system": system_prompt, "message": user_message, "callback": callback, "model": model})
	_process_queue()


func _process_queue() -> void:
	## Fire up to MAX_CONCURRENT requests simultaneously.
	while not _request_queue.is_empty() and _active_requests.size() < MAX_CONCURRENT:
		# Find a free HTTPRequest node
		var free_http: HTTPRequest = null
		for http: HTTPRequest in _http_pool:
			if not _active_requests.has(http):
				free_http = http
				break
		if free_http == null:
			break

		var req: Dictionary = _request_queue.pop_front()
		_active_requests[free_http] = req

		var model: String = req.get("model", MODEL)
		var url: String = API_URL + model + ":generateContent?key=" + _api_key
		var gen_config: Dictionary = {"maxOutputTokens": 256, "temperature": 0.8}
		if model == MODEL:
			gen_config["thinkingConfig"] = {"thinkingBudget": 0}
		var body: Dictionary = {
			"contents": [{"parts": [{"text": req["message"]}]}],
			"systemInstruction": {"parts": [{"text": req["system"]}]},
			"generationConfig": gen_config,
		}
		var json_body: String = JSON.stringify(body)
		var headers: PackedStringArray = ["Content-Type: application/json"]

		total_input_tokens += (req["system"].length() + req["message"].length()) / 4
		total_requests += 1

		var err: Error = free_http.request(url, headers, HTTPClient.METHOD_POST, json_body)
		if err != OK:
			push_warning("GeminiClient: HTTP request failed: %s" % error_string(err))
			_active_requests.erase(free_http)
			req["callback"].call("", false)
			continue


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	if not _active_requests.has(http):
		return
	var req: Dictionary = _active_requests[http]
	_active_requests.erase(http)

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


static func parse_json_response(text: String) -> Variant:
	## Parse JSON from Gemini response, stripping markdown fences if present.
	var cleaned: String = text.strip_edges()
	if cleaned.begins_with("```"):
		var first_newline: int = cleaned.find("\n")
		if first_newline >= 0:
			cleaned = cleaned.substr(first_newline + 1)
		if cleaned.ends_with("```"):
			cleaned = cleaned.left(cleaned.length() - 3).strip_edges()
	var json := JSON.new()
	if json.parse(cleaned) == OK:
		return json.data
	return null
