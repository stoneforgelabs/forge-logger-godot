extends Logger
## In-memory ring buffer of engine log output, fed by the scriptable Logger
## API (Godot 4.5+). Attached to bug reports instead of reading godot.log,
## which release exports keep buffered on disk until the game exits.
##
## This file is loaded dynamically by ForgeLogger (never preloaded or
## referenced by class_name), so the rest of the plugin still parses on
## engines that predate the Logger class.

const MAX_LINES: int = 500

var _lines: PackedStringArray = PackedStringArray()
var _mutex: Mutex = Mutex.new()


func _log_message(message: String, _error: bool) -> void:
	_append(message)


func _log_error(function: String, file: String, line: int, code: String, rationale: String, _editor_notify: bool, error_type: int, script_backtraces: Array[ScriptBacktrace]) -> void:
	var kind: String = "ERROR"
	match error_type:
		ERROR_TYPE_WARNING:
			kind = "WARNING"
		ERROR_TYPE_SCRIPT:
			kind = "SCRIPT ERROR"
		ERROR_TYPE_SHADER:
			kind = "SHADER ERROR"
	var text: String = "%s: %s\n   at: %s (%s:%d)\n" % [kind, rationale if not rationale.is_empty() else code, function, file, line]
	for backtrace: ScriptBacktrace in script_backtraces:
		if backtrace.get_frame_count() > 0:
			text += backtrace.format(3) + "\n"
	_append(text)


## Full captured output as one string. Safe to call from any thread.
func get_text() -> String:
	_mutex.lock()
	var text: String = "".join(_lines)
	_mutex.unlock()
	return text


func _append(text: String) -> void:
	if not text.ends_with("\n"):
		text += "\n"
	# Logger callbacks may fire from any thread, so the buffer is mutex-guarded.
	_mutex.lock()
	_lines.append(text)
	if _lines.size() > MAX_LINES:
		_lines = _lines.slice(_lines.size() - MAX_LINES)
	_mutex.unlock()
