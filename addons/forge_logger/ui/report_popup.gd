extends PanelContainer
## In-game bug report popup UI.
## Provides fields for title, description, and log attachment.
## After successful submission, shows the report ID with a copy button.

@onready var title_input: LineEdit = %TitleInput
@onready var description_input: TextEdit = %DescriptionInput
@onready var attach_logs_check: CheckBox = %AttachLogsCheck
@onready var attach_screenshot_check: CheckBox = %AttachScreenshotCheck
@onready var submit_button: Button = %SubmitButton
@onready var cancel_button: Button = %CancelButton
@onready var status_label: Label = %StatusLabel
@onready var form_content: VBoxContainer = %FormContent
@onready var success_content: VBoxContainer = %SuccessContent
@onready var report_id_input: LineEdit = %ReportIdInput
@onready var copy_button: Button = %CopyButton
@onready var close_button: Button = %CloseButton

var _auto_close_timer: SceneTreeTimer = null


func _ready() -> void:
	_clamp_to_viewport()
	get_tree().root.size_changed.connect(_clamp_to_viewport)

	attach_logs_check.button_pressed = true
	# Screenshot option follows the enable_screenshot project setting (opt-in):
	# hidden + unchecked unless the developer turned it on.
	var fl: Node = get_node_or_null("/root/ForgeLogger")
	var screenshots_enabled: bool = fl != null and fl.config != null and fl.config.enable_screenshot
	attach_screenshot_check.button_pressed = screenshots_enabled
	attach_screenshot_check.visible = screenshots_enabled

	submit_button.pressed.connect(_on_submit_pressed)
	cancel_button.pressed.connect(_on_cancel_pressed)
	copy_button.pressed.connect(_on_copy_pressed)
	close_button.pressed.connect(_close)

	status_label.text = ""
	success_content.visible = false
	form_content.visible = true


func _on_submit_pressed() -> void:
	var title_text: String = title_input.text.strip_edges()
	if title_text.is_empty():
		status_label.text = "Title is required."
		return

	submit_button.disabled = true
	status_label.text = "Submitting..."

	var description_text: String = description_input.text
	var attach_logs: bool = attach_logs_check.button_pressed
	var attach_screenshot: bool = attach_screenshot_check.button_pressed

	var forge_logger: Node = get_node_or_null("/root/ForgeLogger")
	if forge_logger == null:
		status_label.text = "ForgeLogger autoload not found."
		submit_button.disabled = false
		return

	var report_id: String = await forge_logger.submit_ui_report(
		title_text,
		description_text,
		attach_logs,
		attach_screenshot,
	)

	if not report_id.is_empty():
		_show_success(report_id)
	else:
		status_label.text = "Failed — report queued for retry."
		submit_button.disabled = false


func _show_success(report_id: String) -> void:
	form_content.visible = false
	success_content.visible = true
	report_id_input.text = report_id
	DisplayServer.clipboard_set(report_id)

	# Auto-close after 10 seconds.
	_auto_close_timer = get_tree().create_timer(10.0)
	_auto_close_timer.timeout.connect(_close)


func _on_copy_pressed() -> void:
	DisplayServer.clipboard_set(report_id_input.text)
	copy_button.text = "Copied!"
	await get_tree().create_timer(1.0).timeout
	if is_instance_valid(copy_button):
		copy_button.text = "Copy ID"


func _on_cancel_pressed() -> void:
	_close()


func _input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		_close()
		get_viewport().set_input_as_handled()


func _clamp_to_viewport() -> void:
	var vp_size: Vector2 = get_viewport_rect().size
	# Limit the panel so it always fits within the visible viewport with some padding.
	var panel_node: PanelContainer = $CenterContainer/Panel as PanelContainer
	var max_w: float = maxf(vp_size.x - 32.0, 200.0)
	var max_h: float = maxf(vp_size.y - 32.0, 200.0)
	panel_node.custom_minimum_size.x = minf(300.0, max_w)
	panel_node.size = Vector2(minf(panel_node.size.x, max_w), minf(panel_node.size.y, max_h))
	custom_minimum_size = Vector2.ZERO
	size = vp_size


func _close() -> void:
	# Remove the CanvasLayer wrapper created by ForgeLogger.show_report_popup().
	var parent_node: Node = get_parent()
	if parent_node is CanvasLayer:
		parent_node.queue_free()
	else:
		queue_free()
