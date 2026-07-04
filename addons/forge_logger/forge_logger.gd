extends Node
## ForgeLogger — runtime autoload singleton.
## Provides the public API for session management, bug reporting,
## log uploads, and offline retry.

const LOG_PREFIX: String = "[ForgeLogger] "
const REPORT_ACTION: String = "forge_logger_report"

signal session_ready

var config: ForgeLoggerConfig = null
var http: ForgeLoggerHttpClient = null
var session_manager: ForgeLoggerSessionManager = null
var upload_manager: ForgeLoggerUploadManager = null
var report_queue: ForgeLoggerReportQueue = null
var event_manager: ForgeLoggerEventManager = null

var _initialized: bool = false
var _session_started: bool = false
var _pending_screenshot_path: String = ""


func _ready() -> void:
	_initialize()
	_register_report_action()
	if config.auto_start_session:
		# Defer session start so the scene tree is fully ready.
		call_deferred("_auto_start")


func _initialize() -> void:
	if _initialized:
		return

	config = ForgeLoggerConfig.load_from_project_settings()

	http = ForgeLoggerHttpClient.new()
	http.name = "ForgeLoggerHttp"
	add_child(http)
	http.configure(config.base_url, config.api_key)

	session_manager = ForgeLoggerSessionManager.new()
	session_manager.initialize(config, http)

	upload_manager = ForgeLoggerUploadManager.new()
	upload_manager.initialize(config, http)

	report_queue = ForgeLoggerReportQueue.new()
	report_queue.initialize(config, http)

	event_manager = ForgeLoggerEventManager.new()
	event_manager.initialize(config, http)

	_initialized = true
	_log("Initialized (project: %s, url: %s)." % [config.project_id, config.base_url])


func _auto_start() -> void:
	# Check for crash from previous session
	if session_manager.has_crash_marker():
		_log("Unclean shutdown detected from previous session.")
		session_manager.clear_crash_marker()
		# Retry any queued reports from previous session
		if report_queue.queue_size() > 0:
			_log("Retrying %d queued reports..." % report_queue.queue_size())
			var sent: int = await report_queue.retry_all(config.project_id)
			_log("Retried queued reports: %d succeeded." % sent)

	# Start new session
	var success: bool = await session_manager.start_session()
	if success:
		_log("Session active: %s" % session_manager.get_session_id())
	else:
		_log("Session start failed; reports will be queued.")
	_session_started = true
	session_ready.emit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed(REPORT_ACTION):
		get_viewport().set_input_as_handled()
		show_report_popup()


func _register_report_action() -> void:
	if not InputMap.has_action(REPORT_ACTION):
		InputMap.add_action(REPORT_ACTION)
		var key_event: InputEventKey = InputEventKey.new()
		key_event.keycode = KEY_F8
		InputMap.action_add_event(REPORT_ACTION, key_event)
		_log("Registered default report hotkey: F8 (action: %s)." % REPORT_ACTION)


# ---- Public API ----


## Submit a bug report programmatically.
## Example:
##   ForgeLogger.capture_bug({
##       "title": "Player stuck in wall",
##       "description": "Dash caused collision lock",
##       "severity": "high",
##       "tags": ["movement", "collision"],
##       "custom_data": {"scene": get_tree().current_scene.name}
##   })
func capture_bug(data: Dictionary) -> String:
	var session_id: String = session_manager.get_session_id()
	var report: ForgeLoggerModels.ReportData = ForgeLoggerReportBuilder.build_from_dict(data, session_id)

	# Optionally attach logs
	var attach_logs: bool = data.get("attach_logs", config.enable_logs)
	if attach_logs and config.project_id != "":
		var upload_refs: Array[Dictionary] = await upload_manager.upload_all_logs(config.project_id, session_id)
		report.uploads = upload_refs

	# Optionally attach screenshot
	var attach_screenshot: bool = data.get("attach_screenshot", config.enable_screenshot)
	if attach_screenshot and config.project_id != "":
		var screenshot_path: String = upload_manager.capture_screenshot(get_viewport())
		var screenshot_refs: Array[Dictionary] = await upload_manager.upload_screenshot(config.project_id, session_id, screenshot_path)
		report.uploads.append_array(screenshot_refs)

	# Upload any events that have not been sent yet so their IDs are available.
	var session_id_for_events: String = session_manager.get_session_id()
	if config.project_id != "" and not session_id_for_events.is_empty():
		await event_manager.send_events(config.project_id, session_id_for_events)

	# Attach IDs of events already uploaded via API.
	report.event_ids = event_manager.get_uploaded_event_ids()

	var payload: Dictionary = ForgeLoggerReportBuilder.build_report_payload(report)
	return await _submit_or_queue(payload)


