class_name ForgeLoggerReportQueue
extends RefCounted
## Offline retry queue for everything the plugin must not lose: bug reports
## and in-game feedback answers. Entries are stored on disk and retried on the
## next launch (once a session is up) or when retry_all() is called.
##
## Each entry has a `kind` and the handler registered for that kind sends it.
## `report` is built in; the feedback manager registers `feedback`. Queue files
## written by plugin 0.3.x and older hold report entries without a `kind` —
## they are read as reports, so an upgraded game still sends them.
##
## The class keeps its historical name (ForgeLogger.report_queue) so games that
## call it directly keep working.

## Fired when a retry_all() pass ends, with the number of entries sent.
signal flush_finished(succeeded: int)

const LOG_PREFIX: String = "[ForgeLogger] "
const QUEUE_FILE: String = "user://forge_logger_queue.json"
## A queued entry is discarded after this many attempts the server refused
## for good (a 4xx the handler still retries — e.g. a report the API does not
## accept), so the queue cannot grow without bound. Attempts that only mean
## "later" do not count: no response (offline — an answer given at a festival
## booth with no internet must survive until the game is online again), 408,
## 429 (rate limited) and 5xx (server trouble, e.g. 503 contact_unavailable).
## Those entries expire by age instead (MAX_AGE_DAYS).
const MAX_RETRY_ATTEMPTS: int = 5
## An entry the server kept answering with "later" is dropped this many days
## after it was queued.
const MAX_AGE_DAYS: int = 30
## Hard cap on stored entries. Over it, the oldest bug report goes first;
## a player's feedback answer (maybe with a contact and a raffle entry) only
## when nothing else is left to drop.
const MAX_ENTRIES: int = 100

const KIND_REPORT: String = "report"
const KIND_FEEDBACK: String = "feedback"

## Handler outcomes (the "outcome" key of the Dictionary a handler returns).
const OUTCOME_SENT: String = "sent"
const OUTCOME_RETRY: String = "retry"
const OUTCOME_DROP: String = "drop"

var _queue: Array[Dictionary] = []
var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null
## kind -> Callable(payload: Dictionary) -> Dictionary {outcome, response_code}
var _handlers: Dictionary = {}
var _flushing: bool = false
var _last_flush_count: int = 0
## Ids of entries a caller is sending right now (stored first so that quitting
## mid-request cannot lose them) — a retry pass leaves them alone.
var _in_flight: Dictionary = {}


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient) -> void:
	_config = config
	_http = http
	register_handler(KIND_REPORT, _send_report)
	# Analytics-only setups (enable_reports = false) never touch user://: the
	# queue then lives in memory and is lost when the game quits.
	if _config.enable_reports:
		_load_queue()


## Register the sender for one kind of entry. The handler gets the stored
## payload and returns {"outcome": "sent" | "retry" | "drop", "response_code": int}
## (it may be a coroutine).
func register_handler(kind: String, handler: Callable) -> void:
	_handlers[kind] = handler


## Store a payload for a later retry. `kind` defaults to a bug report.
## Returns the entry's id. With `in_flight` the caller is about to send the
## payload itself: the entry only guards against losing it (the game quits
## mid-request) — retry_all() skips it until the caller calls
## finish_in_flight() (sent / refused: remove it; "later": keep it).
func enqueue(payload: Dictionary, kind: String = KIND_REPORT, in_flight: bool = false) -> String:
	var entry: Dictionary = {
		"id": ForgeLoggerModels.generate_uuid(),
		"kind": kind,
		"payload": payload,
		"queued_at": Time.get_datetime_string_from_system(true),
		"queued_unix": int(Time.get_unix_time_from_system()),
		"attempts": 0,
	}
	_queue.append(entry)
	if in_flight:
		_in_flight[str(entry["id"])] = true
	while _queue.size() > MAX_ENTRIES:
		var dropped: Dictionary = _queue.pop_at(_drop_index())
		_in_flight.erase(str(dropped.get("id", "")))
		push_warning("[ForgeLogger] Offline queue full — dropped the oldest %s entry." % _entry_kind(dropped))
	_save_queue()
	if not in_flight:
		_log("%s queued for retry (%d in queue)." % [kind.capitalize(), _queue.size()])
	return str(entry["id"])


## End of a caller's own send of an entry stored with `in_flight`. `keep` =
## the server said "later": the entry stays for the next retry pass.
func finish_in_flight(id: String, keep: bool) -> void:
	_in_flight.erase(id)
	if keep:
		_log("Queued for retry (%d in queue)." % _queue.size())
		return
	for i: int in range(_queue.size()):
		if str(_queue[i].get("id", "")) == id:
			_queue.remove_at(i)
			_save_queue()
			return


