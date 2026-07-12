class_name ForgeLoggerHttpClient
extends Node
## Centralized HTTP communication layer for the Forge Logger API.
## Wraps Godot HTTPRequest with JSON serialization, timeout handling,
## error reporting and retry support.

signal request_completed(success: bool, response_code: int, body: Dictionary)

const LOG_PREFIX: String = "[ForgeLogger] "
const DEFAULT_TIMEOUT: float = 15.0

var _base_url: String = ""
var _api_key: String = ""
var _http_request: HTTPRequest = null


func _ready() -> void:
	_http_request = HTTPRequest.new()
	_http_request.timeout = DEFAULT_TIMEOUT
	add_child(_http_request)


func configure(base_url: String, api_key: String = "") -> void:
	_base_url = base_url.rstrip("/")
	_api_key = api_key


func get_projects() -> Dictionary:
	return await _request("GET", "/v1/projects")


func start_session(_project_id: String, payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/sessions", payload)


func create_upload(_project_id: String, payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/uploads", payload)


func put_raw(url: String, content_type: String, data: PackedByteArray) -> Dictionary:
	var headers: PackedStringArray = PackedStringArray(["Content-Type: %s" % content_type])

	url = url.replace("0.0.0.0", "127.0.0.1")

	_log("HTTP PUT %s (%d bytes, %s)" % [url, data.size(), content_type])

	# Use a dedicated HTTPRequest node for raw PUT uploads to avoid conflicts
	# with the main _http_request used for API calls.
	var put_request: HTTPRequest = HTTPRequest.new()
	put_request.timeout = 60
	put_request.use_threads = false
	add_child(put_request)

	var err: int = put_request.request_raw(url, headers, HTTPClient.METHOD_PUT, data)
	if err != OK:
		print("err", err)
		_log("HTTP PUT request error: %s (url: %s)" % [error_string(err), url])
		put_request.queue_free()
		return {"success": false, "response_code": 0, "body": {}, "error": error_string(err)}

	var result: Array = await put_request.request_completed
	put_request.queue_free()
	var response_code: int = result[1] as int
	var response_body: PackedByteArray = result[3] as PackedByteArray

	var parsed_body: Dictionary = _parse_response(response_body)
	var success: bool = response_code >= 200 and response_code < 300

	if not success:
		var error_detail: String = _format_error_body(parsed_body)
		_log("HTTP PUT %s -> %d%s" % [url, response_code, error_detail])

	return {"success": success, "response_code": response_code, "body": parsed_body}


func submit_report(_project_id: String, payload: Dictionary) -> Dictionary:
	return await _request("POST", "/v1/ingest/reports", payload)


func list_reports(project_id: String) -> Dictionary:
	var path: String = "/v1/projects/%s/reports" % project_id
	return await _request("GET", path)


func get_events(project_id: String, _session_id: String) -> Dictionary:
	var path: String = "/v1/projects/%s/events" % project_id
	return await _request("GET", path)


func post_events(_project_id: String, events: Array) -> Dictionary:
	return await _request_with_body("POST", "/v1/ingest/events", events)


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


func _request_internal(method_name: String, path: String, body_str: String = "") -> Dictionary:
	var url: String = _base_url + path
	var headers: PackedStringArray = PackedStringArray(["Content-Type: application/json"])
	if _api_key != "":
		headers.append("Authorization: Bearer %s" % _api_key)

	var http_method: int = _method_to_enum(method_name)

	_log("HTTP %s %s -> %s" % [method_name, path, body_str])

	var err: int = _http_request.request(url, headers, http_method, body_str)
	if err != OK:
		_log("HTTP request error: %s (url: %s)" % [error_string(err), url])
		return {"success": false, "response_code": 0, "body": {}, "error": error_string(err)}

	var result: Array = await _http_request.request_completed
	var response_code: int = result[1] as int
	var response_body: PackedByteArray = result[3] as PackedByteArray

	var parsed_body: Dictionary = _parse_response(response_body)
	var success: bool = response_code >= 200 and response_code < 300

	if not success:
		var error_detail: String = _format_error_body(parsed_body)
		_log("HTTP %s %s -> %d%s" % [method_name, path, response_code, error_detail])

	request_completed.emit(success, response_code, parsed_body)
	return {"success": success, "response_code": response_code, "body": parsed_body}


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
