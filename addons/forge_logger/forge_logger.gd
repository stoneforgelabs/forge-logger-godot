extends Node
## ForgeLogger — runtime autoload singleton.
## Provides the public API for session management, bug reporting,
## in-game feedback forms, log uploads, offline retry, and play analytics
## (heartbeats + track()).
##
## Runs with PROCESS_MODE_ALWAYS: a paused SceneTree (pause menus, the in-game
## feedback form) would otherwise stop its HTTPRequest and timers, so
## heartbeats, event flushes, feedback answers and end_session() would stall
## while the game is paused.

const LOG_PREFIX: String = "[ForgeLogger] "
const REPORT_ACTION: String = "forge_logger_report"
## track() events are sent at most this many seconds after being recorded.
const TRACK_FLUSH_INTERVAL: float = 5.0
const HEARTBEAT_PATH: String = "/v1/ingest/sessions/%s/heartbeat"

# Top-level fields of the API's ReportContextDto. Context-provider keys
# matching these are placed top-level; anything else goes into extra.
const CONTEXT_FIELDS: PackedStringArray = [
	"sceneName", "checkpoint", "platform", "buildVersion",
	"locale", "playerPosition", "performance", "extra",
]

signal session_ready
## A player sent an in-game feedback form (show_feedback()). `result.status`
## is "sent" (stored; `response_id`) or "queued" (offline — saved and sent on
## a later launch or retry_queued()).
signal feedback_submitted(link_token: String, result: Dictionary)
## The in-game feedback form was closed; `submitted` is true when the player
## sent it (or it was queued) before closing.
signal feedback_closed(link_token: String, submitted: bool)

var config: ForgeLoggerConfig = null
var http: ForgeLoggerHttpClient = null
var session_manager: ForgeLoggerSessionManager = null
var upload_manager: ForgeLoggerUploadManager = null
var report_queue: ForgeLoggerReportQueue = null
var event_manager: ForgeLoggerEventManager = null
var feedback_manager: ForgeLoggerFeedbackManager = null

# Engine log capture (log_capture.gd). Untyped and loaded dynamically so the
# plugin still parses on engines without the scriptable Logger class (< 4.5).
var log_capture: Object = null

## Extra keys merged into the `metadata` of the next session start, e.g.
## {"build_kind": "demo"}. Set it before the session starts (with
## auto_start_session on: in your first autoload or main scene _ready, which
## run before the deferred auto start).
var session_metadata: Dictionary = {}

var _initialized: bool = false
var _session_started: bool = false
var _pending_screenshot_path: String = ""
var _context_provider: Callable = Callable()
var _feedback_popup: Control = null
var _flush_timer: Timer = null
var _heartbeat_timer: Timer = null
var _heartbeat_in_flight: bool = false
var _warned_unconfigured_track: bool = false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	_initialize()
	if config.enable_reports and config.enable_report_hotkey:
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
	http.log_requests = config.log_requests
	add_child(http)
	http.configure(config.base_url, config.api_key)

	session_manager = ForgeLoggerSessionManager.new()
	session_manager.initialize(config, http)

	_flush_timer = Timer.new()
	_flush_timer.name = "ForgeLoggerFlush"
	_flush_timer.wait_time = TRACK_FLUSH_INTERVAL
	_flush_timer.timeout.connect(_on_flush_timer)
	add_child(_flush_timer)
	_flush_timer.start()

	_heartbeat_timer = Timer.new()
	_heartbeat_timer.name = "ForgeLoggerHeartbeat"
	_heartbeat_timer.wait_time = maxf(config.heartbeat_interval, 1.0)
	_heartbeat_timer.timeout.connect(_on_heartbeat_timer)
	add_child(_heartbeat_timer)

	upload_manager = ForgeLoggerUploadManager.new()
	upload_manager.initialize(config, http)

	report_queue = ForgeLoggerReportQueue.new()
	report_queue.initialize(config, http)

	event_manager = ForgeLoggerEventManager.new()
	event_manager.initialize(config, http)

	# Registers the "feedback" kind with the offline queue, so queued answers
	# can be sent on the next launch.
	feedback_manager = ForgeLoggerFeedbackManager.new()
	feedback_manager.initialize(config, http, session_manager, report_queue)
	# The game's own checkpoint (set_context_provider) goes with every answer,
	# so the dashboard can tell where in the demo the player was (FB-11).
	feedback_manager.checkpoint_source = _context_checkpoint

	if config.enable_reports:
		_register_log_capture()

	_initialized = true
	_log("Initialized (url: %s)." % config.base_url)


