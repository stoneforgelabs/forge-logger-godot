extends Control
## In-game feedback form (FB-09), opened by ForgeLogger.show_feedback().
##
## Renders the blocks of a form fetched from the ingest API — stars, text,
## price points, yes / no, single choice, contact with its consent, raffle —
## so the questions change in the dashboard without a new build. Mouse,
## keyboard and gamepad: every input is focusable, with explicit focus
## neighbours so the D-pad walks the form top to bottom and across each row;
## B / Esc (ui_cancel) closes it.
##
## Look: the Theme from show_feedback({"theme": …}) or forge_logger/popup_theme,
## merged over built-in defaults. Theme type variations you can style:
##   ForgeLoggerPanel (PanelContainer), ForgeLoggerTitle, ForgeLoggerQuestion,
##   ForgeLoggerHint, ForgeLoggerError (Label), ForgeLoggerPrimaryButton,
##   ForgeLoggerChoice (Button — answers: yes / no, options, price points),
##   ForgeLoggerStar (Button — icons `star_filled` / `star_empty`),
##   ForgeLoggerConsent (CheckBox — icons `checked` / `unchecked`) and
##   ForgeLoggerConsentText (Label — the consent wording next to it).

const REFERENCE_HEIGHT: float = 720.0
const MAX_PANEL_WIDTH: float = 640.0
const MIN_PANEL_WIDTH: float = 240.0
const EDGE_MARGIN: float = 16.0
const MIN_SCROLL_HEIGHT: float = 80.0

const STATE_LOADING: String = "loading"
const STATE_FORM: String = "form"
const STATE_SENDING: String = "sending"
const STATE_MESSAGE: String = "message"
const STATE_THANKS: String = "thanks"

## Forge Logger orange — selected answers and the primary button.
const ACCENT: Color = Color(1.0, 0.416, 0.173)

const EMAIL_PATTERN: String = "^[^@\\s]+@[^@\\s]+\\.[^@\\s.]{2,}$"
const STEAM_URL_PATTERN: String = "(?i)^(?:https?://)?(?:www\\.)?steamcommunity\\.com/(?:id|profiles)/[^/?#]+/?(?:[?#].*)?$"

var _forge_logger: Node = null
var _link_token: String = ""
var _options: Dictionary = {}
var _locale: String = "en"
var _form: Dictionary = {}
var _state: String = STATE_LOADING
var _retry_on_submit: bool = false
var _submitted: bool = false
var _paused_by_us: bool = false
var _closing: bool = false

# The player's draft — survives a re-render (e.g. after the form changed).
var _answers: Dictionary = {}
var _contact_kind: String = "email"
var _contact_value: String = ""
var _share_contact: bool = false
var _raffle: bool = false

var _error_labels: Dictionary = {}
var _field_focus: Dictionary = {}
var _focus_rows: Array = []
var _consent_texts: Dictionary = {}
var _star_buttons: Dictionary = {}
var _star_filled: Texture2D = null
var _star_empty: Texture2D = null

@onready var _panel: PanelContainer = %Panel
@onready var _title: Label = %Title
@onready var _scroll: ScrollContainer = %Scroll
@onready var _content: VBoxContainer = %Content
@onready var _status: Label = %Status
@onready var _close_button: Button = %CloseButton
@onready var _submit_button: Button = %SubmitButton
@onready var _powered_by: Label = %PoweredBy


## Called by ForgeLogger.show_feedback() before the popup enters the tree.
func setup(forge_logger: Node, link_token: String, options: Dictionary = {}) -> void:
	_forge_logger = forge_logger
	_link_token = link_token
	_options = options


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	var custom_theme: Variant = _options.get("theme", null)
	theme = _build_theme(custom_theme as Theme if custom_theme is Theme else null)
	_star_filled = theme.get_icon("star_filled", "ForgeLoggerStar")
	_star_empty = theme.get_icon("star_empty", "ForgeLoggerStar")

	_locale = ForgeLoggerFeedbackI18n.resolve_locale(str(_options.get("locale", "")), TranslationServer.get_locale(), "")

	if bool(_options.get("pause", false)) and not get_tree().paused:
		get_tree().paused = true
		_paused_by_us = true

	_close_button.pressed.connect(_close)
	_submit_button.pressed.connect(_on_submit_pressed)
	_content.minimum_size_changed.connect(_queue_layout)
	get_viewport().size_changed.connect(_apply_scale)
	_apply_scale()

	_load_form()


func _exit_tree() -> void:
	# Freed from outside (scene tree torn down): still restore the pause and
	# tell ForgeLogger the form is gone.
	_finish_close()


# ---- Loading ----


func _load_form() -> void:
	_show_message(_t("loading"), "", false, STATE_LOADING)
	var manager: ForgeLoggerFeedbackManager = _manager()
	if manager == null:
		_show_message(_t("errorTitle"), _t("errorBody"), false)
		return
	var result: Dictionary = await manager.fetch_form(_link_token)
	if not is_inside_tree() or _closing:
		return
	var form: Dictionary = result.get("form", {}) as Dictionary
	_locale = ForgeLoggerFeedbackI18n.resolve_locale(str(_options.get("locale", "")), TranslationServer.get_locale(), str(form.get("defaultLocale", "")) if form.get("defaultLocale", null) is String else "")
	match str(result.get("status", "")):
		ForgeLoggerFeedbackManager.FORM_OK:
			_form = form
			_render_form()
		ForgeLoggerFeedbackManager.FORM_UNAVAILABLE:
			var availability: String = str(form.get("availability", "closed"))
			if availability == "draft" or availability == "not_started":
				_show_message(_t("notOpenTitle"), _t("notOpenBody"), false)
			else:
				_show_message(_t("closedTitle"), _t("closedBody"), false)
		ForgeLoggerFeedbackManager.FORM_NOT_FOUND:
			_show_message(_t("notFoundTitle"), _t("notFoundBody"), false)
		_:
			_show_message(_t("errorTitle"), _t("errorBody"), true)


# ---- Rendering ----