## Send every queued entry once. Returns how many were sent. A call made while
## a pass is already running waits for that pass instead of sending twice.
func retry_all() -> int:
	if _flushing:
		await flush_finished
		return _last_flush_count
	if _queue.is_empty():
		return 0

	_flushing = true
	var succeeded: int = 0
	var now_unix: int = int(Time.get_unix_time_from_system())
	# Kinds the server rate-limited during this pass: their remaining entries
	# wait for the next pass instead of each earning another 429 (reports and
	# feedback answers have separate limits, so one does not stall the other).
	var throttled: Dictionary = {}
	# Iterate a snapshot: entries enqueued during the pass stay for the next one.
	var snapshot: Array[Dictionary] = _queue.duplicate()
	for entry: Dictionary in snapshot:
		var kind: String = _entry_kind(entry)
		var handler: Callable = _handlers.get(kind, Callable())
		if not handler.is_valid():
			# Written by a newer plugin, or its manager is not loaded — keep it.
			continue
		if _in_flight.has(str(entry.get("id", ""))) or throttled.has(kind):
			continue
		if _is_expired(entry, now_unix):
			_remove(entry)
			push_warning("[ForgeLogger] Queued %s dropped: the server kept asking to retry later for %d days." % [kind, MAX_AGE_DAYS])
			_save_queue()
			continue

		var payload: Dictionary = entry.get("payload", {}) as Dictionary
		var result: Variant = await handler.call(payload)
		var outcome: Dictionary = result as Dictionary if result is Dictionary else {}
		var response_code: int = int(outcome.get("response_code", 0))
		match str(outcome.get("outcome", OUTCOME_RETRY)):
			OUTCOME_SENT:
				succeeded += 1
				_remove(entry)
				_log("Queued %s sent." % kind)
			OUTCOME_DROP:
				_remove(entry)
				push_warning("[ForgeLogger] Queued %s rejected by the server (HTTP %d) and dropped." % [kind, response_code])
			_:
				if response_code == 429:
					throttled[kind] = true
				if not is_transient_failure(response_code):
					entry["attempts"] = int(entry.get("attempts", 0)) + 1
				var attempts: int = int(entry.get("attempts", 0))
				if attempts >= MAX_RETRY_ATTEMPTS:
					_remove(entry)
					# Surface the drop loudly: the entry is gone for good.
					push_warning("[ForgeLogger] Queued %s permanently dropped after %d failed attempts." % [kind, attempts])
				else:
					_log("Queued %s not sent (HTTP %d, attempt %d/%d), keeping it." % [kind, response_code, attempts, MAX_RETRY_ATTEMPTS])
		# Persist after every entry, so a crash mid-pass neither loses nor resends much.
		_save_queue()

	_flushing = false
	_last_flush_count = succeeded
	flush_finished.emit(succeeded)
	return succeeded


func is_flushing() -> bool:
	return _flushing


## A failure that only means "try again later" — never counted as an attempt:
## no response (offline), 408, 429 and any 5xx.
static func is_transient_failure(response_code: int) -> bool:
	return response_code == 0 or response_code == 408 or response_code == 429 or response_code >= 500


func queue_size() -> int:
	return _queue.size()


## Number of queued entries of one kind (`report`, `feedback`).
func queue_size_of(kind: String) -> int:
	var count: int = 0
	for entry: Dictionary in _queue:
		if _entry_kind(entry) == kind:
			count += 1
	return count


func clear() -> void:
	_queue.clear()
	_save_queue()


func _send_report(payload: Dictionary) -> Dictionary:
	var result: Dictionary = await _http.submit_report(payload)
	# Reports keep their pre-0.4 rule: any failure is retried (up to
	# MAX_RETRY_ATTEMPTS answered attempts); idempotency is the clientRequestId.
	var outcome: String = OUTCOME_SENT if result.get("success", false) else OUTCOME_RETRY
	return {"outcome": outcome, "response_code": int(result.get("response_code", 0))}


## Index of the entry to drop when the queue is over MAX_ENTRIES: the oldest
## that is not a feedback answer, else the oldest.
func _drop_index() -> int:
	for i: int in range(_queue.size()):
		if _entry_kind(_queue[i]) != KIND_FEEDBACK:
			return i
	return 0


func _is_expired(entry: Dictionary, now_unix: int) -> bool:
	var queued: int = int(entry.get("queued_unix", 0))
	if queued <= 0:
		# Written before 0.5: only the ISO date-time is there.
		var at: String = str(entry.get("queued_at", ""))
		if at.is_empty():
			return false
		queued = int(Time.get_unix_time_from_datetime_string(at))
		if queued <= 0:
			return false
	return now_unix - queued > MAX_AGE_DAYS * 86400


func _entry_kind(entry: Dictionary) -> String:
	var kind: String = str(entry.get("kind", ""))
	return KIND_REPORT if kind.is_empty() else kind


func _remove(entry: Dictionary) -> void:
	var id: String = str(entry.get("id", ""))
	for i: int in range(_queue.size()):
		if str(_queue[i].get("id", "")) == id:
			_queue.remove_at(i)
			return


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
			if not item is Dictionary:
				continue
			var entry: Dictionary = item as Dictionary
			# 0.3.x entries have no id / kind: give them an id, read them as reports.
			if str(entry.get("id", "")).is_empty():
				entry["id"] = ForgeLoggerModels.generate_uuid()
			if str(entry.get("kind", "")).is_empty():
				entry["kind"] = KIND_REPORT
			if not entry.get("payload", null) is Dictionary:
				continue
			entry["attempts"] = int(entry.get("attempts", 0))
			_queue.append(entry)

	if not _queue.is_empty():
		_log("Loaded %d queued entries from disk." % _queue.size())


func _save_queue() -> void:
	if not _config.enable_reports:
		return
	var arr: Array = []
	for entry: Dictionary in _queue:
		arr.append(entry)
	# Write a temp file and swap it in, so a crash mid-write keeps the old queue.
	var tmp_path: String = QUEUE_FILE + ".tmp"
	var file: FileAccess = FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		_log("Failed to save queue file.")
		return
	file.store_string(JSON.stringify(arr, "\t"))
	file.close()
	var err: Error = DirAccess.rename_absolute(tmp_path, QUEUE_FILE)
	if err == OK:
		return
	# Some file systems refuse to rename over an existing file — write in place.
	DirAccess.remove_absolute(tmp_path)
	var direct: FileAccess = FileAccess.open(QUEUE_FILE, FileAccess.WRITE)
	if direct == null:
		_log("Failed to save queue file (%s)." % error_string(err))
		return
	direct.store_string(JSON.stringify(arr, "\t"))
	direct.close()


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
