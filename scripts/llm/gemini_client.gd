extends Node
## Calls Gemini 2.5 Flash for NPC dialogue generation.
## 2 concurrent pool for NPC traffic + 1 dedicated player node for instant response.

const MODEL: String = "gemini-2.5-flash"
const MODEL_LITE: String = "gemini-2.5-flash-lite"
const MODEL_PRO: String = "gemini-2.5-pro"
const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"
const MAX_CONCURRENT: int = 2

var _api_key: String = ""
var _request_queue: Array[Dictionary] = []
var _http_pool: Array[HTTPRequest] = []
var _active_requests: Dictionary = {}

# Dedicated player dialogue node — bypasses the queue entirely
var _player_http: HTTPRequest
var _player_request: Dictionary = {}

# Throttle: minimum delay between dispatching requests
var _last_dispatch_time: int = 0

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

	# NPC request pool (2 concurrent)
	for i: int in range(MAX_CONCURRENT):
		var http := HTTPRequest.new()
		http.timeout = 15.0
		http.body_size_limit = -1  # Unlimited — fixes result:13
		http.name = "HTTPRequest_%d" % i
		add_child(http)
		http.request_completed.connect(_on_request_completed.bind(http))
		_http_pool.append(http)

	# Dedicated player dialogue node (never queued)
	_player_http = HTTPRequest.new()
	_player_http.timeout = 15.0
	_player_http.body_size_limit = -1
	_player_http.name = "PlayerHTTPRequest"
	add_child(_player_http)
	_player_http.request_completed.connect(_on_player_request_completed)


func has_api_key() -> bool:
	return _api_key != ""


func generate(system_prompt: String, user_message: String, callback: Callable, model_override: String = "") -> void:
	if _api_key == "":
		callback.call("", false)
		return
	var model: String = model_override if model_override != "" else MODEL
	_request_queue.append({"system": system_prompt, "message": user_message, "callback": callback, "model": model, "retries": 0})
	_process_queue()


func generate_priority(system_prompt: String, user_message: String, callback: Callable, model_override: String = "") -> void:
	## Send immediately on dedicated player HTTP node — bypasses queue.
	if _api_key == "":
		callback.call("", false)
		return
	var model: String = model_override if model_override != "" else MODEL
	var req: Dictionary = {"system": system_prompt, "message": user_message, "callback": callback, "model": model, "retries": 0}
	if _player_request.is_empty():
		_send_request_on(_player_http, req)
		_player_request = req
	else:
		_request_queue.push_front(req)
		_process_queue()


func _process_queue() -> void:
	# Throttle: at least 200ms between dispatches to avoid hammering
	var now_ms: int = Time.get_ticks_msec()
	if now_ms - _last_dispatch_time < 200 and not _request_queue.is_empty():
		# Schedule retry shortly
		if not _request_queue.is_empty():
			get_tree().create_timer(0.2).timeout.connect(_process_queue, CONNECT_ONE_SHOT)
		return

	while not _request_queue.is_empty() and _active_requests.size() < MAX_CONCURRENT:
		var free_http: HTTPRequest = null
		for http: HTTPRequest in _http_pool:
			if not _active_requests.has(http):
				free_http = http
				break
		if free_http == null:
			break

		var req: Dictionary = _request_queue.pop_front()
		_active_requests[free_http] = req
		_last_dispatch_time = Time.get_ticks_msec()
		_send_request_on(free_http, req)


func _send_request_on(http: HTTPRequest, req: Dictionary) -> void:
	var model: String = req.get("model", MODEL)
	var url: String = API_URL + model + ":generateContent?key=" + _api_key
	var gen_config: Dictionary = {"maxOutputTokens": 256, "temperature": 0.8}
	var body: Dictionary = {
		"contents": [{"parts": [{"text": req["message"]}]}],
		"systemInstruction": {"parts": [{"text": req["system"]}]},
		"generationConfig": gen_config,
	}
	var json_body: String = JSON.stringify(body)
	var headers: PackedStringArray = ["Content-Type: application/json"]

	total_input_tokens += (req["system"].length() + req["message"].length()) / 4
	total_requests += 1

	var err: Error = http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_warning("GeminiClient: HTTP request failed: %s" % error_string(err))
		_active_requests.erase(http)
		req["callback"].call("", false)


func _on_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray, http: HTTPRequest) -> void:
	if not _active_requests.has(http):
		return
	var req: Dictionary = _active_requests[http]
	_active_requests.erase(http)

	# Retry on 503 (rate limit) — once, after 2 seconds
	if code == 503 and req.get("retries", 0) < 1:
		req["retries"] = req.get("retries", 0) + 1
		push_warning("GeminiClient: 503 rate limit, retrying in 2s...")
		get_tree().create_timer(2.0).timeout.connect(func() -> void:
			_request_queue.push_front(req)
			_process_queue()
		)
		return

	if code != 200 or result != HTTPRequest.RESULT_SUCCESS:
		push_warning("GeminiClient: API error %d (result: %d)" % [code, result])
		req["callback"].call("", false)
		_process_queue()
		return

	var text: String = _extract_text(body)
	req["callback"].call(text, text != "")
	_process_queue()


func _on_player_request_completed(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _player_request.is_empty():
		return
	var req: Dictionary = _player_request
	_player_request = {}

	if code != 200 or result != HTTPRequest.RESULT_SUCCESS:
		push_warning("GeminiClient: Player API error %d (result: %d)" % [code, result])
		req["callback"].call("", false)
		return

	var text: String = _extract_text(body)
	req["callback"].call(text, text != "")


func _extract_text(body: PackedByteArray) -> String:
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		return ""
	var candidates: Array = json.data.get("candidates", [])
	if candidates.is_empty():
		return ""
	var parts: Array = candidates[0].get("content", {}).get("parts", [])
	if parts.is_empty():
		return ""
	var text: String = parts[0].get("text", "")
	total_output_tokens += text.length() / 4
	return text.strip_edges()


static func parse_json_response(text: String) -> Variant:
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
