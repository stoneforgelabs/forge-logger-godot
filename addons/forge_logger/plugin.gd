@tool
extends EditorPlugin
## Forge Logger editor plugin.
## Registers the ForgeLogger autoload singleton and exposes
## configuration via ProjectSettings.

const AUTOLOAD_NAME: String = "ForgeLogger"
const AUTOLOAD_PATH: String = "res://addons/forge_logger/forge_logger.gd"


func _enter_tree() -> void:
	ForgeLoggerConfig._define_project_settings()
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, AUTOLOAD_PATH)
	print("[ForgeLogger] Plugin enabled.")


func _exit_tree() -> void:
	remove_autoload_singleton(AUTOLOAD_NAME)
	print("[ForgeLogger] Plugin disabled.")