func _render_form() -> void:
	_state = STATE_FORM
	_clear_content()
	_retry_on_submit = false
	var branding: Dictionary = _form.get("branding", {}) as Dictionary if _form.get("branding", null) is Dictionary else {}
	var schema: Dictionary = _form.get("schema", {}) as Dictionary
	var for_children: bool = bool(_form.get("forChildren", false))

	var game_name: String = str(branding.get("gameName", "")) if branding.get("gameName", null) is String else ""
	_title.text = game_name if not game_name.is_empty() else _t("headingGeneric")
	_add_text(_t("subheadingChildren") if for_children else _t("subheading"), &"ForgeLoggerHint", HORIZONTAL_ALIGNMENT_CENTER)
	if for_children:
		_add_text(_t("childrenNotice"), &"ForgeLoggerHint")
	if schema.get("intro", null) is String and not str(schema["intro"]).is_empty():
		_add_text(str(schema["intro"]))

	var blocks: Array = _visible_blocks()
	var any_required: bool = false
	for block: Dictionary in blocks:
		if bool(block.get("required", false)):
			any_required = true
	if any_required:
		_add_text(_t("requiredHint"), &"ForgeLoggerHint")

	for block: Dictionary in blocks:
		match str(block.get("type", "")):
			"rating":
				_render_rating(block)
			"text":
				_render_text(block, true)
			"short_text":
				_render_text(block, false)
			"yes_no":
				_render_yes_no(block)
			"single_choice":
				_render_choices(block, _choice_options(block))
			"price_intent":
				_render_choices(block, _price_options(block))
			"contact":
				_render_contact(block)
			"raffle":
				_render_raffle(block)
			_:
				pass  # A block type from a newer API: skip it, the rest still works.

	_powered_by.text = _t("poweredBy")
	_powered_by.visible = bool(_form.get("poweredBy", true))
	_close_button.text = _t("close")
	_close_button.visible = true
	_close_button.disabled = false
	_submit_button.text = _t("submit")
	_submit_button.visible = true
	_submit_button.disabled = false
	_set_status("")
	_apply_focus_chain([_close_button, _submit_button])
	_queue_layout()
	_focus_first()


func _render_rating(block: Dictionary) -> void:
	var id: String = str(block.get("id", ""))
	var box: VBoxContainer = _add_question(block)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	var stars: Array = []
	for value: int in range(1, 6):
		var star: Button = Button.new()
		star.name = "Star%d" % value
		star.theme_type_variation = &"ForgeLoggerStar"
		star.toggle_mode = true
		star.icon = _star_empty
		star.expand_icon = true
		star.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
		star.custom_minimum_size = Vector2(44, 44)
		star.tooltip_text = _t("starLabel", {"count": value})
		star.pressed.connect(_on_star_pressed.bind(id, value))
		row.add_child(star)
		stars.append(star)
	box.add_child(row)
	var low: String = str(block.get("lowLabel", "")) if block.get("lowLabel", null) is String else ""
	var high: String = str(block.get("highLabel", "")) if block.get("highLabel", null) is String else ""
	if not low.is_empty() or not high.is_empty():
		var captions: HBoxContainer = HBoxContainer.new()
		var low_label: Label = _make_label(low, &"ForgeLoggerHint")
		low_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var high_label: Label = _make_label(high, &"ForgeLoggerHint")
		high_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		high_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		captions.add_child(low_label)
		captions.add_child(high_label)
		captions.custom_minimum_size.x = 5 * 48
		captions.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		box.add_child(captions)
	_star_buttons[id] = stars
	_update_stars(id)
	_add_error_label(box, id)
	_field_focus[id] = stars[0]
	_focus_rows.append(stars)


func _render_text(block: Dictionary, multiline: bool) -> void:
	var id: String = str(block.get("id", ""))
	var box: VBoxContainer = _add_question(block)
	var max_length: int = int(block.get("maxLength", 2000 if multiline else 200))
	var placeholder: String = str(block.get("placeholder", "")) if block.get("placeholder", null) is String else ""
	if placeholder.is_empty():
		placeholder = _t("textPlaceholder")
	var current: String = str(_answers.get(id, "")) if _answers.get(id, null) is String else ""
	var counter: Label = _make_label("", &"ForgeLoggerHint")
	counter.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	var input: Control = null
	if multiline:
		var edit: TextEdit = TextEdit.new()
		edit.name = "Text_%s" % id
		edit.custom_minimum_size = Vector2(0, 96)
		edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		edit.placeholder_text = placeholder
		edit.text = current
		edit.text_changed.connect(func() -> void:
			_on_text_changed(id, edit.text, counter, max_length))
		input = edit
	else:
		var line: LineEdit = LineEdit.new()
		line.name = "Text_%s" % id
		line.max_length = max_length
		line.placeholder_text = placeholder
		line.text = current
		line.text_changed.connect(func(new_text: String) -> void:
			_on_text_changed(id, new_text, counter, max_length))
		input = line
	box.add_child(input)
	box.add_child(counter)
	_update_counter(counter, current, max_length)
	_add_error_label(box, id)
	_field_focus[id] = input
	_focus_rows.append([input])


func _render_yes_no(block: Dictionary) -> void:
	var id: String = str(block.get("id", ""))
	var box: VBoxContainer = _add_question(block)
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	var group: ButtonGroup = ButtonGroup.new()
	var buttons: Array = []
	for value: bool in [true, false]:
		var button: Button = Button.new()
		button.name = "Yes" if value else "No"
		button.text = _t("yes") if value else _t("no")
		button.theme_type_variation = &"ForgeLoggerChoice"
		button.toggle_mode = true
		button.button_group = group
		button.custom_minimum_size = Vector2(120, 40)
		button.set_pressed_no_signal(_answers.get(id, null) is bool and _answers[id] == value)
		button.toggled.connect(func(on: bool) -> void:
			if on:
				_set_answer(id, value))
		row.add_child(button)
		buttons.append(button)
	box.add_child(row)
	_add_error_label(box, id)
	_field_focus[id] = buttons[0]
	_focus_rows.append(buttons)


## One answer out of several ([{value, label}]): a column of toggle buttons in
## one group — a clearer selected state than radio dots, on any background.
func _render_choices(block: Dictionary, options: Array) -> void:
	var id: String = str(block.get("id", ""))
	var box: VBoxContainer = _add_question(block)
	var group: ButtonGroup = ButtonGroup.new()
	var first: Control = null
	for option: Dictionary in options:
		var value: String = str(option.get("value", ""))
		var radio: Button = Button.new()
		radio.name = "Option_%s" % value
		radio.theme_type_variation = &"ForgeLoggerChoice"
		radio.text = str(option.get("label", value))
		radio.alignment = HORIZONTAL_ALIGNMENT_LEFT
		radio.toggle_mode = true
		radio.custom_minimum_size = Vector2(0, 38)
		radio.button_group = group
		radio.set_pressed_no_signal(_answers.get(id, null) is String and str(_answers[id]) == value)
		radio.toggled.connect(func(on: bool) -> void:
			if on:
				_set_answer(id, value))
		box.add_child(radio)
		_focus_rows.append([radio])
		if first == null:
			first = radio
	_add_error_label(box, id)
	if first != null:
		_field_focus[id] = first


