class_name ForgeLoggerEventManager
extends RefCounted
## Manages event collection, storage, and submission for the Forge Logger plugin.
## Events are stored in memory and can be attached to bug reports,
## sent independently to the API, or posted immediately.

const LOG_PREFIX: String = "[ForgeLogger] "
## Analytics events (track()) waiting to be sent; the oldest are dropped
## beyond this so an offline game cannot grow the buffer without bound.
const TRACK_MAX_PENDING: int = 1000
## Events per POST /v1/ingest/events request (server max is 500).
const TRACK_BATCH_SIZE: int = 100

signal _flush_finished

## A send_events() batch finished (internal: serializes concurrent calls).
signal _batch_finished

var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null
var _events: Array[ForgeLoggerModels.EventData] = []
var _sending: bool = false
# track() buffer: API-shaped dictionaries, removed once delivered (unlike
# _events, which are kept so bug reports can link them).
var _tracked: Array[Dictionary] = []
var _flushing: bool = false
var _dropped_warned: bool = false


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
##
## Calls are serialized: an event gets its backend id only when the response
## arrives, so two batches in flight at once (capture_bug() twice in a row, a
## periodic send_events() next to an F8 report) would both post the same
## events and the server — without an idempotency key for events — would
## store them twice. A second call waits for the first, then sends whatever
## is still without an id.
func send_events(session_id: String) -> bool:
	while _sending:
		await _batch_finished
	_sending = true
	var ok: bool = await _send_unsent(session_id)
	_sending = false
	_batch_finished.emit()
	return ok


func _send_unsent(session_id: String) -> bool:
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

	var result: Dictionary = await _http.post_events(events_payload)
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
func post_event_immediate(session_id: String, event_type: String, payload: Dictionary = {}) -> bool:
	var event: ForgeLoggerModels.EventData = ForgeLoggerModels.EventData.new()
	event.event_type = event_type
	event.occurred_at = _get_utc_timestamp()
	event.payload = payload
	event.session_id = session_id

	var result: Dictionary = await _http.post_events([event.to_dict()])
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


## Queue an analytics event (fire-and-forget). Sent in batches by
## flush_tracked(); `session_id` may be empty and is then filled in at send time.
func track(event_type: String, payload: Dictionary, session_id: String) -> void:
	_tracked.append({
		"sessionId": session_id,
		"eventType": event_type,
		"occurredAt": _get_utc_timestamp(),
		"payload": payload,
	})
	if _tracked.size() > TRACK_MAX_PENDING:
		_tracked.pop_front()
		if not _dropped_warned:
			_dropped_warned = true
			push_warning("[ForgeLogger] Analytics buffer full (%d); dropping the oldest events." % TRACK_MAX_PENDING)


## Number of tracked events not delivered yet.
func pending_tracked() -> int:
	return _tracked.size()


## Send all tracked events in batches. Events without a session id get
## `session_id`. Keeps undelivered events on network errors, 429 and 5xx (next
## flush retries them); drops a batch the server rejects outright (other 4xx),
## which would otherwise be re-sent forever. Concurrent calls wait for the
## running flush and then send what is left. Returns true when the buffer is
## empty afterwards.
func flush_tracked(session_id: String) -> bool:
	while _flushing:
		await _flush_finished
	if _tracked.is_empty():
		return true
	if session_id.is_empty():
		return false
	_flushing = true
	var ok: bool = true
	while not _tracked.is_empty():
		var count: int = mini(TRACK_BATCH_SIZE, _tracked.size())
		var batch: Array[Dictionary] = []
		for i: int in range(count):
			var ev: Dictionary = _tracked[i]
			if str(ev.get("sessionId", "")).is_empty():
				ev["sessionId"] = session_id
			batch.append(ev)
		var result: Dictionary = await _http.post_events(batch)
		if result.get("success", false):
			_tracked = _tracked.slice(count)
			continue
		var code: int = result.get("response_code", 0)
		if code >= 400 and code < 500 and code != 408 and code != 429:
			var err_body: Dictionary = result.get("body", {})
			push_warning("[ForgeLogger] Dropped %d analytics events rejected by the server (HTTP %d): %s" % [count, code, str(err_body.get("message", ""))])
			_tracked = _tracked.slice(count)
			continue
		ok = false
		break
	_flushing = false
	_flush_finished.emit()
	return ok and _tracked.is_empty()


## Shutdown path: one blocking request with up to TRACK_BATCH_SIZE events.
func flush_tracked_blocking(session_id: String) -> void:
	if _tracked.is_empty() or session_id.is_empty():
		return
	var batch: Array = []
	for i: int in range(mini(TRACK_BATCH_SIZE, _tracked.size())):
		var ev: Dictionary = _tracked[i]
		if str(ev.get("sessionId", "")).is_empty():
			ev["sessionId"] = session_id
		batch.append(ev)
	if _http.post_blocking("/v1/ingest/events", batch, 1000):
		_tracked = _tracked.slice(batch.size())


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