func _register_log_capture() -> void:
	if not ClassDB.class_exists("Logger"):
		_log("Scriptable Logger unavailable (Godot < 4.5); reports will attach godot.log from disk.")
		return
	var capture_script: GDScript = load("res://addons/forge_logger/log_capture.gd") as GDScript
	if capture_script == null:
		_log("Log capture script not found.")
		return
	log_capture = capture_script.new()
	# call() keeps this compilable on engines where OS.add_logger does not exist.
	OS.call("add_logger", log_capture)
	_log("Engine log capture active.")


func _auto_start() -> void:
	# Check for crash from previous session (bug reporting only — analytics-only
	# setups keep nothing in user://).
	if config.enable_reports and session_manager.has_crash_marker():
		_log("Unclean shutdown detected from previous session.")
		session_manager.clear_crash_marker()

	# Start new session
	var success: bool = await _start_session_internal()
	if success:
		_log("Session active: %s" % session_manager.get_session_id())
	else:
		_log("Session start failed; reports will be queued.")


func _start_session_internal() -> bool:
	session_manager.session_metadata = session_metadata.duplicate(true)
	var success: bool = await session_manager.start_session()
	if success:
		_on_session_started()
	if not _session_started:
		_session_started = true
		session_ready.emit()
	return success


func _on_session_started() -> void:
	if config.heartbeat_interval > 0.0:
		_heartbeat_timer.wait_time = maxf(config.heartbeat_interval, 1.0)
		_heartbeat_timer.start()
		_web_arm_end_beacon()
	# Events tracked before the session existed go out with the first flush.
	if event_manager.pending_tracked() > 0:
		flush()
	_flush_queue_in_background()


## Send what an earlier run left in the offline queue (reports and feedback
## answers) once the backend answered — after any shutdown, clean or not.
## Runs alongside the game: every request has its own HTTPRequest.
func _flush_queue_in_background() -> void:
	if report_queue.queue_size() == 0:
		return
	_log("Retrying %d queued entries..." % report_queue.queue_size())
	var sent: int = await report_queue.retry_all()
	_log("Retried queued entries: %d sent, %d left." % [sent, report_queue.queue_size()])


func _unhandled_input(event: InputEvent) -> void:
	# The autoload runs with PROCESS_MODE_ALWAYS; keep the report hotkey
	# inactive while the game is paused.
	if not config.enable_reports or not config.enable_report_hotkey or get_tree().paused:
		return
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
	if not config.enable_reports:
		_log("capture_bug ignored: forge_logger/enable_reports is off.")
		return ""
	var session_id: String = session_manager.get_session_id()
	var report: ForgeLoggerModels.ReportData = ForgeLoggerReportBuilder.build_from_dict(data, session_id)
	report.source_channel = data.get("source_channel", "api")
	report.context = _build_context()

	# Optionally attach logs
	var attach_logs: bool = data.get("attach_logs", config.enable_logs)
	if attach_logs and config.is_ingest_configured():
		var upload_refs: Array[Dictionary] = await _upload_logs(session_id)
		report.uploads = upload_refs

	# Optionally attach screenshot
	var attach_screenshot: bool = data.get("attach_screenshot", config.enable_screenshot)
	if attach_screenshot and config.is_ingest_configured():
		var screenshot_path: String = upload_manager.capture_screenshot(get_viewport())
		var screenshot_refs: Array[Dictionary] = await upload_manager.upload_screenshot(session_id, screenshot_path)
		report.uploads.append_array(screenshot_refs)

	# Upload any events that have not been sent yet so their IDs are available.
	var session_id_for_events: String = session_manager.get_session_id()
	if config.is_ingest_configured() and not session_id_for_events.is_empty():
		await event_manager.send_events(session_id_for_events)

	# Attach IDs of events already uploaded via API.
	report.event_ids = event_manager.get_uploaded_event_ids()

	var payload: Dictionary = ForgeLoggerReportBuilder.build_report_payload(report)
	return await _submit_or_queue(payload)