func _render_contact(block: Dictionary) -> void:
	var box: VBoxContainer = _add_question(block)
	var kinds: Array = []
	var raw_kinds: Variant = block.get("kinds", [])
	if raw_kinds is Array:
		for kind: Variant in raw_kinds:
			if str(kind) in ["email", "steam_profile"] and not kinds.has(str(kind)):
				kinds.append(str(kind))
	if kinds.is_empty():
		kinds.append("email")
	if not kinds.has(_contact_kind):
		_contact_kind = str(kinds[0])

	var field_label: Label = _make_label("", &"ForgeLoggerHint")
	var help: Label = _make_label(_t("contactSteamHelp"), &"ForgeLoggerHint")
	var input: LineEdit = LineEdit.new()
	input.name = "ContactInput"
	input.text = _contact_value
	input.max_length = 2048
	input.text_changed.connect(func(new_text: String) -> void:
		_contact_value = new_text
		_clear_error("contact"))
	var refresh_kind: Callable = func() -> void:
		var email: bool = _contact_kind == "email"
		field_label.text = _t("contactEmailLabel") if email else _t("contactSteamLabel")
		help.visible = not email
		input.virtual_keyboard_type = LineEdit.KEYBOARD_TYPE_EMAIL_ADDRESS if email else LineEdit.KEYBOARD_TYPE_URL

	if kinds.size() > 1:
		box.add_child(_make_label(_t("contactKindLabel"), &"ForgeLoggerHint"))
		var row: HBoxContainer = HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var group: ButtonGroup = ButtonGroup.new()
		var kind_buttons: Array = []
		for kind: String in kinds:
			var kind_button: Button = Button.new()
			kind_button.name = "Kind_%s" % kind
			kind_button.text = _t("contactKindEmail") if kind == "email" else _t("contactKindSteam")
			kind_button.theme_type_variation = &"ForgeLoggerChoice"
			kind_button.toggle_mode = true
			kind_button.button_group = group
			kind_button.custom_minimum_size = Vector2(120, 36)
			kind_button.set_pressed_no_signal(kind == _contact_kind)
			kind_button.toggled.connect(func(on: bool) -> void:
				if on:
					_contact_kind = kind
					_clear_error("contact")
					refresh_kind.call())
			row.add_child(kind_button)
			kind_buttons.append(kind_button)
		box.add_child(row)
		_focus_rows.append(kind_buttons)

	box.add_child(field_label)
	box.add_child(input)
	box.add_child(help)
	refresh_kind.call()
	_add_error_label(box, "contact")
	_field_focus["contact"] = input
	_focus_rows.append([input])

	var days: int = int(_form.get("contactRetentionDays", 90))
	var consent: CheckBox = _add_consent(box, "shareContact", _t("consentShareContact", {"days": days}), _share_contact)
	consent.toggled.connect(func(on: bool) -> void:
		_share_contact = on
		_clear_error("shareContact"))

	var policy: String = str(_form.get("privacyPolicyUrl", "")) if _form.get("privacyPolicyUrl", null) is String else ""
	if policy.begins_with("https://"):
		var policy_button: Button = Button.new()
		policy_button.name = "PrivacyPolicy"
		policy_button.flat = true
		policy_button.text = _t("footerDeveloperPrivacy")
		policy_button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		policy_button.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		policy_button.pressed.connect(func() -> void: OS.shell_open(policy))
		box.add_child(policy_button)
		_focus_rows.append([policy_button])


func _render_raffle(block: Dictionary) -> void:
	var box: VBoxContainer = _add_question(block)
	if _raffle_entry_open():
		var consent: CheckBox = _add_consent(box, "raffle", _t("consentRaffle"), _raffle)
		consent.toggled.connect(func(on: bool) -> void:
			_raffle = on
			_clear_error("raffle"))
	else:
		# Past the entry deadline (FB-10): nothing to tick — the server would
		# drop the consent silently and the player would believe they entered.
		_raffle = false
		var closed: Label = _make_label(_t("raffleClosed"), &"ForgeLoggerHint")
		closed.name = "RaffleClosed"
		box.add_child(closed)
	var rules_url: String = _raffle_rules_url()
	if not rules_url.is_empty():
		var full_rules: Button = Button.new()
		full_rules.name = "RaffleFullRules"
		full_rules.flat = true
		full_rules.text = _t("raffleFullRulesLink")
		full_rules.alignment = HORIZONTAL_ALIGNMENT_LEFT
		full_rules.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		full_rules.pressed.connect(func() -> void: OS.shell_open(rules_url))
		box.add_child(full_rules)
		_focus_rows.append([full_rules])
	var rules: VBoxContainer = VBoxContainer.new()
	rules.visible = false
	for index: int in range(1, 6):
		rules.add_child(_make_label("• " + _t("raffleRule%d" % index), &"ForgeLoggerHint"))
	var toggle: Button = Button.new()
	toggle.name = "RaffleRules"
	toggle.flat = true
	toggle.text = _t("raffleRulesToggle")
	toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	toggle.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	toggle.pressed.connect(func() -> void: rules.visible = not rules.visible)
	box.add_child(toggle)
	box.add_child(rules)
	_focus_rows.append([toggle])


## A consent checkbox with its full wording next to it (clicking the text
## ticks it too). The wording is remembered: it is sent with the answer.
func _add_consent(box: VBoxContainer, field: String, wording: String, checked: bool) -> CheckBox:
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	var check: CheckBox = CheckBox.new()
	check.name = "Consent_%s" % field
	check.theme_type_variation = &"ForgeLoggerConsent"
	check.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	check.set_pressed_no_signal(checked)
	var label: Label = _make_label(wording, &"ForgeLoggerConsentText")
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.mouse_filter = Control.MOUSE_FILTER_STOP
	label.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton and (event as InputEventMouseButton).pressed and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
			check.button_pressed = not check.button_pressed)
	row.add_child(check)
	row.add_child(label)
	box.add_child(row)
	_consent_texts[field] = wording
	_add_error_label(box, field)
	_field_focus[field] = check
	_focus_rows.append([check])
	return check


