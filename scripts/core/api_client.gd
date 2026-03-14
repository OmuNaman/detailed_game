extends Node
## HTTP client for the DeepTown Brain backend (localhost:8000).
## All cognitive requests (memory, dialogue, planning, reflection) route through here.
## Uses a pool of HTTPRequest nodes to handle concurrent requests without blocking.

const BASE_URL: String = "http://localhost:8000"
const POOL_SIZE: int = 4
const REQUEST_TIMEOUT: float = 10.0

var _http_pool: Array[HTTPRequest] = []
var _pool_busy: Array[bool] = []
var _pool_callbacks: Array[Callable] = []
var _request_queue: Array[Dictionary] = []
var _backend_available: bool = false


func _ready() -> void:
	for i: int in range(POOL_SIZE):
		var http := HTTPRequest.new()
		http.timeout = REQUEST_TIMEOUT
		add_child(http)
		http.request_completed.connect(_on_request_completed.bind(i))
		_http_pool.append(http)
		_pool_busy.append(false)
		_pool_callbacks.append(Callable())

	# Check backend connectivity on startup
	get_request("/health", func(response: Dictionary, success: bool) -> void:
		_backend_available = success
		if success:
			print("[ApiClient] Backend connected at %s" % BASE_URL)
		else:
			push_warning("ApiClient: Backend not available at %s — running in offline mode" % BASE_URL)
	)


func is_available() -> bool:
	## Returns whether the backend responded to the last health check.
	return _backend_available


func post(endpoint: String, body: Dictionary, callback: Callable) -> void:
	## Queue a POST request. Callback receives (response: Dictionary, success: bool).
	_request_queue.append({
		"url": BASE_URL + endpoint,
		"method": HTTPClient.METHOD_POST,
		"body": JSON.stringify(body),
		"callback": callback,
	})
	_try_process_queue()


func put(endpoint: String, body: Dictionary, callback: Callable) -> void:
	## Queue a PUT request. Callback receives (response: Dictionary, success: bool).
	_request_queue.append({
		"url": BASE_URL + endpoint,
		"method": HTTPClient.METHOD_PUT,
		"body": JSON.stringify(body),
		"callback": callback,
	})
	_try_process_queue()


func get_request(endpoint: String, callback: Callable) -> void:
	## Queue a GET request. Callback receives (response: Dictionary, success: bool).
	_request_queue.append({
		"url": BASE_URL + endpoint,
		"method": HTTPClient.METHOD_GET,
		"body": "",
		"callback": callback,
	})
	_try_process_queue()


func _try_process_queue() -> void:
	while not _request_queue.is_empty():
		var slot: int = _find_idle_slot()
		if slot == -1:
			return  # All slots busy — will retry when a slot frees up

		var req: Dictionary = _request_queue.pop_front()
		_pool_busy[slot] = true
		_pool_callbacks[slot] = req["callback"]

		var headers: PackedStringArray = ["Content-Type: application/json"]
		var err: Error

		if req["method"] == HTTPClient.METHOD_GET:
			err = _http_pool[slot].request(req["url"], headers, HTTPClient.METHOD_GET)
		else:
			err = _http_pool[slot].request(req["url"], headers, req["method"], req["body"])

		if err != OK:
			push_warning("ApiClient: HTTP request failed to start: %s" % error_string(err))
			_pool_busy[slot] = false
			var cb: Callable = _pool_callbacks[slot]
			_pool_callbacks[slot] = Callable()
			if cb.is_valid():
				cb.call({}, false)


func _find_idle_slot() -> int:
	for i: int in range(POOL_SIZE):
		if not _pool_busy[i]:
			return i
	return -1


func _on_request_completed(result: int, code: int, _headers: PackedStringArray,
		body: PackedByteArray, slot: int) -> void:
	_pool_busy[slot] = false
	var cb: Callable = _pool_callbacks[slot]
	_pool_callbacks[slot] = Callable()

	if not cb.is_valid():
		_try_process_queue()
		return

	# Handle failures
	if result != HTTPRequest.RESULT_SUCCESS or code < 200 or code >= 300:
		if result == HTTPRequest.RESULT_CANT_CONNECT:
			_backend_available = false
		cb.call({}, false)
		_try_process_queue()
		return

	# Parse JSON response
	var json := JSON.new()
	if json.parse(body.get_string_from_utf8()) != OK:
		push_warning("ApiClient: Failed to parse response JSON")
		cb.call({}, false)
		_try_process_queue()
		return

	_backend_available = true
	if json.data is Dictionary:
		cb.call(json.data, true)
	else:
		cb.call({"data": json.data}, true)

	# Process any queued requests now that a slot is free
	_try_process_queue()
