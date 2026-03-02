extends Node
## Calls Gemini gemini-embedding-001 to embed text into 768-dim vectors.
## Falls back gracefully if API unavailable. Serializes requests via queue.

const MODEL: String = "gemini-embedding-001"
const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"
const EMBEDDING_DIM: int = 768

var _api_key: String = ""
var _http: HTTPRequest
var _pending_callbacks: Array[Callable] = []
var _request_queue: Array[Dictionary] = []  # {text: String, callback: Callable}
var _is_requesting: bool = false


func _ready() -> void:
	_load_api_key()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)


func _load_api_key() -> void:
	var file := FileAccess.open("user://.env", FileAccess.READ)
	if file:
		_api_key = file.get_line().strip_edges()
		if _api_key != "":
			print("[EmbeddingClient] API key loaded from user://.env")
		else:
			push_warning("EmbeddingClient: .env file is empty — embeddings disabled")
	else:
		push_warning("EmbeddingClient: No API key found at user://.env — embeddings disabled")


func has_api_key() -> bool:
	return _api_key != ""


func embed_text(text: String, callback: Callable) -> void:
	## Embeds text and calls callback(embedding: PackedFloat32Array).
	## If no API key or request fails, callback receives empty PackedFloat32Array().
	if _api_key == "":
		callback.call(PackedFloat32Array())
		return

	# Queue the request
	_request_queue.append({"text": text, "callback": callback})

	# Process immediately if nothing in flight
	if not _is_requesting:
		_process_next_request()


func _process_next_request() -> void:
	if _request_queue.is_empty():
		_is_requesting = false
		return

	_is_requesting = true
	var item: Dictionary = _request_queue.pop_front()
	var text: String = item["text"]
	var callback: Callable = item["callback"]
	_pending_callbacks.append(callback)

	var url: String = API_URL + MODEL + ":embedContent?key=" + _api_key
	var body: Dictionary = {
		"model": "models/" + MODEL,
		"content": {"parts": [{"text": text}]},
		"outputDimensionality": EMBEDDING_DIM,
	}
	var json_body: String = JSON.stringify(body)
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var err: Error = _http.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_warning("EmbeddingClient: HTTP request failed: %s" % error_string(err))
		if not _pending_callbacks.is_empty():
			var cb: Callable = _pending_callbacks.pop_back()
			cb.call(PackedFloat32Array())
		# Try next in queue
		_process_next_request()


func _on_request_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if _pending_callbacks.is_empty():
		_process_next_request()
		return

	var cb: Callable = _pending_callbacks.pop_front()

	if code != 200:
		push_warning("EmbeddingClient: API returned %d" % code)
		cb.call(PackedFloat32Array())
		_process_next_request()
		return

	var json := JSON.new()
	var parse_err: Error = json.parse(body.get_string_from_utf8())
	if parse_err != OK:
		push_warning("EmbeddingClient: Failed to parse response")
		cb.call(PackedFloat32Array())
		_process_next_request()
		return

	# Response format: {"embedding": {"values": [0.1, 0.2, ...]}}
	var values: Array = json.data.get("embedding", {}).get("values", [])
	if values.is_empty():
		push_warning("EmbeddingClient: No embedding values in response")
		cb.call(PackedFloat32Array())
		_process_next_request()
		return

	var embedding := PackedFloat32Array()
	embedding.resize(values.size())
	for i: int in range(values.size()):
		embedding[i] = values[i]

	cb.call(embedding)

	# Process next queued request
	_process_next_request()