func _show_message(title_text: String, body: String, can_retry: bool, state: String = STATE_MESSAGE) -> void:
	_state = state
	_clear_content()
	_title.text = title_text
	if not body.is_empty():
		_add_text(body, &"", HORIZONTAL_ALIGNMENT_CENTER)
	_set_status("")
	_powered_by.visible = false
	_close_button.text = _t("close")
	_close_button.visible = true
	_close_button.disabled = false
	_retry_on_submit = can_retry
	_submit_button.visible = can_retry
	_submit_button.disabled = false
	_submit_button.text = _t("retry")
	var buttons: Array = [_close_button]
	if can_retry:
		buttons.append(_submit_button)
	_apply_focus_chain(buttons)
	_queue_layout()
	if is_inside_tree():
		(_submit_button if can_retry else _close_button).grab_focus()


func _show_thanks(queued: bool) -> void:
	_state = STATE_THANKS
	_clear_content()
	var branding: Dictionary = _form.get("branding", {}) as Dictionary if _form.get("branding", null) is Dictionary else {}
	_title.text = _t("thanksTitle")
	var message: String = str(branding.get("thankYouMessage", "")) if branding.get("thankYouMessage", null) is String else ""
	_add_text(message if not message.is_empty() else _t("thanksDefault"), &"", HORIZONTAL_ALIGNMENT_CENTER)
	if queued:
		_add_text(_t("queuedBody"), &"ForgeLoggerHint", HORIZONTAL_ALIGNMENT_CENTER)
	var wishlist_url: String = str(branding.get("wishlistUrl", "")) if branding.get("wishlistUrl", null) is String else ""
	if wishlist_url.begins_with("https://"):
		var wishlist: Button = Button.new()
		wishlist.name = "Wishlist"
		wishlist.theme_type_variation = &"ForgeLoggerPrimaryButton"
		var label: String = str(branding.get("wishlistLabel", "")) if branding.get("wishlistLabel", null) is String else ""
		wishlist.text = label if not label.is_empty() else _wishlist_default_label(wishlist_url)
		wishlist.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		wishlist.custom_minimum_size = Vector2(200, 40)
		wishlist.pressed.connect(func() -> void: OS.shell_open(wishlist_url))
		_content.add_child(wishlist)
		_focus_rows.append([wishlist])
	_set_status("")
	_submit_button.visible = false
	_close_button.text = _t("close")
	_close_button.disabled = false
	_apply_focus_chain([_close_button])
	_queue_layout()
	_focus_first()


# ---- Interaction ----


func _on_star_pressed(id: String, value: int) -> void:
	_set_answer(id, value)
	_update_stars(id)


func _update_stars(id: String) -> void:
	var stars: Array = _star_buttons.get(id, []) as Array
	var value: int = int(_answers.get(id, 0)) if (_answers.get(id, null) is int or _answers.get(id, null) is float) else 0
	for index: int in range(stars.size()):
		var star: Button = stars[index] as Button
		var on: bool = index < value
		star.set_pressed_no_signal(on)
		star.icon = _star_filled if on else _star_empty


func _on_text_changed(id: String, new_text: String, counter: Label, max_length: int) -> void:
	_set_answer(id, new_text)
	_update_counter(counter, new_text, max_length)


func _update_counter(counter: Label, current: String, max_length: int) -> void:
	counter.text = _t("charCount", {"count": current.strip_edges().length(), "max": max_length})


func _set_answer(id: String, value: Variant) -> void:
	_answers[id] = value
	_clear_error(id)


func _on_submit_pressed() -> void:
	if _retry_on_submit:
		_load_form()
		return
	if _state != STATE_FORM:
		return
	var errors: Dictionary = _validate()
	_show_errors(errors)
	if not errors.is_empty():
		_set_status(_t("errorFixFields"))
		_focus_first_error(errors)
		return

	var manager: ForgeLoggerFeedbackManager = _manager()
	if manager == null:
		return
	_state = STATE_SENDING
	_submit_button.disabled = true
	_close_button.disabled = true
	_submit_button.text = _t("submitting")
	_set_status("")

	var has_contact_block: bool = _has_block("contact")
	var has_raffle_block: bool = _has_block("raffle")
	var contact_value: String = _contact_value.strip_edges()
	var extra: Dictionary = {"locale": _locale, "consent_texts": _consent_texts}
	if has_contact_block and not contact_value.is_empty():
		extra["contact"] = {"kind": _contact_kind, "value": contact_value}
	extra["consents"] = {
		"shareContact": has_contact_block and not contact_value.is_empty() and _share_contact,
		"raffle": has_raffle_block and _raffle and _raffle_entry_open(),
	}
	var payload: Dictionary = manager.build_payload(_link_token, int(_form.get("schemaVersion", 0)), _build_answers(), extra)
	var result: Dictionary = await manager.submit(payload)
	if not is_inside_tree() or _closing:
		# Closed while sending: the answer still went out (or was queued).
		_notify_submitted(result)
		return

	match str(result.get("status", "")):
		ForgeLoggerFeedbackManager.SUBMIT_SENT:
			_notify_submitted(result)
			_show_thanks(false)
		ForgeLoggerFeedbackManager.SUBMIT_QUEUED:
			_notify_submitted(result)
			_show_thanks(true)
		ForgeLoggerFeedbackManager.SUBMIT_CLOSED:
			_show_message(_t("closedTitle"), _t("closedBody"), false)
		ForgeLoggerFeedbackManager.SUBMIT_OUTDATED:
			# The questions changed: fetch them again, keep what still fits.
			await _load_form()
			if _state == STATE_FORM:
				_set_status(_t("errorOutdatedGame"))
		ForgeLoggerFeedbackManager.SUBMIT_INVALID:
			_state = STATE_FORM
			var mapped: Dictionary = _map_server_errors(result.get("errors", []) as Array)
			_show_errors(mapped)
			_restore_submit()
			_set_status(_t("errorFixFields"))
			_focus_first_error(mapped)
		_:
			_state = STATE_FORM
			_restore_submit()
			_set_status(_t("errorGeneric"))


func _notify_submitted(result: Dictionary) -> void:
	var status: String = str(result.get("status", ""))
	if status != ForgeLoggerFeedbackManager.SUBMIT_SENT and status != ForgeLoggerFeedbackManager.SUBMIT_QUEUED:
		return
	if _submitted:
		return
	_submitted = true
	if _forge_logger != null and is_instance_valid(_forge_logger) and _forge_logger.has_signal("feedback_submitted"):
		_forge_logger.emit_signal("feedback_submitted", _link_token, result)


func _restore_submit() -> void:
	_submit_button.disabled = false
	_close_button.disabled = false
	_submit_button.text = _t("submit")


