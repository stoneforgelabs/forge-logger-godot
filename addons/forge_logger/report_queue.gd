class_name ForgeLoggerReportQueue
extends RefCounted
## Offline retry queue. Stores failed reports to disk and retries them
## on the next game launch or when connectivity is restored.

const LOG_PREFIX: String = "[ForgeLogger] "
const QUEUE_FILE: String = "user://forge_logger_queue.json"
## A queued report is discarded after this many failed retry attempts so the
## offline queue cannot grow without bound.
const MAX_RETRY_ATTEMPTS: int = 5

var _queue: Array[Dictionary] = []
var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient) -> void:
	_config = config
	_http = http
	_load_queue()


func enqueue(report_payload: Dictionary) -> void:
	var entry: Dictionary = {
		"payload": report_payload,
		"queued_at": Time.get_datetime_string_from_system(true),
		"attempts": 0,
	}
	_queue.append(entry)
	_save_queue()
	_log("Report queued for retry (%d in queue)." % _queue.size())


func retry_all() -> int:
	if _queue.is_empty():
		return 0

	var succeeded: int = 0
	var remaining: Array[Dictionary] = []

	for entry: Dictionary in _queue:
		var payload: Dictionary = entry.get("payload", {})
		var attempts: int = entry.get("attempts", 0) + 1
		entry["attempts"] = attempts

		var result: Dictionary = await _http.submit_report(payload)
		if result.get("success", false):
			succeeded += 1
			_log("Queued report submitted successfully (attempt %d)." % attempts)
		else:
			if attempts < MAX_RETRY_ATTEMPTS:
				remaining.append(entry)
				_log("Queued report retry failed (attempt %d/%d), keeping in queue." % [attempts, MAX_RETRY_ATTEMPTS])
			else:
				# Surface the drop loudly: after MAX_RETRY_ATTEMPTS the report is
				# discarded for good, so it must not pass silently.
				push_warning("[ForgeLogger] Report permanently dropped after %d failed retry attempts." % attempts)
				_log("Queued report dropped after %d attempts (max %d)." % [attempts, MAX_RETRY_ATTEMPTS])

	_queue = remaining
	_save_queue()
	return succeeded


func queue_size() -> int:
	return _queue.size()


func clear() -> void:
	_queue.clear()
	_save_queue()


func _load_queue() -> void:
	if not FileAccess.file_exists(QUEUE_FILE):
		return
	var file: FileAccess = FileAccess.open(QUEUE_FILE, FileAccess.READ)
	if file == null:
		return
	var text: String = file.get_as_text()
	file.close()

	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		_log("Failed to parse queue file.")
		return

	var data: Variant = json.data
	if data is Array:
		for item: Variant in data:
			if item is Dictionary:
				_queue.append(item as Dictionary)

	if not _queue.is_empty():
		_log("Loaded %d queued reports from disk." % _queue.size())


func _save_queue() -> void:
	var file: FileAccess = FileAccess.open(QUEUE_FILE, FileAccess.WRITE)
	if file == null:
		_log("Failed to save queue file.")
		return
	var arr: Array = []
	for entry: Dictionary in _queue:
		arr.append(entry)
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
