class_name ForgeLoggerConfig
extends RefCounted
## Configuration holder for the Forge Logger plugin.
## Values are loaded from ProjectSettings or set programmatically.

const SETTINGS_PREFIX: String = "forge_logger/"

# Defaults
const DEFAULT_BASE_URL: String = "https://ingest.forgelogger.dev"
const DEFAULT_API_KEY: String = ""
const DEFAULT_GAME_NAME: String = ""
const DEFAULT_GAME_VERSION: String = "0.0.1"
const DEFAULT_BUILD_HASH: String = ""
const DEFAULT_ENVIRONMENT: String = "development"
const DEFAULT_ENABLE_LOGS: bool = true
const DEFAULT_ENABLE_SCREENSHOT: bool = false
const DEFAULT_AUTO_START_SESSION: bool = true
const DEFAULT_COLLECT_DEVICE_INFO: bool = false
const DEFAULT_ENABLE_REPORT_HOTKEY: bool = true
const DEFAULT_FEEDBACK_BASE_URL: String = ""
const DEFAULT_POPUP_THEME: String = ""
const DEFAULT_ENABLE_REPORTS: bool = true
const DEFAULT_HEARTBEAT_INTERVAL: float = 0.0
const DEFAULT_LOG_REQUESTS: bool = false
## Public feedback form host used when `feedback_base_url` is left empty.
## Distinct from `base_url` (the ingest API) — this is the player-facing
## web page opened by `open_feedback()`.
const FEEDBACK_BASE_URL_FALLBACK: String = "https://forgelogger.dev"

var base_url: String = DEFAULT_BASE_URL
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
## When false, the F8 report popup is never wired up (open_feedback() and the
## rest of the public API still work) — for games that only want the web
## feedback form. Defaults to true, matching pre-existing behavior.
var enable_report_hotkey: bool = DEFAULT_ENABLE_REPORT_HOTKEY
## Host of the public feedback form opened by open_feedback(). Empty means
## the hosted default (FEEDBACK_BASE_URL_FALLBACK); set it to point players
## at a self-hosted feedback frontend.
var feedback_base_url: String = DEFAULT_FEEDBACK_BASE_URL
## Theme resource (res://….tres) applied to the plugin's popups — the bug
## report popup and the in-game feedback form. Empty = the project's default
## look. Style the form's own parts through the ForgeLogger* theme type
## variations (see the README).
var popup_theme: String = DEFAULT_POPUP_THEME
## When false the plugin is a pure analytics client: no F8 action or report
## popup, no engine log capture, and nothing written to user:// (no crash
## marker, session file, offline queue or cached feedback form). Reports from
## code are refused. In-game feedback forms still work, but unsent answers and
## the form copy then live in memory only and are lost when the game quits.
var enable_reports: bool = DEFAULT_ENABLE_REPORTS
## Play analytics: seconds between session heartbeats (elapsed play time).
## 0 = off. The final heartbeat (ended) is sent on end_session() and, best
## effort, when the window closes.
var heartbeat_interval: float = DEFAULT_HEARTBEAT_INTERVAL
## Print every request body to the console. Off by default — bodies can be
## large and repetitive (heartbeats, event batches). Failures are always logged.
var log_requests: bool = DEFAULT_LOG_REQUESTS


## The ingest backend derives the project from the logger token, so a token is
## the only required setting. A custom base_url without a token also counts as
## configured — self-hosted ingest may run without auth.
func is_ingest_configured() -> bool:
	return not api_key.is_empty() or base_url != DEFAULT_BASE_URL


## Host to open the public feedback form on (open_feedback()), with the
## trailing slash stripped so callers can join "/f/<token>" directly.
func get_feedback_base_url() -> String:
	if feedback_base_url.is_empty():
		return FEEDBACK_BASE_URL_FALLBACK
	return feedback_base_url.rstrip("/")