func _input(event: InputEvent) -> void:
	if _closing or not is_visible_in_tree():
		return
	if event.is_action_pressed("ui_cancel") or _is_pad_button(event, JOY_BUTTON_B, "ui_cancel", true):
		if _state != STATE_SENDING:
			get_viewport().set_input_as_handled()
			_close()
		return
	# Godot's default ui_accept has no gamepad button (many games add A, some
	# don't): unless the game mapped it, A acts as ui_accept on the focused control.
	if _is_pad_button(event, JOY_BUTTON_A, "ui_accept", false):
		get_viewport().set_input_as_handled()
		_forward_accept.call_deferred((event as InputEventJoypadButton).pressed)
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner == null or not is_ancestor_of(focus_owner):
		# Focus sits in the game's UI (or nowhere): pull it into the form so a
		# gamepad never drives the game behind it.
		if _is_navigation(event):
			get_viewport().set_input_as_handled()
			_focus_first()
		return
	if not (focus_owner is TextEdit or focus_owner is LineEdit):
		return
	# Text fields swallow up / down (caret) and Tab (indent). Let a gamepad and
	# Tab leave them, or the rest of the form is unreachable without a mouse.
	var side: int = -1
	var from_pad: bool = event is InputEventJoypadButton or event is InputEventJoypadMotion
	if event.is_action_pressed("ui_focus_next") and focus_owner is TextEdit:
		side = SIDE_BOTTOM
	elif event.is_action_pressed("ui_focus_prev") and focus_owner is TextEdit:
		side = SIDE_TOP
	elif from_pad and event.is_action_pressed("ui_down"):
		side = SIDE_BOTTOM
	elif from_pad and event.is_action_pressed("ui_up"):
		side = SIDE_TOP
	if side < 0:
		return
	var path: NodePath = focus_owner.focus_neighbor_bottom if side == SIDE_BOTTOM else focus_owner.focus_neighbor_top
	var target: Control = focus_owner.get_node_or_null(path) as Control if not path.is_empty() else null
	if target != null and target != focus_owner:
		get_viewport().set_input_as_handled()
		target.grab_focus()


func _is_navigation(event: InputEvent) -> bool:
	for action: String in ["ui_up", "ui_down", "ui_left", "ui_right", "ui_accept", "ui_focus_next", "ui_focus_prev"]:
		if event.is_action_pressed(action):
			return true
	return false


## A gamepad button the game has not mapped to `action` itself.
func _is_pad_button(event: InputEvent, button: JoyButton, action: StringName, pressed_only: bool) -> bool:
	if not event is InputEventJoypadButton:
		return false
	var pad: InputEventJoypadButton = event as InputEventJoypadButton
	if pad.button_index != button or (pressed_only and not pad.pressed):
		return false
	return not InputMap.has_action(action) or not event.is_action(action)


## Replays A as ui_accept to the focused control only (through the viewport,
## not Input, so the game's own action state is left alone).
func _forward_accept(pressed: bool) -> void:
	if _closing or not is_inside_tree():
		return
	var focus_owner: Control = get_viewport().gui_get_focus_owner()
	if focus_owner == null or not is_ancestor_of(focus_owner):
		if pressed:
			_focus_first()
		return
	var action: InputEventAction = InputEventAction.new()
	action.action = &"ui_accept"
	action.pressed = pressed
	get_viewport().push_input(action)


func _close() -> void:
	if _closing:
		return
	_finish_close()
	var parent_node: Node = get_parent()
	if parent_node is CanvasLayer:
		parent_node.queue_free()
	else:
		queue_free()


func _finish_close() -> void:
	if _closing:
		return
	_closing = true
	if _paused_by_us and is_inside_tree():
		get_tree().paused = false
	_paused_by_us = false
	if _forge_logger != null and is_instance_valid(_forge_logger) and _forge_logger.has_method("_on_feedback_popup_closed"):
		_forge_logger.call("_on_feedback_popup_closed", _link_token, _submitted)


# ---- Validation (mirrors validateFeedbackDraft on the web form) ----


func _validate() -> Dictionary:
	var errors: Dictionary = {}
	for block: Dictionary in _visible_blocks():
		var type: String = str(block.get("type", ""))
		if type == "contact" or type == "raffle":
			continue
		var id: String = str(block.get("id", ""))
		var value: Variant = _answers.get(id, null)
		var empty: bool = value == null or (value is String and str(value).strip_edges().is_empty())
		if empty:
			if bool(block.get("required", false)):
				errors[id] = _t("errorRequired")
			continue
		if (type == "text" or type == "short_text") and value is String:
			var max_length: int = int(block.get("maxLength", 0))
			if max_length > 0 and str(value).strip_edges().length() > max_length:
				errors[id] = _t("errorTooLong", {"max": max_length})

	var has_contact: bool = _has_block("contact") and not _contact_value.strip_edges().is_empty()
	if has_contact:
		if not _is_plausible_contact(_contact_kind, _contact_value):
			errors["contact"] = _t("errorEmail") if _contact_kind == "email" else _t("errorSteam")
		elif not _share_contact:
			errors["shareContact"] = _t("errorConsentNeeded")
	if _has_block("raffle") and _raffle and not has_contact:
		errors["raffle"] = _t("errorRaffleNeedsContact")
	return errors


func _is_plausible_contact(kind: String, raw: String) -> bool:
	var value: String = raw.strip_edges()
	if kind == "email":
		var compact: String = RegEx.create_from_string("\\s+").sub(value, "", true)
		return value.length() <= 254 and RegEx.create_from_string(EMAIL_PATTERN).search(compact) != null
	if RegEx.create_from_string("^7656119\\d{10}$").search(value) != null:
		return true
	if RegEx.create_from_string("^\\d{1,10}$").search(value) != null:
		return true
	return RegEx.create_from_string(STEAM_URL_PATTERN).search(value) != null


## Server issues (`answers.<id>`, `contact.value`, `consents.shareContact`)
## mapped onto the form's fields.
func _map_server_errors(issues: Array) -> Dictionary:
	var fields: Dictionary = {}
	for issue: Variant in issues:
		if not issue is Dictionary:
			continue
		var path: String = str((issue as Dictionary).get("path", ""))
		var message: String = str((issue as Dictionary).get("message", _t("errorGeneric")))
		var field: String = ""
		if path.begins_with("answers."):
			field = path.substr("answers.".length()).split(".")[0]
		elif path == "consents.shareContact":
			field = "shareContact"
		elif path == "consents.raffle":
			field = "raffle"
		elif path.begins_with("contact"):
			field = "contact"
		if not field.is_empty() and not fields.has(field):
			fields[field] = message
	return fields