## Submit a report built from the UI popup.
## Returns the report ID on success, or an empty string on failure.
func submit_ui_report(title: String, description: String, attach_logs: bool, attach_screenshot: bool = true) -> String:
	if not config.enable_reports:
		_log("submit_ui_report ignored: forge_logger/enable_reports is off.")
		return ""
	var session_id: String = session_manager.get_session_id()

	var report: ForgeLoggerModels.ReportData = ForgeLoggerModels.ReportData.new()
	report.session_id = session_id
	report.title = title
	report.description = description
	report.severity = "medium"
	report.reporter_type = "player"
	report.source_channel = "ui_popup"
	report.context = _build_context()

	if attach_logs and config.is_ingest_configured():
		var upload_refs: Array[Dictionary] = await _upload_logs(session_id)
		report.uploads = upload_refs

	if attach_screenshot and _pending_screenshot_path != "" and config.is_ingest_configured():
		var screenshot_refs: Array[Dictionary] = await upload_manager.upload_screenshot(session_id, _pending_screenshot_path)
		report.uploads.append_array(screenshot_refs)

	_pending_screenshot_path = ""

	# Upload any events that have not been sent yet so their IDs are available.
	var session_id_for_events: String = session_manager.get_session_id()
	if config.is_ingest_configured() and not session_id_for_events.is_empty():
		await event_manager.send_events(session_id_for_events)

	# Attach IDs of events already uploaded via API.
	report.event_ids = event_manager.get_uploaded_event_ids()

	var payload: Dictionary = ForgeLoggerReportBuilder.build_report_payload(report)
	return await _submit_or_queue(payload)


## Show the in-game bug report popup.
func show_report_popup() -> void:
	if not config.enable_reports:
		_log("Report popup disabled: forge_logger/enable_reports is off.")
		return
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
	var popup_theme: Theme = config.load_popup_theme()
	if popup_theme != null:
		popup.theme = popup_theme
	# Use a CanvasLayer so the popup always renders on top and is not affected by scene transforms.
	var canvas_layer: CanvasLayer = CanvasLayer.new()
	canvas_layer.layer = 100
	canvas_layer.name = "ForgeLoggerPopupLayer"
	canvas_layer.add_child(popup)
	_add_to_root(canvas_layer)


## Manually start a session (if auto_start_session is false). Applies
## session_metadata and, with heartbeat_interval > 0, starts heartbeats. On
## success, anything left in the offline queue is retried in the background.
## Starting again after end_session() opens a new session.
func start_session() -> bool:
	return await _start_session_internal()


## True while a session is running (started and not ended with end_session()).
func is_session_active() -> bool:
	return session_manager.is_active()


## Play analytics: queue an event for the current session. Events are batched
## and sent within ~5 s (TRACK_FLUSH_INTERVAL), or right away with flush().
## Fire-and-forget — nothing is awaited. Events tracked before the session
## starts are sent once it does. Example:
##   ForgeLogger.track("play.level_started", {"level": "1"})
func track(event_type: String, payload: Dictionary = {}) -> void:
	if not config.is_ingest_configured():
		if not _warned_unconfigured_track:
			_warned_unconfigured_track = true
			_log("track() ignored: set forge_logger/api_key (or point base_url at your own backend).")
		return
	var session_id: String = session_manager.get_session_id() if session_manager.is_active() else ""
	event_manager.track(event_type, payload, session_id)


## Send tracked events now. Returns true when nothing is left to send.
func flush() -> bool:
	if event_manager.pending_tracked() == 0:
		return true
	if not session_manager.is_active():
		return false
	return await event_manager.flush_tracked(session_manager.get_session_id())


## End the current session: flush tracked events and send the final heartbeat
## (`ended: true`, `reason`). Heartbeats stop; later track() calls wait for the
## next start_session(). Returns true when the server confirmed the end.
func end_session(reason: String = "quit") -> bool:
	if not session_manager.is_active():
		return false
	_heartbeat_timer.stop()
	await flush()
	var ok: bool = await session_manager.send_heartbeat(true, reason)
	session_manager.mark_ended()
	_web_disarm_end_beacon()
	if config.enable_reports:
		session_manager.clear_crash_marker()
	_log("Session ended (%s)." % reason)
	return ok


## Get current session ID.
func get_session_id() -> String:
	return session_manager.get_session_id()


