extends Node
## Calls Gemini gemini-embedding-001 to embed text into 768-dim vectors.
## Falls back gracefully if API unavailable. Serializes requests via queue.

const MODEL: String = "gemini-embedding-001"
const API_URL: String = "https://generativelanguage.googleapis.com/v1beta/models/"
const EMBEDDING_DIM: int = 768

var _api_key: String = ""
var _http: HTTPRequest
var _http_batch: HTTPRequest
var _pending_callbacks: Array[Callable] = []
var _request_queue: Array[Dictionary] = []  # {text: String, callback: Callable}
var _is_requesting: bool = false
var _batch_queue: Array[Dictionary] = []  # {texts: Array[String], callback: Callable}
var _is_batch_requesting: bool = false
var _pending_batch_callback: Callable


func _ready() -> void:
	_load_api_key()
	_http = HTTPRequest.new()
	add_child(_http)
	_http.request_completed.connect(_on_request_completed)
	_http_batch = HTTPRequest.new()
	add_child(_http_batch)
	_http_batch.request_completed.connect(_on_batch_request_completed)


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


# --- Batch Embedding ---

func embed_batch(texts: Array[String], callback: Callable) -> void:
	## Embeds multiple texts in one API call. Callback receives Array[PackedFloat32Array].
	## Falls back to empty arrays if API unavailable.
	if _api_key == "" or texts.is_empty():
		var empty_results: Array[PackedFloat32Array] = []
		for _i: int in range(texts.size()):
			empty_results.append(PackedFloat32Array())
		callback.call(empty_results)
		return

	_batch_queue.append({"texts": texts, "callback": callback})
	if not _is_batch_requesting:
		_process_next_batch()


func _process_next_batch() -> void:
	if _batch_queue.is_empty():
		_is_batch_requesting = false
		return

	_is_batch_requesting = true
	var item: Dictionary = _batch_queue.pop_front()
	var texts: Array = item["texts"]
	_pending_batch_callback = item["callback"]

	var url: String = API_URL + MODEL + ":batchEmbedContents?key=" + _api_key
	var requests: Array[Dictionary] = []
	for text: String in texts:
		requests.append({
			"model": "models/" + MODEL,
			"content": {"parts": [{"text": text}]},
			"outputDimensionality": EMBEDDING_DIM,
		})
	var body: Dictionary = {"requests": requests}
	var json_body: String = JSON.stringify(body)
	var headers: PackedStringArray = ["Content-Type: application/json"]
	var err: Error = _http_batch.request(url, headers, HTTPClient.METHOD_POST, json_body)
	if err != OK:
		push_warning("EmbeddingClient: Batch HTTP request failed: %s" % error_string(err))
		var empty_results: Array[PackedFloat32Array] = []
		for _i: int in range(texts.size()):
			empty_results.append(PackedFloat32Array())
		_pending_batch_callback.call(empty_results)
		_process_next_batch()


func _on_batch_request_completed(_result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if not _pending_batch_callback.is_valid():
		_process_next_batch()
		return

	var cb: Callable = _pending_batch_callback

	if code != 200:
		push_warning("EmbeddingClient: Batch API returned %d" % code)
		cb.call([] as Array[PackedFloat32Array])
		_process_next_batch()
		return

	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_warning("EmbeddingClient: Failed to parse batch response")
		cb.call([] as Array[PackedFloat32Array])
		_process_next_batch()
		return

	# Response format: {"embeddings": [{"values": [...]}, {"values": [...]}, ...]}
	var embeddings_data: Array = json.data.get("embeddings", [])
	var results: Array[PackedFloat32Array] = []
	for entry: Variant in embeddings_data:
		if entry is Dictionary:
			var values: Array = (entry as Dictionary).get("values", [])
			var emb := PackedFloat32Array()
			emb.resize(values.size())
			for i: int in range(values.size()):
				emb[i] = values[i]
			results.append(emb)
		else:
			results.append(PackedFloat32Array())

	cb.call(results)
	_process_next_batch()