func _show_errors(errors: Dictionary) -> void:
	for field: String in _error_labels.keys():
		var label: Label = _error_labels[field] as Label
		if not is_instance_valid(label):
			continue
		label.text = str(errors.get(field, ""))
		label.visible = errors.has(field)


func _clear_error(field: String) -> void:
	var label: Label = _error_labels.get(field, null) as Label
	if label != null and is_instance_valid(label):
		label.visible = false


func _focus_first_error(errors: Dictionary) -> void:
	for row: Array in _focus_rows:
		for control: Variant in row:
			for field: String in errors.keys():
				if _field_focus.get(field, null) == control:
					(control as Control).grab_focus()
					return


# ---- Answers ----


func _build_answers() -> Dictionary:
	var out: Dictionary = {}
	for block: Dictionary in _visible_blocks():
		var type: String = str(block.get("type", ""))
		if type == "contact" or type == "raffle":
			continue
		var id: String = str(block.get("id", ""))
		if not _answers.has(id):
			continue
		var value: Variant = _answers[id]
		if value is String:
			var trimmed: String = str(value).strip_edges()
			if not trimmed.is_empty():
				out[id] = trimmed
		elif type == "rating":
			out[id] = int(value)
		else:
			out[id] = value
	return out


func _visible_blocks() -> Array:
	var blocks: Array = []
	var schema: Variant = _form.get("schema", null)
	if not schema is Dictionary:
		return blocks
	var raw: Variant = (schema as Dictionary).get("blocks", [])
	if not raw is Array:
		return blocks
	for block: Variant in raw:
		if not block is Dictionary or not bool((block as Dictionary).get("enabled", true)):
			continue
		# `raffle: null` from the server = no raffle to enter (no prize or
		# deadline saved yet, a plan without raffles) — never offer it then.
		if str((block as Dictionary).get("type", "")) == "raffle" and _form.has("raffle") and not _form["raffle"] is Dictionary:
			continue
		blocks.append(block)
	return blocks


## Whether a raffle entry is still accepted. The server says so in
## `raffle.entryOpen` (FB-10); a server older than that sends no `raffle` key
## and enforces the deadline on its own.
func _raffle_entry_open() -> bool:
	var raffle: Variant = _form.get("raffle", null)
	if raffle is Dictionary:
		return bool((raffle as Dictionary).get("entryOpen", true))
	return not _form.has("raffle")


## `<feedback host>/f/<token>/rules` — the prize, dates and full rules, in the
## form's language. Empty without raffle terms from the server.
func _raffle_rules_url() -> String:
	if not _form.get("raffle", null) is Dictionary:
		return ""
	var config: Variant = _forge_logger.get("config") if _forge_logger != null and is_instance_valid(_forge_logger) else null
	if not config is ForgeLoggerConfig:
		return ""
	var url: String = "%s/f/%s/rules" % [(config as ForgeLoggerConfig).get_feedback_base_url(), _link_token.uri_encode()]
	if not _locale.is_empty():
		url += "?lang=%s" % _locale.uri_encode()
	return url


func _has_block(type: String) -> bool:
	for block: Dictionary in _visible_blocks():
		if str(block.get("type", "")) == type:
			return true
	return false


func _choice_options(block: Dictionary) -> Array:
	var options: Array = []
	var raw: Variant = block.get("options", [])
	if raw is Array:
		for option: Variant in raw:
			if option is Dictionary:
				options.append({"value": str((option as Dictionary).get("id", "")), "label": str((option as Dictionary).get("label", ""))})
	return options


func _price_options(block: Dictionary) -> Array:
	var options: Array = []
	var currency: String = str(block.get("currency", "EUR"))
	var raw: Variant = block.get("pricePoints", [])
	if raw is Array:
		for point: Variant in raw:
			if point is Dictionary:
				var p: Dictionary = point as Dictionary
				options.append({
					"value": str(p.get("id", "")),
					"label": ForgeLoggerFeedbackI18n.format_price(float(p.get("amount", 0)), currency, _locale, bool(p.get("orMore", false))),
				})
	if bool(block.get("allowNoPurchase", false)):
		var label: String = str(block.get("noPurchaseLabel", "")) if block.get("noPurchaseLabel", null) is String else ""
		options.append({"value": "would_not_buy", "label": label if not label.is_empty() else _t("wouldNotBuy")})
	return options


# ---- Building blocks ----


func _add_question(block: Dictionary) -> VBoxContainer:
	var box: VBoxContainer = VBoxContainer.new()
	box.name = "Block_%s" % str(block.get("id", ""))
	box.add_theme_constant_override("separation", 6)
	var label_text: String = str(block.get("label", ""))
	if bool(block.get("required", false)):
		label_text += " *"
	box.add_child(_make_label(label_text, &"ForgeLoggerQuestion"))
	if block.get("description", null) is String and not str(block["description"]).is_empty():
		box.add_child(_make_label(str(block["description"]), &"ForgeLoggerHint"))
	_content.add_child(box)
	return box


func _add_error_label(box: VBoxContainer, field: String) -> void:
	var label: Label = _make_label("", &"ForgeLoggerError")
	label.name = "Error_%s" % field
	label.visible = false
	box.add_child(label)
	_error_labels[field] = label


func _add_text(text_value: String, variation: StringName = &"", align: HorizontalAlignment = HORIZONTAL_ALIGNMENT_LEFT) -> Label:
	var label: Label = _make_label(text_value, variation)
	label.horizontal_alignment = align
	_content.add_child(label)
	return label


func _make_label(text_value: String, variation: StringName = &"") -> Label:
	var label: Label = Label.new()
	label.text = text_value
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if variation != &"":
		label.theme_type_variation = variation
	return label


func _clear_content() -> void:
	for child: Node in _content.get_children():
		_content.remove_child(child)
		child.queue_free()
	_error_labels.clear()
	_field_focus.clear()
	_focus_rows.clear()
	_consent_texts.clear()
	_star_buttons.clear()


