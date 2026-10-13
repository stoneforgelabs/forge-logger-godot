class_name ForgeLoggerHttpClient
extends Node
## Centralized HTTP communication layer for the Forge Logger API.
## Wraps Godot HTTPRequest with JSON serialization, timeout handling,
## error reporting and retry support.
##
## Every request in flight owns its own HTTPRequest node, taken from a small
## pool of idle nodes. A single shared HTTPRequest answers a second request
## made while the first is still running with ERR_BUSY — so a bug report, an
## event batch, a heartbeat, an upload and a feedback answer sent at the same
## time would fail each other. With the pool they all go out side by side.

signal request_completed(success: bool, response_code: int, body: Dictionary)

const LOG_PREFIX: String = "[ForgeLogger] "
const DEFAULT_TIMEOUT: float = 15.0
## Raw uploads (logs, screenshots) to the signed storage URL may be large.
const UPLOAD_TIMEOUT: float = 60.0
## Idle HTTPRequest nodes kept for reuse; extra ones are freed when they finish.
const MAX_IDLE_REQUESTS: int = 4

## Print request bodies (forge_logger/log_requests). Failures always log.
var log_requests: bool = false

var _base_url: String = ""
var _api_key: String = ""
var _idle_requests: Array[HTTPRequest] = []
var _in_flight: int = 0


func _ready() -> void:
	# Keep talking to the backend while the game is paused — the in-game
	# feedback form can pause the tree, and a paused HTTPRequest never finishes.
	process_mode = Node.PROCESS_MODE_ALWAYS


func configure(base_url: String, api_key: String = "") -> void:
	_base_url = base_url.rstrip("/")
	_api_key = api_key


## Number of requests currently waiting for a response.
func in_flight_count() -> int:
	return _in_flight