## Open a public feedback form (forgelogger.dev/f/<link_token>, or your own
## feedback_base_url) in the system browser, with the active session, its
## build, playtime, current scene and checkpoint (from set_context_provider)
## attached to the URL so the response comes back linked to what the player
## just did. With no active session, opens the link with no query parameters —
## the form still works, just without the telemetry tie.
## `extra` adds further query parameters (e.g. {"lang": "de", "utm_campaign": "nextfest"});
## it never overrides session/build/playtime, but an `extra` "scene" or
## "checkpoint" replaces the automatic one.
## Example:
##   var button_pressed := func(): ForgeLogger.open_feedback("AbCdEfGh12345678")
func open_feedback(link_token: String, extra: Dictionary = {}) -> void:
	var url: String = "%s/f/%s" % [config.get_feedback_base_url(), link_token.uri_encode()]

	var params: PackedStringArray = PackedStringArray()
	var session_id: String = session_manager.get_session_id()
	if not session_id.is_empty():
		params.append("session=%s" % session_id.uri_encode())
		var build_id: String = session_manager.get_build_id()
		if not build_id.is_empty():
			params.append("build=%s" % build_id.uri_encode())
		# Seconds since this session started (the in-game form sends the same).
		params.append("playtime=%d" % session_manager.get_session_uptime_sec())
		# Where the player is — the server keeps them next to the session only.
		var scene_node: Node = get_tree().current_scene
		if scene_node != null and not extra.has("scene"):
			params.append("scene=%s" % str(scene_node.name).uri_encode())
		var checkpoint: String = _context_checkpoint()
		if not checkpoint.is_empty() and not extra.has("checkpoint"):
			params.append("checkpoint=%s" % checkpoint.uri_encode())

	for key: Variant in extra:
		var k: String = str(key)
		if k.is_empty():
			continue
		params.append("%s=%s" % [k.uri_encode(), str(extra[key]).uri_encode()])

	if params.size() > 0:
		url += "?" + "&".join(params)

	_log("Opening feedback form: %s" % url)
	OS.shell_open(url)


## Show a feedback form inside the game — rendered natively from the form's
## questions on the server, so changing the questions in the dashboard needs
## no new build. `link_token` is the 16 characters after /f/ of a feedback
## link (create one link for the game, e.g. "In game"). Works with mouse,
## keyboard and gamepad; the last fetched form is cached for offline play, and
## answers given offline are queued and sent on a later launch.
## `options` (all optional):
##   locale: String   — language of the fixed labels (default: the game's
##                      TranslationServer locale, then the link's preset, English)
##   pause: bool      — pause the game while the form is open (default false)
##   theme: Theme     — look of the form (default: forge_logger/popup_theme)
##   ui_scale: float  — 0 = automatic by viewport height (default), else a factor
##   layer: int       — CanvasLayer order (default 100)
## Returns the popup (null when the token is malformed). Listen to
## feedback_submitted / feedback_closed, e.g.:
##   ForgeLogger.show_feedback("AbCdEfGh12345678", {"pause": true})
##   await ForgeLogger.feedback_closed
func show_feedback(link_token: String, options: Dictionary = {}) -> Control:
	if is_instance_valid(_feedback_popup):
		return _feedback_popup
	if not feedback_manager.is_valid_link_token(link_token):
		push_error("[ForgeLogger] show_feedback: '%s' is not a feedback link token (the 16 characters after /f/)." % link_token)
		return null
	# Dynamic load — runtime-only UI instantiation, like the report popup.
	var scene: PackedScene = load("res://addons/forge_logger/ui/feedback_popup.tscn") as PackedScene
	if scene == null:
		_log("Feedback popup scene not found.")
		return null
	var popup: Control = scene.instantiate() as Control
	var effective: Dictionary = options.duplicate()
	if not effective.has("theme"):
		var popup_theme: Theme = config.load_popup_theme()
		if popup_theme != null:
			effective["theme"] = popup_theme
	popup.call("setup", self, link_token, effective)
	var canvas_layer: CanvasLayer = CanvasLayer.new()
	canvas_layer.layer = int(options.get("layer", 100))
	canvas_layer.name = "ForgeLoggerFeedbackLayer"
	canvas_layer.process_mode = Node.PROCESS_MODE_ALWAYS
	canvas_layer.add_child(popup)
	_add_to_root(canvas_layer)
	_feedback_popup = popup
	return popup


