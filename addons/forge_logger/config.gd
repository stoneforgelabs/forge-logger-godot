class_name ForgeLoggerConfig
extends RefCounted
## Configuration holder for the Forge Logger plugin.
## Values are loaded from ProjectSettings or set programmatically.

const SETTINGS_PREFIX: String = "forge_logger/"

# Defaults
const DEFAULT_BASE_URL: String = "https://ingest.forgelogger.dev"
const DEFAULT_PROJECT_ID: String = ""
const DEFAULT_API_KEY: String = ""
const DEFAULT_GAME_NAME: String = ""
const DEFAULT_GAME_VERSION: String = "0.0.1"
const DEFAULT_BUILD_HASH: String = ""
const DEFAULT_ENVIRONMENT: String = "development"
const DEFAULT_ENABLE_LOGS: bool = true
const DEFAULT_ENABLE_SCREENSHOT: bool = false
const DEFAULT_AUTO_START_SESSION: bool = true
const DEFAULT_COLLECT_DEVICE_INFO: bool = false

var base_url: String = DEFAULT_BASE_URL
var project_id: String = DEFAULT_PROJECT_ID
var api_key: String = DEFAULT_API_KEY
var game_name: String = DEFAULT_GAME_NAME
var game_version: String = DEFAULT_GAME_VERSION
var build_hash: String = DEFAULT_BUILD_HASH
var environment: String = DEFAULT_ENVIRONMENT
var enable_logs: bool = DEFAULT_ENABLE_LOGS
var enable_screenshot: bool = DEFAULT_ENABLE_SCREENSHOT
var auto_start_session: bool = DEFAULT_AUTO_START_SESSION
## When false, the start-session payload omits the device model and locale so
## players are not personally identified. Defaults to false (opt-in).
var collect_device_info: bool = DEFAULT_COLLECT_DEVICE_INFO


static func _define_project_settings() -> void:
	var settings: Array[Dictionary] = [
		{"name": "base_url", "type": TYPE_STRING, "default": DEFAULT_BASE_URL, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "https://ingest.forgelogger.dev"},
		{"name": "project_id", "type": TYPE_STRING, "default": DEFAULT_PROJECT_ID, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Your project UUID from Forge Logger API"},
		{"name": "api_key", "type": TYPE_STRING, "default": DEFAULT_API_KEY, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Optional API key for authentication"},
		{"name": "game_name", "type": TYPE_STRING, "default": DEFAULT_GAME_NAME, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Display name of your game"},
		{"name": "game_version", "type": TYPE_STRING, "default": DEFAULT_GAME_VERSION, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "e.g. 1.0.0"},
		{"name": "build_hash", "type": TYPE_STRING, "default": DEFAULT_BUILD_HASH, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Optional git commit hash"},
		{"name": "environment", "type": TYPE_STRING, "default": DEFAULT_ENVIRONMENT, "hint": PROPERTY_HINT_ENUM, "hint_string": "development,staging,production"},
		{"name": "enable_logs", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_LOGS, "hint": PROPERTY_HINT_NONE},
		{"name": "enable_screenshot", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_SCREENSHOT, "hint": PROPERTY_HINT_NONE},
		{"name": "auto_start_session", "type": TYPE_BOOL, "default": DEFAULT_AUTO_START_SESSION, "hint": PROPERTY_HINT_NONE},
		{"name": "collect_device_info", "type": TYPE_BOOL, "default": DEFAULT_COLLECT_DEVICE_INFO, "hint": PROPERTY_HINT_NONE},
	]
	for s: Dictionary in settings:
		var key: String = SETTINGS_PREFIX + s["name"]
		if not ProjectSettings.has_setting(key):
			ProjectSettings.set_setting(key, s["default"])
		ProjectSettings.set_initial_value(key, s["default"])
		ProjectSettings.add_property_info({
			"name": key,
			"type": s["type"],
			"hint": s["hint"],
			"hint_string": s.get("hint_string", ""),
		})


static func load_from_project_settings() -> ForgeLoggerConfig:
	var cfg: ForgeLoggerConfig = ForgeLoggerConfig.new()
	cfg.base_url = _get_setting("base_url", DEFAULT_BASE_URL)
	cfg.project_id = _get_setting("project_id", DEFAULT_PROJECT_ID)
	cfg.api_key = _get_setting("api_key", DEFAULT_API_KEY)
	cfg.game_name = _get_setting("game_name", DEFAULT_GAME_NAME)
	if cfg.game_name.is_empty():
		# Fall back to Godot's standard project name so sessions are labelled
		# even when the plugin setting was never filled in.
		cfg.game_name = str(ProjectSettings.get_setting("application/config/name", ""))
	cfg.game_version = _get_setting("game_version", DEFAULT_GAME_VERSION)
	if cfg.game_version.is_empty() or cfg.game_version == DEFAULT_GAME_VERSION:
		# Same for the standard project version — an explicit plugin setting
		# still wins over application/config/version.
		var app_version: String = str(ProjectSettings.get_setting("application/config/version", ""))
		if not app_version.is_empty():
			cfg.game_version = app_version
	cfg.build_hash = _get_setting("build_hash", DEFAULT_BUILD_HASH)
	cfg.environment = _get_setting("environment", DEFAULT_ENVIRONMENT)
	cfg.enable_logs = _get_setting("enable_logs", DEFAULT_ENABLE_LOGS)
	cfg.enable_screenshot = _get_setting("enable_screenshot", DEFAULT_ENABLE_SCREENSHOT)
	cfg.auto_start_session = _get_setting("auto_start_session", DEFAULT_AUTO_START_SESSION)
	cfg.collect_device_info = _get_setting("collect_device_info", DEFAULT_COLLECT_DEVICE_INFO)
	return cfg


static func _get_setting(key: String, default_value: Variant) -> Variant:
	var full_key: String = SETTINGS_PREFIX + key
	if ProjectSettings.has_setting(full_key):
		return ProjectSettings.get_setting(full_key)
	return default_value
