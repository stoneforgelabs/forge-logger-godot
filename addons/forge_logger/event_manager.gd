class_name ForgeLoggerEventManager
extends RefCounted
## Manages event collection, storage, and submission for the Forge Logger plugin.
## Events are stored in memory and can be attached to bug reports,
## sent independently to the API, or posted immediately.

const LOG_PREFIX: String = "[ForgeLogger] "

var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null
var _events: Array[ForgeLoggerModels.EventData] = []


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient) -> void:
	_config = config
	_http = http


## Record a new event with the given type and payload.
## The occurred_at timestamp is set automatically to the current UTC time.
func record_event(event_type: String, payload: Dictionary = {}) -> ForgeLoggerModels.EventData:
	var event: ForgeLoggerModels.EventData = ForgeLoggerModels.EventData.new()
	event.event_type = event_type
	event.occurred_at = _get_utc_timestamp()
	event.payload = payload
	_events.append(event)
	_log("Event recorded: %s" % event_type)
	return event


## Return stored events without backend ID as an array of dictionaries (API format).
func get_events_as_dicts() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for event: ForgeLoggerModels.EventData in _events:
		if not event.has_backend_id():
			result.append(event.to_dict())
	return result


## Return IDs of events that have been uploaded to the backend.
func get_uploaded_event_ids() -> Array[String]:
	var result: Array[String] = []
	for event: ForgeLoggerModels.EventData in _events:
		if event.has_backend_id():
			result.append(event.id)
	return result


## Return the number of stored events.
func event_count() -> int:
	return _events.size()


## Clear all stored events.
func clear_events() -> void:
	_events.clear()
	_log("Events cleared.")


## Send all stored events without backend IDs to the API.
## On success, assigns backend IDs to the sent events (keeps them in buffer).
## Returns true if the events were sent successfully.
func send_events(project_id: String, session_id: String) -> bool:
	var unsent: Array[ForgeLoggerModels.EventData] = []
	for event: ForgeLoggerModels.EventData in _events:
		if not event.has_backend_id():
			unsent.append(event)

	if unsent.is_empty():
		_log("No unsent events to send.")
		return true

	var events_payload: Array[Dictionary] = []
	for event: ForgeLoggerModels.EventData in unsent:
		event.session_id = session_id
		events_payload.append(event.to_dict())

	var result: Dictionary = await _http.post_events(project_id, events_payload)
	if result.get("success", false):
		var body: Variant = result.get("body", {})
		_assign_backend_ids(unsent, body)
		_log("Sent %d events successfully." % events_payload.size())
		return true
	else:
		var err_body: Dictionary = result.get("body", {})
		var error_msg: String = str(err_body.get("message", ""))
		_log("Failed to send events (HTTP %d). %s" % [result.get("response_code", 0), error_msg])
		return false


## Post a single event immediately to the API and store it with its backend ID.
## Returns true if the event was sent successfully.
func post_event_immediate(project_id: String, session_id: String, event_type: String, payload: Dictionary = {}) -> bool:
	var event: ForgeLoggerModels.EventData = ForgeLoggerModels.EventData.new()
	event.event_type = event_type
	event.occurred_at = _get_utc_timestamp()
	event.payload = payload
	event.session_id = session_id

	var result: Dictionary = await _http.post_events(project_id, [event.to_dict()])
	if result.get("success", false):
		var body: Variant = result.get("body", {})
		_assign_backend_ids([event], body)
		_events.append(event)
		_log("Immediate event sent and stored: %s (id: %s)" % [event_type, event.id])
		return true
	else:
		var err_body: Dictionary = result.get("body", {})
		var error_msg: String = str(err_body.get("message", ""))
		_log("Immediate event failed (HTTP %d). %s" % [result.get("response_code", 0), error_msg])
		return false


## Assign backend IDs from the API response to the corresponding events.
func _assign_backend_ids(events: Array[ForgeLoggerModels.EventData], body: Variant) -> void:
	# Response can be {"items": [...]} (wrapped by _parse_response) or a dict with ids.
	var items: Array = []
	if body is Dictionary:
		var body_dict: Dictionary = body as Dictionary
		if body_dict.has("items") and body_dict["items"] is Array:
			items = body_dict["items"] as Array
		elif body_dict.has("id"):
			items = [body_dict]
	if items.size() == events.size():
		for i: int in range(items.size()):
			var item: Variant = items[i]
			if item is Dictionary:
				var item_id: String = str((item as Dictionary).get("id", ""))
				if item_id != "":
					events[i].id = item_id
	else:
		_log("Could not assign backend IDs: response items count (%d) != events count (%d)." % [items.size(), events.size()])


func _get_utc_timestamp() -> String:
	var dt: Dictionary = Time.get_datetime_dict_from_system(true)
	return "%04d-%02d-%02dT%02d:%02d:%02d.000Z" % [
		dt["year"], dt["month"], dt["day"],
		dt["hour"], dt["minute"], dt["second"],
	]


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