## Submit a report built from the UI popup.
## Returns the report ID on success, or an empty string on failure.
func submit_ui_report(title: String, description: String, attach_logs: bool, attach_screenshot: bool = true) -> String:
	var session_id: String = session_manager.get_session_id()

	var report: ForgeLoggerModels.ReportData = ForgeLoggerModels.ReportData.new()
	report.session_id = session_id
	report.title = title
	report.description = description
	report.severity = "medium"
	report.reporter_type = "player"

	if attach_logs and config.project_id != "":
		var upload_refs: Array[Dictionary] = await upload_manager.upload_all_logs(config.project_id, session_id)
		report.uploads = upload_refs

	if attach_screenshot and _pending_screenshot_path != "" and config.project_id != "":
		var screenshot_refs: Array[Dictionary] = await upload_manager.upload_screenshot(config.project_id, session_id, _pending_screenshot_path)
		report.uploads.append_array(screenshot_refs)

	_pending_screenshot_path = ""

	# Upload any events that have not been sent yet so their IDs are available.
	var session_id_for_events: String = session_manager.get_session_id()
	if config.project_id != "" and not session_id_for_events.is_empty():
		await event_manager.send_events(config.project_id, session_id_for_events)

	# Attach IDs of events already uploaded via API.
	report.event_ids = event_manager.get_uploaded_event_ids()

	var payload: Dictionary = ForgeLoggerReportBuilder.build_report_payload(report)
	return await _submit_or_queue(payload)


## Show the in-game bug report popup.
func show_report_popup() -> void:
	# Capture a clean frame BEFORE the popup is added, and only when screenshots
	# are enabled (config.enable_screenshot, opt-in). Covers both the hotkey path
	# and direct show_report_popup() calls.
	if config.enable_screenshot and _pending_screenshot_path == "":
		_pending_screenshot_path = upload_manager.capture_screenshot(get_viewport())
	# Dynamic load — plugin UI scene path may vary; justification: runtime-only UI instantiation.
	var scene: PackedScene = load("res://addons/forge_logger/ui/report_popup.tscn") as PackedScene
	if scene == null:
		_log("Report popup scene not found.")
		return
	var popup: Control = scene.instantiate() as Control
	# Use a CanvasLayer so the popup always renders on top and is not affected by scene transforms.
	var canvas_layer: CanvasLayer = CanvasLayer.new()
	canvas_layer.layer = 100
	canvas_layer.name = "ForgeLoggerPopupLayer"
	get_tree().root.add_child(canvas_layer)
	canvas_layer.add_child(popup)


## Manually start a session (if auto_start_session is false).
func start_session() -> bool:
	return await session_manager.start_session()


## Get current session ID.
func get_session_id() -> String:
	return session_manager.get_session_id()


## Retry all queued reports.
func retry_queued() -> int:
	return await report_queue.retry_all(config.project_id)


## Wait until the session has been initialized (started or failed).
## Call this before using session-dependent API methods from early scripts.
func await_session_ready() -> void:
	if _session_started:
		return
	await session_ready


## Record an event with type and optional payload. Stored in memory until sent.
## Example:
##   ForgeLogger.record_event("input", {"key": "I", "action": "open_inventory"})
func record_event(event_type: String, payload: Dictionary = {}) -> void:
	event_manager.record_event(event_type, payload)


## Send all stored events to the API independently (without a bug report).
## Waits for session to be ready before sending.
## Returns true if events were sent successfully.
func send_events() -> bool:
	await await_session_ready()
	var session_id: String = session_manager.get_session_id()
	if config.project_id.is_empty():
		_log("Cannot send events: project_id is not configured.")
		return false
	return await event_manager.send_events(config.project_id, session_id)


## Post a single event immediately to the API without storing it.
## Waits for session to be ready before posting.
## Returns true if the event was sent successfully.
func post_event(event_type: String, payload: Dictionary = {}) -> bool:
	await await_session_ready()
	var session_id: String = session_manager.get_session_id()
	if config.project_id.is_empty():
		_log("Cannot post event: project_id is not configured.")
		return false
	return await event_manager.post_event_immediate(config.project_id, session_id, event_type, payload)


## Get the number of stored events.
func get_event_count() -> int:
	return event_manager.event_count()


## Clear all stored events without sending them.
func clear_events() -> void:
	event_manager.clear_events()


## Check API health.
func check_health() -> Dictionary:
	return await http.check_health()


# ---- Internal ----


func _submit_or_queue(payload: Dictionary) -> String:
	if config.project_id.is_empty():
		_log("Cannot submit report: project_id is not configured.")
		report_queue.enqueue(payload)
		return ""

	var result: Dictionary = await http.submit_report(config.project_id, payload)
	if result.get("success", false):
		var body: Dictionary = result.get("body", {})
		var report_id: String = str(body.get("id", body.get("reportId", "")))
		_log("Report submitted: %s (id: %s)" % [payload.get("title", ""), report_id])
		return report_id
	else:
		var err_body: Dictionary = result.get("body", {})
		var error_msg: String = str(err_body.get("message", ""))
		_log("Report submission failed (HTTP %d), queuing for retry. %s" % [result.get("response_code", 0), error_msg])
		report_queue.enqueue(payload)
		return ""


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Clean shutdown — remove crash marker
		session_manager.clear_crash_marker()


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