## Explicit focus neighbours: up / down move between rows, left / right
## within a row (stars, yes / no, contact kind, the buttons at the bottom).
func _apply_focus_chain(bottom_row: Array) -> void:
	var rows: Array = _focus_rows.duplicate()
	var visible_bottom: Array = []
	for control: Variant in bottom_row:
		if (control as Control).visible:
			visible_bottom.append(control)
	if not visible_bottom.is_empty():
		rows.append(visible_bottom)
	var flat: Array = []
	for r: int in range(rows.size()):
		var row: Array = rows[r]
		for i: int in range(row.size()):
			var control: Control = row[i] as Control
			control.focus_mode = Control.FOCUS_ALL
			control.focus_neighbor_left = control.get_path_to(row[i - 1] as Control) if i > 0 else NodePath(".")
			control.focus_neighbor_right = control.get_path_to(row[i + 1] as Control) if i < row.size() - 1 else NodePath(".")
			if r > 0:
				var above: Array = rows[r - 1]
				control.focus_neighbor_top = control.get_path_to(above[mini(i, above.size() - 1)] as Control)
			else:
				control.focus_neighbor_top = NodePath(".")
			if r < rows.size() - 1:
				var below: Array = rows[r + 1]
				control.focus_neighbor_bottom = control.get_path_to(below[mini(i, below.size() - 1)] as Control)
			else:
				control.focus_neighbor_bottom = NodePath(".")
			flat.append(control)
	for k: int in range(flat.size()):
		var control: Control = flat[k] as Control
		control.focus_next = control.get_path_to(flat[(k + 1) % flat.size()] as Control)
		control.focus_previous = control.get_path_to(flat[(k - 1 + flat.size()) % flat.size()] as Control)


func _focus_first() -> void:
	if not is_inside_tree():
		return
	for row: Array in _focus_rows:
		if not row.is_empty():
			(row[0] as Control).grab_focus()
			return
	if _close_button.visible:
		_close_button.grab_focus()


func _set_status(text_value: String) -> void:
	_status.text = text_value
	_status.visible = not text_value.is_empty()


func _wishlist_default_label(url: String) -> String:
	var host: String = url.trim_prefix("https://").split("/")[0].to_lower()
	if host == "store.steampowered.com" or host.ends_with(".steampowered.com"):
		return _t("wishlistSteam")
	if host == "itch.io" or host.ends_with(".itch.io"):
		return _t("wishlistItch")
	return _t("wishlistOther")


func _t(key: String, args: Dictionary = {}) -> String:
	return ForgeLoggerFeedbackI18n.text(_locale, key, args)


func _manager() -> ForgeLoggerFeedbackManager:
	if _forge_logger == null or not is_instance_valid(_forge_logger):
		return null
	return _forge_logger.get("feedback_manager") as ForgeLoggerFeedbackManager


# ---- Layout ----


## Scale the whole form with the viewport (a 720p-sized form on a 1080p or
## Steam Deck screen, half size on a low-res pixel-art viewport), or by
## options.ui_scale; the panel never leaves the screen and scrolls instead.
func _apply_scale() -> void:
	if not is_inside_tree():
		return
	var viewport_size: Vector2 = get_viewport().get_visible_rect().size
	var ui_scale: float = float(_options.get("ui_scale", 0.0))
	if ui_scale <= 0.0:
		ui_scale = clampf(viewport_size.y / REFERENCE_HEIGHT, 0.5, 2.0)
	var layer: CanvasLayer = get_parent() as CanvasLayer
	if layer != null:
		layer.scale = Vector2(ui_scale, ui_scale)
	else:
		ui_scale = 1.0
	position = Vector2.ZERO
	size = viewport_size / ui_scale
	var width: float = minf(MAX_PANEL_WIDTH, size.x - 2.0 * EDGE_MARGIN)
	_panel.custom_minimum_size.x = maxf(width, MIN_PANEL_WIDTH)
	_queue_layout()


func _queue_layout() -> void:
	if is_inside_tree():
		call_deferred("_update_scroll_height")


func _update_scroll_height() -> void:
	if not is_inside_tree():
		return
	_scroll.custom_minimum_size.y = 0.0
	var chrome: float = _panel.get_combined_minimum_size().y
	var content_height: float = _content.get_combined_minimum_size().y
	var available: float = size.y - 2.0 * EDGE_MARGIN - chrome
	_scroll.custom_minimum_size.y = clampf(content_height, 0.0, maxf(available, MIN_SCROLL_HEIGHT))


# ---- Theme ----