## Adds a popup layer to the root viewport. Called from a _ready() during the
## game's start (a main scene asking "what happened?" right after a crash),
## the root is still busy setting up its children and refuses add_child —
## the popup would stay outside the tree, never shown yet counted as open.
## Then it is added once the start is done.
func _add_to_root(layer: Node) -> void:
	var root: Window = get_tree().root
	if root.is_node_ready():
		root.add_child(layer)
	else:
		root.add_child.call_deferred(layer)


## Is the in-game feedback form open?
func is_feedback_open() -> bool:
	return is_instance_valid(_feedback_popup)


## Fetch a feedback form ahead of time so show_feedback() can render it even
## offline (e.g. at game start, before a festival booth loses its network).
## True when an open form is cached and ready.
func prefetch_feedback(link_token: String) -> bool:
	return await feedback_manager.prefetch(link_token)


## Retry everything in the offline queue (bug reports and feedback answers).
## Returns how many were sent.
func retry_queued() -> int:
	return await report_queue.retry_all()


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
	if not config.is_ingest_configured():
		_log("Cannot send events: set forge_logger/api_key (or point base_url at your own backend).")
		return false
	return await event_manager.send_events(session_id)


## Post a single event immediately to the API without storing it.
## Waits for session to be ready before posting.
## Returns true if the event was sent successfully.
func post_event(event_type: String, payload: Dictionary = {}) -> bool:
	await await_session_ready()
	var session_id: String = session_manager.get_session_id()
	if not config.is_ingest_configured():
		_log("Cannot post event: set forge_logger/api_key (or point base_url at your own backend).")
		return false
	return await event_manager.post_event_immediate(session_id, event_type, payload)


## Get the number of stored events.
func get_event_count() -> int:
	return event_manager.event_count()


## Clear all stored events without sending them.
func clear_events() -> void:
	event_manager.clear_events()


## Register a callable returning a Dictionary of game-specific report context,
## merged into every report (including popup reports, where no custom_data
## flows). Keys matching the API context fields (checkpoint, playerPosition,
## sceneName, ...) are sent top-level; anything else lands in context.extra.
## Example:
##   ForgeLogger.set_context_provider(func() -> Dictionary:
##       return {"checkpoint": "level_3", "playerPosition": {"x": 1.0, "y": 2.0}})
func set_context_provider(provider: Callable) -> void:
	_context_provider = provider


## Check API health.
func check_health() -> Dictionary:
	return await http.check_health()


# ---- Internal ----


## The `checkpoint` the game-registered context provider returns right now,
## or "" (no provider, no such key, or an empty value).
func _context_checkpoint() -> String:
	if not _context_provider.is_valid():
		return ""
	var provided: Variant = _context_provider.call()
	if not provided is Dictionary:
		return ""
	var value: Variant = (provided as Dictionary).get("checkpoint", null)
	if value == null:
		return ""
	return str(value).strip_edges()


## Snapshot of runtime context (ReportContextDto) at report time: current
## scene, platform, build version, performance counters, uptime, and whatever
## the game-registered context provider returns.
func _build_context() -> Dictionary:
	var context: Dictionary = {}

	var scene: Node = get_tree().current_scene
	if scene != null:
		context["sceneName"] = str(scene.name)
	context["platform"] = OS.get_name()
	if config.game_version != "":
		context["buildVersion"] = config.game_version
	# Locale is personally-identifying telemetry — same opt-in as the session.
	if config.collect_device_info:
		context["locale"] = OS.get_locale()

	context["performance"] = {
		"fps": Engine.get_frames_per_second(),
		"frameTimeMs": snappedf(Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0, 0.01),
		"memoryMb": snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"vramMb": snappedf(Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0, 0.1),
		"nodeCount": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphanNodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
	}
	context["extra"] = {"uptimeSec": int(Time.get_ticks_msec() / 1000.0)}

	if _context_provider.is_valid():
		var provided: Variant = _context_provider.call()
		if provided is Dictionary:
			for key: Variant in (provided as Dictionary):
				var k: String = str(key)
				var value: Variant = (provided as Dictionary)[key]
				if k == "extra" or k == "performance":
					if value is Dictionary:
						(context[k] as Dictionary).merge(value as Dictionary, true)
				elif k in CONTEXT_FIELDS:
					context[k] = value
				else:
					(context["extra"] as Dictionary)[k] = value

	return context