## The Theme from `popup_theme`, or null when unset or not a Theme.
func load_popup_theme() -> Theme:
	if popup_theme.is_empty():
		return null
	if not ResourceLoader.exists(popup_theme):
		push_warning("[ForgeLogger] popup_theme not found: %s" % popup_theme)
		return null
	var resource: Resource = load(popup_theme)
	if resource is Theme:
		return resource as Theme
	push_warning("[ForgeLogger] popup_theme is not a Theme resource: %s" % popup_theme)
	return null


static func _define_project_settings() -> void:
	var settings: Array[Dictionary] = [
		{"name": "base_url", "type": TYPE_STRING, "default": DEFAULT_BASE_URL, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "https://ingest.forgelogger.dev"},
		{"name": "api_key", "type": TYPE_STRING, "default": DEFAULT_API_KEY, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Your project's logger token (flg_...); project scope is derived from it"},
		{"name": "game_name", "type": TYPE_STRING, "default": DEFAULT_GAME_NAME, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Display name of your game"},
		{"name": "game_version", "type": TYPE_STRING, "default": DEFAULT_GAME_VERSION, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "e.g. 1.0.0"},
		{"name": "build_hash", "type": TYPE_STRING, "default": DEFAULT_BUILD_HASH, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "Optional git commit hash"},
		{"name": "environment", "type": TYPE_STRING, "default": DEFAULT_ENVIRONMENT, "hint": PROPERTY_HINT_ENUM, "hint_string": "development,staging,production"},
		{"name": "enable_logs", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_LOGS, "hint": PROPERTY_HINT_NONE},
		{"name": "enable_screenshot", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_SCREENSHOT, "hint": PROPERTY_HINT_NONE},
		{"name": "auto_start_session", "type": TYPE_BOOL, "default": DEFAULT_AUTO_START_SESSION, "hint": PROPERTY_HINT_NONE},
		{"name": "collect_device_info", "type": TYPE_BOOL, "default": DEFAULT_COLLECT_DEVICE_INFO, "hint": PROPERTY_HINT_NONE},
		{"name": "enable_report_hotkey", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_REPORT_HOTKEY, "hint": PROPERTY_HINT_NONE},
		{"name": "feedback_base_url", "type": TYPE_STRING, "default": DEFAULT_FEEDBACK_BASE_URL, "hint": PROPERTY_HINT_PLACEHOLDER_TEXT, "hint_string": "https://forgelogger.dev (leave empty for the hosted default)"},
		{"name": "popup_theme", "type": TYPE_STRING, "default": DEFAULT_POPUP_THEME, "hint": PROPERTY_HINT_FILE, "hint_string": "*.tres,*.res"},
		{"name": "enable_reports", "type": TYPE_BOOL, "default": DEFAULT_ENABLE_REPORTS, "hint": PROPERTY_HINT_NONE},
		{"name": "heartbeat_interval", "type": TYPE_FLOAT, "default": DEFAULT_HEARTBEAT_INTERVAL, "hint": PROPERTY_HINT_RANGE, "hint_string": "0,3600,1,or_greater,suffix:s"},
		{"name": "log_requests", "type": TYPE_BOOL, "default": DEFAULT_LOG_REQUESTS, "hint": PROPERTY_HINT_NONE},
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
	cfg.enable_report_hotkey = _get_setting("enable_report_hotkey", DEFAULT_ENABLE_REPORT_HOTKEY)
	cfg.feedback_base_url = _get_setting("feedback_base_url", DEFAULT_FEEDBACK_BASE_URL)
	cfg.popup_theme = _get_setting("popup_theme", DEFAULT_POPUP_THEME)
	cfg.enable_reports = _get_setting("enable_reports", DEFAULT_ENABLE_REPORTS)
	cfg.heartbeat_interval = maxf(float(_get_setting("heartbeat_interval", DEFAULT_HEARTBEAT_INTERVAL)), 0.0)
	cfg.log_requests = _get_setting("log_requests", DEFAULT_LOG_REQUESTS)
	return cfg


static func _get_setting(key: String, default_value: Variant) -> Variant:
	var full_key: String = SETTINGS_PREFIX + key
	if ProjectSettings.has_setting(full_key):
		return ProjectSettings.get_setting(full_key)
	return default_value