func start_session(payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/sessions", payload)


func create_upload(payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/uploads", payload)


func post_heartbeat(session_id: String, payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/sessions/%s/heartbeat" % session_id.uri_encode(), payload)


func put_raw(url: String, content_type: String, data: PackedByteArray) -> Dictionary:
	var headers: PackedStringArray = PackedStringArray(["Content-Type: %s" % content_type])

	url = url.replace("0.0.0.0", "127.0.0.1")

	if log_requests:
		_log("HTTP PUT %s (%d bytes, %s)" % [url, data.size(), content_type])

	var put_request: HTTPRequest = _acquire(UPLOAD_TIMEOUT)
	var err: int = put_request.request_raw(url, headers, HTTPClient.METHOD_PUT, data)
	if err != OK:
		_release(put_request)
		_log("HTTP PUT request error: %s (url: %s)" % [error_string(err), url])
		return {"success": false, "response_code": 0, "body": {}, "headers": {}, "error": error_string(err)}

	var result: Array = await put_request.request_completed
	_release(put_request)
	var response_code: int = result[1] as int
	var parsed_body: Dictionary = _parse_response(result[3] as PackedByteArray)
	var success: bool = response_code >= 200 and response_code < 300

	if not success:
		var error_detail: String = _format_error_body(parsed_body)
		_log("HTTP PUT %s -> %d%s" % [url, response_code, error_detail])

	return {"success": success, "response_code": response_code, "body": parsed_body, "headers": _parse_headers(result[2] as PackedStringArray)}


func submit_report(payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/reports", payload)


func post_events(events: Array) -> Dictionary:
	return await _request_with_body("POST", "/v1/ingest/events", events)


## Fetch an in-game feedback form. Pass the ETag of a cached copy to get a
## 304 (empty body) while the form is unchanged.
func get_feedback_form(link_token: String, etag: String = "") -> Dictionary:
	var headers: PackedStringArray = PackedStringArray()
	if not etag.is_empty():
		headers.append("If-None-Match: %s" % etag)
	return await _request_internal("GET", "/v1/ingest/feedback/%s" % link_token.uri_encode(), "", headers)


## Submit a player's feedback answers. The body is never logged: it can carry
## the player's contact, and the log is attached to later bug reports.
func submit_feedback(payload: Dictionary) -> Dictionary:
	return await _request_internal("POST", "/v1/ingest/feedback", JSON.stringify(payload), PackedStringArray(), false)


func check_health() -> Dictionary:
	return await _request("GET", "/health")


func _format_error_body(body: Dictionary) -> String:
	if body.is_empty():
		return ""
	var message: String = str(body.get("message", ""))
	var error: String = str(body.get("error", ""))
	var parts: PackedStringArray = PackedStringArray()
	if error != "":
		parts.append(error)
	if message != "":
		parts.append(message)
	if parts.is_empty():
		return " | Body: %s" % JSON.stringify(body)
	return " | %s" % " - ".join(parts)


func _request_with_body(method_name: String, path: String, body: Variant) -> Dictionary:
	return await _request_internal(method_name, path, JSON.stringify(body))


func _request(method_name: String, path: String, body: Dictionary = {}) -> Dictionary:
	var body_str: String = ""
	if method_name == "POST" or method_name == "PUT" or method_name == "PATCH":
		body_str = JSON.stringify(body)
	return await _request_internal(method_name, path, body_str)


## Result: {success, response_code, body, headers} (+ error when the request
## could not be started). response_code 0 = no response (offline, DNS, timeout).
## Header names in `headers` are lower-case.
func _request_internal(method_name: String, path: String, body_str: String = "", extra_headers: PackedStringArray = PackedStringArray(), log_body: bool = true) -> Dictionary:
	var url: String = _base_url + path
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	if _api_key != "":
		headers.append("Authorization: Bearer %s" % _api_key)
	headers.append_array(extra_headers)

	var http_method: int = _method_to_enum(method_name)

	if log_requests:
		if log_body:
			_log("HTTP %s %s -> %s" % [method_name, path, body_str])
		else:
			_log("HTTP %s %s (%d bytes)" % [method_name, path, body_str.to_utf8_buffer().size()])

	var http_request: HTTPRequest = _acquire(DEFAULT_TIMEOUT)
	var err: int = http_request.request(url, headers, http_method, body_str)
	if err != OK:
		_release(http_request)
		_log("HTTP request error: %s (url: %s)" % [error_string(err), url])
		return {"success": false, "response_code": 0, "body": {}, "headers": {}, "error": error_string(err)}

	var result: Array = await http_request.request_completed
	_release(http_request)
	var response_code: int = result[1] as int
	var parsed_body: Dictionary = _parse_response(result[3] as PackedByteArray)
	var success: bool = response_code >= 200 and response_code < 300

	if not success and response_code != 304:
		var error_detail: String = _format_error_body(parsed_body)
		_log("HTTP %s %s -> %d%s" % [method_name, path, response_code, error_detail])

	request_completed.emit(success, response_code, parsed_body)
	return {"success": success, "response_code": response_code, "body": parsed_body, "headers": _parse_headers(result[2] as PackedStringArray)}


func _acquire(timeout: float) -> HTTPRequest:
	var http_request: HTTPRequest = null
	while not _idle_requests.is_empty() and http_request == null:
		var candidate: HTTPRequest = _idle_requests.pop_back()
		if is_instance_valid(candidate):
			http_request = candidate
	if http_request == null:
		http_request = HTTPRequest.new()
		http_request.use_threads = false
		add_child(http_request)
	http_request.timeout = timeout
	_in_flight += 1
	return http_request


func _release(http_request: HTTPRequest) -> void:
	_in_flight = maxi(_in_flight - 1, 0)
	if not is_instance_valid(http_request):
		return
	if _idle_requests.size() < MAX_IDLE_REQUESTS:
		_idle_requests.append(http_request)
	else:
		http_request.queue_free()


func _parse_headers(raw: PackedStringArray) -> Dictionary:
	var headers: Dictionary = {}
	for line: String in raw:
		var colon: int = line.find(":")
		if colon <= 0:
			continue
		headers[line.substr(0, colon).strip_edges().to_lower()] = line.substr(colon + 1).strip_edges()
	return headers


## Synchronous best-effort POST with its own HTTPClient, for shutdown paths
## where the SceneTree will not process another frame (window closed, quit).
## Blocks the caller for at most timeout_ms. Not available on web exports
## (no blocking sockets there) — returns false.
func post_blocking(path: String, payload: Variant, timeout_ms: int = 1500) -> bool:
	if OS.has_feature("web"):
		return false
	var url: String = _base_url
	var use_tls: bool = url.begins_with("https://")
	var rest: String = url.substr(8 if use_tls else 7) if url.begins_with("http") else url
	var slash: int = rest.find("/")
	var host_port: String = rest if slash < 0 else rest.substr(0, slash)
	var base_path: String = "" if slash < 0 else rest.substr(slash)
	var host: String = host_port
	var port: int = -1
	var colon: int = host_port.rfind(":")
	if colon > 0 and host_port.substr(colon + 1).is_valid_int():
		host = host_port.substr(0, colon)
		port = host_port.substr(colon + 1).to_int()

	var client: HTTPClient = HTTPClient.new()
	var deadline: int = Time.get_ticks_msec() + timeout_ms
	var err: int = client.connect_to_host(host, port, TLSOptions.client() if use_tls else null)
	if err != OK:
		return false
	while client.get_status() in [HTTPClient.STATUS_RESOLVING, HTTPClient.STATUS_CONNECTING]:
		if Time.get_ticks_msec() > deadline:
			client.close()
			return false
		client.poll()
		OS.delay_msec(5)
	if client.get_status() != HTTPClient.STATUS_CONNECTED:
		client.close()
		return false

	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	if _api_key != "":
		headers.append("Authorization: Bearer %s" % _api_key)
	var body_str: String = JSON.stringify(payload)
	if log_requests:
		_log("HTTP POST %s -> %s (blocking)" % [path, body_str])
	err = client.request(HTTPClient.METHOD_POST, base_path + path, headers, body_str)
	if err != OK:
		client.close()
		return false
	while client.get_status() == HTTPClient.STATUS_REQUESTING:
		if Time.get_ticks_msec() > deadline:
			client.close()
			return false
		client.poll()
		OS.delay_msec(5)
	var code: int = client.get_response_code() if client.has_response() else 0
	client.close()
	return code >= 200 and code < 300


func _parse_response(raw: PackedByteArray) -> Dictionary:
	if raw.is_empty():
		return {}
	var text: String = raw.get_string_from_utf8()
	if text.is_empty():
		return {}
	var json: JSON = JSON.new()
	var parse_err: int = json.parse(text)
	if parse_err != OK:
		_log("JSON parse error: %s" % json.get_error_message())
		return {"_raw": text}
	var data: Variant = json.data
	if data is Dictionary:
		return data as Dictionary
	if data is Array:
		return {"items": data}
	return {"_raw": text}


func _method_to_enum(method_name: String) -> int:
	match method_name:
		"GET":
			return HTTPClient.METHOD_GET
		"POST":
			return HTTPClient.METHOD_POST
		"PUT":
			return HTTPClient.METHOD_PUT
		"PATCH":
			return HTTPClient.METHOD_PATCH
		"DELETE":
			return HTTPClient.METHOD_DELETE
		_:
			return HTTPClient.METHOD_GET


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