## Prefer the in-memory capture: it works in release exports (where godot.log
## stays buffered until exit) and includes error backtraces. Falls back to
## reading log files from disk when capture is unavailable or empty.
func _upload_logs(session_id: String) -> Array[Dictionary]:
	if log_capture != null:
		var refs: Array[Dictionary] = await upload_manager.upload_captured_log(session_id, log_capture.get_text())
		if refs.size() > 0:
			return refs
	return await upload_manager.upload_all_logs(session_id)


func _submit_or_queue(payload: Dictionary) -> String:
	if not config.is_ingest_configured():
		_log("Cannot submit report: set forge_logger/api_key (or point base_url at your own backend).")
		report_queue.enqueue(payload)
		return ""

	var result: Dictionary = await http.submit_report(payload)
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


## Called by the feedback popup when it closes.
func _on_feedback_popup_closed(link_token: String, submitted: bool) -> void:
	_feedback_popup = null
	feedback_closed.emit(link_token, submitted)


func _on_flush_timer() -> void:
	if event_manager.pending_tracked() > 0 and session_manager.is_active():
		flush()


func _on_heartbeat_timer() -> void:
	if _heartbeat_in_flight or not session_manager.is_active():
		return
	_heartbeat_in_flight = true
	await session_manager.send_heartbeat()
	_heartbeat_in_flight = false


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST:
		# Clean shutdown — remove crash marker
		if config.enable_reports:
			session_manager.clear_crash_marker()
		# With auto_accept_quit the engine quits right after this notification;
		# a game that asks "really quit?" ends the session on _exit_tree instead.
		if get_tree().auto_accept_quit:
			_end_session_on_shutdown("window_closed")


func _exit_tree() -> void:
	_end_session_on_shutdown("quit")
	if log_capture != null:
		OS.call("remove_logger", log_capture)
		log_capture = null


## Best-effort session end when no further frame will run: blocking requests
## with a short timeout (desktop/mobile), or the page's keepalive beacon (web).
func _end_session_on_shutdown(reason: String) -> void:
	if session_manager == null or not session_manager.is_active():
		return
	_heartbeat_timer.stop()
	# Session end on shutdown is part of play analytics: only with heartbeats on,
	# so games that do not use them keep quitting without extra requests.
	var analytics: bool = config.heartbeat_interval > 0.0
	if OS.has_feature("web"):
		if analytics:
			_web_fire_end_beacon(reason)
			session_manager.mark_ended()
		return
	if event_manager.pending_tracked() > 0:
		event_manager.flush_tracked_blocking(session_manager.get_session_id())
	if analytics:
		session_manager.send_end_blocking(reason)


# ---- Web: end the session when the page goes away ----
# Closing the tab never reaches GDScript, so on web exports a small JS handler
# sends the final heartbeat on `pagehide` with fetch(keepalive), which the
# browser lets finish after the page is gone.


func _web_arm_end_beacon() -> void:
	if not OS.has_feature("web"):
		return
	var url: String = config.base_url.rstrip("/") + HEARTBEAT_PATH % session_manager.get_session_id()
	var js: String = """
(function () {
  var s = window.__forgeLoggerSession = window.__forgeLoggerSession || {};
  s.url = %s; s.token = %s; s.start = performance.now() - %d; s.done = false;
  s.send = function (reason) {
    var t = window.__forgeLoggerSession;
    if (!t || t.done) { return; }
    t.done = true;
    try {
      var h = { 'Content-Type': 'application/json' };
      if (t.token) { h['Authorization'] = 'Bearer ' + t.token; }
      fetch(t.url, { method: 'POST', keepalive: true, headers: h, body: JSON.stringify({
        elapsedS: Math.max(0, Math.floor((performance.now() - t.start) / 1000)),
        ended: true, endReason: reason || 'window_closed' }) });
    } catch (e) {}
  };
  if (!s.installed) {
    s.installed = true;
    window.addEventListener('pagehide', function () { window.__forgeLoggerSession.send('window_closed'); });
  }
})();
""" % [JSON.stringify(url), JSON.stringify(config.api_key), session_manager.elapsed_seconds() * 1000]
	JavaScriptBridge.eval(js, true)


func _web_fire_end_beacon(reason: String) -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("window.__forgeLoggerSession && window.__forgeLoggerSession.send(%s);" % JSON.stringify(reason), true)


func _web_disarm_end_beacon() -> void:
	if OS.has_feature("web"):
		JavaScriptBridge.eval("if (window.__forgeLoggerSession) { window.__forgeLoggerSession.done = true; }", true)


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
