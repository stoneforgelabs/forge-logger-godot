class_name ForgeLoggerSessionManager
extends RefCounted
## Manages game session lifecycle: creation, persistence, and unclean-shutdown
## detection. Note: this is NOT a crash handler — it captures no stack traces or
## dumps; it only notices an unclean exit and retries already-queued reports.

const LOG_PREFIX: String = "[ForgeLogger] "
const SESSION_FILE: String = "user://forge_logger_session.json"
const CRASH_MARKER_FILE: String = "user://forge_logger_crash_marker"

var current_session: ForgeLoggerModels.SessionData = null
var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient) -> void:
	_config = config
	_http = http


func build_start_session_payload() -> Dictionary:
	var scene_name: String = ""
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree and tree.current_scene:
		scene_name = tree.current_scene.name

	var channel: String = _config.environment
	# Map config environment values to API channel enum (dev, qa, alpha, beta, staging, prod).
	match _config.environment:
		"development":
			channel = "dev"
		"production":
			channel = "prod"

	var build: Dictionary = {
		"version": _config.game_version,
		"platform": OS.get_name(),
	}
	if _config.build_hash != "":
		build["gitCommit"] = _config.build_hash
	build["channel"] = channel

	# Device model and locale are personally-identifiable telemetry, so they are
	# gated behind config.collect_device_info (opt-in). When disabled, the
	# payload still carries non-identifying build/engine/platform metadata.
	var collect_device_info: bool = _config.collect_device_info

	var player: Dictionary = {
		"deviceId": OS.get_model_name() if collect_device_info else "",
	}

	var metadata: Dictionary = {
		"engineVersion": Engine.get_version_info().get("string", "unknown"),
		"locale": OS.get_locale() if collect_device_info else "",
		"currentScene": scene_name,
		"startedAt": Time.get_datetime_string_from_system(true),
		"gameName": _config.game_name,
	}

	var payload: Dictionary = {
		"build": build,
		"player": player,
		"metadata": metadata,
	}
	return payload


func start_session() -> bool:
	if _config.project_id.is_empty():
		_log("Cannot start session: project_id is not configured.")
		return false

	var payload: Dictionary = build_start_session_payload()
	var result: Dictionary = await _http.start_session(_config.project_id, payload)

	if result.get("success", false):
		var body: Dictionary = result.get("body", {})
		current_session = ForgeLoggerModels.SessionData.new()
		current_session.session_id = str(body.get("id", body.get("sessionId", "")))
		current_session.project_id = _config.project_id
		var meta: Dictionary = payload.get("metadata", {})
		var build: Dictionary = payload.get("build", {})
		var player: Dictionary = payload.get("player", {})
		current_session.started_at = meta.get("startedAt", "")
		current_session.game_version = build.get("version", "")
		current_session.build_hash = build.get("gitCommit", "")
		current_session.engine_version = meta.get("engineVersion", "")
		current_session.platform = build.get("platform", "")
		current_session.device = player.get("deviceId", "")
		current_session.locale = meta.get("locale", "")
		current_session.current_scene = meta.get("currentScene", "")
		_save_session()
		_write_crash_marker()
		_log("Session started: %s" % current_session.session_id)
		return true
	else:
		var err_body: Dictionary = result.get("body", {})
		var error_msg: String = str(err_body.get("message", ""))
		_log("Failed to start session (HTTP %d). %s" % [result.get("response_code", 0), error_msg])
		return false


func get_session_id() -> String:
	if current_session:
		return current_session.session_id
	return ""


func has_crash_marker() -> bool:
	return FileAccess.file_exists(CRASH_MARKER_FILE)


func clear_crash_marker() -> void:
	if FileAccess.file_exists(CRASH_MARKER_FILE):
		DirAccess.remove_absolute(CRASH_MARKER_FILE)


func load_previous_session() -> ForgeLoggerModels.SessionData:
	if not FileAccess.file_exists(SESSION_FILE):
		return null
	var file: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.READ)
	if file == null:
		return null
	var text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	if json.parse(text) != OK:
		return null
	var data: Variant = json.data
	if data is Dictionary:
		return ForgeLoggerModels.SessionData.from_dict(data as Dictionary)
	return null


func _save_session() -> void:
	if current_session == null:
		return
	var file: FileAccess = FileAccess.open(SESSION_FILE, FileAccess.WRITE)
	if file == null:
		_log("Failed to save session file.")
		return
	file.store_string(JSON.stringify(current_session.to_dict(), "\t"))
	file.close()


func _write_crash_marker() -> void:
	var file: FileAccess = FileAccess.open(CRASH_MARKER_FILE, FileAccess.WRITE)
	if file == null:
		return
	file.store_string(Time.get_datetime_string_from_system(true))
	file.close()


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