## Built-in look (neutral, readable on dark and light games) with the game's
## Theme merged over it — the game's definitions win.
func _build_theme(custom: Theme) -> Theme:
	var built: Theme = Theme.new()
	built.set_type_variation(&"ForgeLoggerTitle", &"Label")
	built.set_font_size(&"font_size", &"ForgeLoggerTitle", 24)
	built.set_type_variation(&"ForgeLoggerQuestion", &"Label")
	built.set_font_size(&"font_size", &"ForgeLoggerQuestion", 17)
	built.set_type_variation(&"ForgeLoggerHint", &"Label")
	built.set_font_size(&"font_size", &"ForgeLoggerHint", 14)
	built.set_color(&"font_color", &"ForgeLoggerHint", Color(0.66, 0.68, 0.74))
	built.set_type_variation(&"ForgeLoggerError", &"Label")
	built.set_font_size(&"font_size", &"ForgeLoggerError", 14)
	built.set_color(&"font_color", &"ForgeLoggerError", Color(0.96, 0.42, 0.38))
	var focus_ring: StyleBoxFlat = _box_style(Color(0, 0, 0, 0), Color(1, 1, 1, 0.9), 2)
	focus_ring.draw_center = false
	focus_ring.set_expand_margin_all(2)

	built.set_type_variation(&"ForgeLoggerPrimaryButton", &"Button")
	built.set_stylebox(&"normal", &"ForgeLoggerPrimaryButton", _box_style(ACCENT, ACCENT, 0))
	built.set_stylebox(&"hover", &"ForgeLoggerPrimaryButton", _box_style(ACCENT.lightened(0.12), ACCENT.lightened(0.12), 0))
	built.set_stylebox(&"pressed", &"ForgeLoggerPrimaryButton", _box_style(ACCENT.darkened(0.15), ACCENT.darkened(0.15), 0))
	built.set_stylebox(&"disabled", &"ForgeLoggerPrimaryButton", _box_style(Color(ACCENT, 0.45), Color(ACCENT, 0.45), 0))
	built.set_stylebox(&"focus", &"ForgeLoggerPrimaryButton", focus_ring)
	for color_name: StringName in [&"font_color", &"font_hover_color", &"font_pressed_color", &"font_focus_color", &"font_hover_pressed_color"]:
		built.set_color(color_name, &"ForgeLoggerPrimaryButton", Color(1, 1, 1))
	built.set_color(&"font_disabled_color", &"ForgeLoggerPrimaryButton", Color(1, 1, 1, 0.6))

	built.set_type_variation(&"ForgeLoggerChoice", &"Button")
	built.set_stylebox(&"normal", &"ForgeLoggerChoice", _box_style(Color(1, 1, 1, 0.05), Color(1, 1, 1, 0.16), 1))
	built.set_stylebox(&"hover", &"ForgeLoggerChoice", _box_style(Color(1, 1, 1, 0.1), Color(1, 1, 1, 0.3), 1))
	built.set_stylebox(&"pressed", &"ForgeLoggerChoice", _box_style(Color(ACCENT, 0.24), ACCENT, 2))
	built.set_stylebox(&"hover_pressed", &"ForgeLoggerChoice", _box_style(Color(ACCENT, 0.32), ACCENT, 2))
	built.set_stylebox(&"focus", &"ForgeLoggerChoice", focus_ring)
	for color_name: StringName in [&"font_pressed_color", &"font_hover_pressed_color"]:
		built.set_color(color_name, &"ForgeLoggerChoice", Color(1, 1, 1))

	built.set_type_variation(&"ForgeLoggerStar", &"Button")
	var star_idle: StyleBoxFlat = _box_style(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 0, 4)
	var star_hover: StyleBoxFlat = _box_style(Color(1, 1, 1, 0.08), Color(0, 0, 0, 0), 0, 4)
	built.set_stylebox(&"normal", &"ForgeLoggerStar", star_idle)
	built.set_stylebox(&"pressed", &"ForgeLoggerStar", star_idle)
	built.set_stylebox(&"hover", &"ForgeLoggerStar", star_hover)
	built.set_stylebox(&"hover_pressed", &"ForgeLoggerStar", star_hover)
	built.set_stylebox(&"focus", &"ForgeLoggerStar", focus_ring)
	built.set_icon(&"star_filled", &"ForgeLoggerStar", _star_texture(Color(1.0, 0.72, 0.2)))
	built.set_icon(&"star_empty", &"ForgeLoggerStar", _star_texture(Color(0.6, 0.62, 0.68, 0.55)))

	built.set_type_variation(&"ForgeLoggerConsent", &"CheckBox")
	built.set_icon(&"checked", &"ForgeLoggerConsent", _checkbox_texture(true))
	built.set_icon(&"unchecked", &"ForgeLoggerConsent", _checkbox_texture(false))
	built.set_stylebox(&"focus", &"ForgeLoggerConsent", focus_ring)
	built.set_type_variation(&"ForgeLoggerConsentText", &"Label")
	built.set_font_size(&"font_size", &"ForgeLoggerConsentText", 15)

	built.set_type_variation(&"ForgeLoggerPanel", &"PanelContainer")
	var panel: StyleBoxFlat = StyleBoxFlat.new()
	panel.bg_color = Color(0.1, 0.11, 0.13, 0.98)
	panel.border_color = Color(1, 1, 1, 0.08)
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(10)
	built.set_stylebox(&"panel", &"ForgeLoggerPanel", panel)
	if custom != null:
		built.merge_with(custom)
	return built


static func _box_style(background: Color, border: Color, border_width: int, margin: int = 12) -> StyleBoxFlat:
	var style: StyleBoxFlat = StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = border
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(6)
	style.content_margin_left = margin
	style.content_margin_right = margin
	style.content_margin_top = mini(margin, 6)
	style.content_margin_bottom = mini(margin, 6)
	return style


## Checkbox icons drawn into textures: the engine's default box is dark and
## disappears on a dark panel — a consent box must be plain to see.
static func _checkbox_texture(checked: bool, texture_size: int = 22) -> ImageTexture:
	var image: Image = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	var size_f: float = float(texture_size)
	var outline: Color = Color(0.8, 0.82, 0.88)
	var tick_a: Vector2 = Vector2(size_f * 0.27, size_f * 0.52)
	var tick_b: Vector2 = Vector2(size_f * 0.43, size_f * 0.68)
	var tick_c: Vector2 = Vector2(size_f * 0.74, size_f * 0.34)
	for y: int in range(texture_size):
		for x: int in range(texture_size):
			var sum: Color = Color(0, 0, 0, 0)
			for sy: int in range(4):
				for sx: int in range(4):
					var p: Vector2 = Vector2(x + (sx + 0.5) / 4.0, y + (sy + 0.5) / 4.0)
					var d: float = _rounded_box_distance(p, 2.0, size_f - 2.0, 4.0)
					var sample: Color = Color(0, 0, 0, 0)
					if checked and d <= 0.0:
						sample = ACCENT
						var tick: float = minf(_segment_distance(p, tick_a, tick_b), _segment_distance(p, tick_b, tick_c))
						if tick <= size_f * 0.07:
							sample = Color(1, 1, 1)
					elif not checked and d <= 0.0 and d > -2.0:
						sample = outline
					sum += Color(sample.r * sample.a, sample.g * sample.a, sample.b * sample.a, sample.a)
			var alpha: float = sum.a / 16.0
			if alpha > 0.0:
				image.set_pixel(x, y, Color(sum.r / sum.a, sum.g / sum.a, sum.b / sum.a, alpha))
	return ImageTexture.create_from_image(image)


static func _rounded_box_distance(p: Vector2, low: float, high: float, radius: float) -> float:
	var center: float = (low + high) / 2.0
	var half: float = (high - low) / 2.0 - radius
	var q: Vector2 = (p - Vector2(center, center)).abs() - Vector2(half, half)
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - radius


static func _segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab: Vector2 = b - a
	var t: float = clampf((p - a).dot(ab) / ab.length_squared(), 0.0, 1.0)
	return p.distance_to(a + ab * t)


## A five-point star drawn into a texture, so the rating never depends on a
## font having the ★ glyph.
static func _star_texture(color: Color, texture_size: int = 32) -> ImageTexture:
	var image: Image = Image.create(texture_size, texture_size, false, Image.FORMAT_RGBA8)
	var points: PackedVector2Array = PackedVector2Array()
	var center: Vector2 = Vector2(texture_size / 2.0, texture_size / 2.0 + texture_size * 0.04)
	var outer: float = texture_size * 0.48
	var inner: float = outer * 0.45
	for k: int in range(10):
		var angle: float = -PI / 2.0 + k * PI / 5.0
		var radius: float = outer if k % 2 == 0 else inner
		points.append(center + Vector2(cos(angle), sin(angle)) * radius)
	for y: int in range(texture_size):
		for x: int in range(texture_size):
			var cover: int = 0
			for sy: int in range(2):
				for sx: int in range(2):
					if Geometry2D.is_point_in_polygon(Vector2(x + (sx + 0.5) / 2.0, y + (sy + 0.5) / 2.0), points):
						cover += 1
			if cover > 0:
				image.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * cover / 4.0))
	return ImageTexture.create_from_image(image)
