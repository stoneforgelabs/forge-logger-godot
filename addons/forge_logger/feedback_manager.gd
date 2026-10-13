class_name ForgeLoggerFeedbackManager
extends RefCounted
## In-game feedback forms (FB-09): fetches a form from the ingest API
## (`GET /v1/ingest/feedback/:linkToken`), keeps the last copy in `user://` for
## offline use (revalidated with its ETag; in memory only when
## forge_logger/enable_reports is off), and submits a player's answers
## (`POST /v1/ingest/feedback`) — straight away, or later from the offline
## queue with the same clientRequestId, so a retry never stores an answer twice.
##
## Retry rules follow the ingest API docs (/docs/ingest-api/feedback): no
## response, 429, 5xx (incl. 503 contact_unavailable) = retry; 409
## unknown_schema_version = fetch the form again; any other 4xx = drop.
## A queued answer the server still cannot take WITH its contact (503
## contact_unavailable on a retry) is sent without the contact and consents —
## the API's "retry later or send without the contact" — so the answers
## themselves are never lost to a missing KMS key or pepper.

const LOG_PREFIX: String = "[ForgeLogger] "
const CACHE_DIR: String = "user://forge_logger_feedback"
## Shape of a feedback link token (mirrors FEEDBACK_LINK_TOKEN_PATTERN).
const LINK_TOKEN_PATTERN: String = "^[A-Za-z0-9_-]{16}$"
## Mirrors FEEDBACK_LIMITS.consentTextMax — a longer wording is not sent
## (a cut-off text would misstate what the player saw).
const CONSENT_TEXT_MAX: int = 1000
## Mirrors FEEDBACK_LIMITS.checkpointMax — the server ignores a longer one.
const CHECKPOINT_MAX: int = 200

## fetch_form() statuses
const FORM_OK: String = "ok"
const FORM_UNAVAILABLE: String = "unavailable"
const FORM_NOT_FOUND: String = "not_found"
const FORM_OFFLINE: String = "offline"
const FORM_ERROR: String = "error"
const FORM_NOT_CONFIGURED: String = "not_configured"

## submit() statuses
const SUBMIT_SENT: String = "sent"
const SUBMIT_QUEUED: String = "queued"
const SUBMIT_CLOSED: String = "closed"
const SUBMIT_OUTDATED: String = "outdated"
const SUBMIT_INVALID: String = "invalid"
const SUBMIT_REJECTED: String = "rejected"

var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null
var _session: ForgeLoggerSessionManager = null
var _queue: ForgeLoggerReportQueue = null
var _token_regex: RegEx = null
## Form copies kept in memory instead of user:// when the game writes nothing
## to disk (forge_logger/enable_reports off): link token -> {etag, form}.
var _memory_cache: Dictionary = {}
## Returns the game's current checkpoint ("" = none) — ForgeLogger wires it to
## the `checkpoint` of set_context_provider(). Sent with every answer (FB-11).
var checkpoint_source: Callable = Callable()


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient, session: ForgeLoggerSessionManager, queue: ForgeLoggerReportQueue) -> void:
	_config = config
	_http = http
	_session = session
	_queue = queue
	_queue.register_handler(ForgeLoggerReportQueue.KIND_FEEDBACK, _send_queued)


func is_valid_link_token(link_token: String) -> bool:
	if _token_regex == null:
		_token_regex = RegEx.create_from_string(LINK_TOKEN_PATTERN)
	return _token_regex.search(link_token) != null


## Fetch the form behind a feedback link. Returns
##   {status, form, from_cache, response_code}
## status: "ok" (open, render `form`), "unavailable" (`form.availability` is
## draft / closed / not_started / ended), "not_found", "offline" (no response
## and nothing cached), "error", "not_configured" (no api_key).
## Offline, rate limited or on a server error the cached copy is used.
func fetch_form(link_token: String) -> Dictionary:
	if not is_valid_link_token(link_token):
		_log("Invalid feedback link token: '%s' (expected the 16 characters after /f/)." % link_token)
		return _form_result(FORM_NOT_FOUND, {}, false, 0)
	if not _config.is_ingest_configured():
		_log("Cannot load feedback form: set forge_logger/api_key (or point base_url at your own backend).")
		return _form_result(FORM_NOT_CONFIGURED, {}, false, 0)

	var cached: Dictionary = _read_cache(link_token)
	var etag: String = str(cached.get("etag", ""))
	var cached_form: Dictionary = cached.get("form", {}) as Dictionary
	var result: Dictionary = await _http.get_feedback_form(link_token, etag if not cached_form.is_empty() else "")
	var code: int = int(result.get("response_code", 0))

	if code == 304 and not cached_form.is_empty():
		return _classify_form(cached_form, false, code)
	if code >= 200 and code < 300:
		var form: Dictionary = result.get("body", {}) as Dictionary
		if not _is_form_shape(form):
			_log("Unexpected feedback form payload for %s." % link_token)
			return _fallback_to_cache(cached_form, FORM_ERROR, code)
		var headers: Dictionary = result.get("headers", {}) as Dictionary
		_write_cache(link_token, str(headers.get("etag", "")), form)
		return _classify_form(form, false, code)
	if code == 404:
		# The link was deleted or belongs to another project: forget it.
		_delete_cache(link_token)
		return _form_result(FORM_NOT_FOUND, {}, false, code)
	if code == 0:
		return _fallback_to_cache(cached_form, FORM_OFFLINE, code)
	return _fallback_to_cache(cached_form, FORM_ERROR, code)


## Warm the offline cache (e.g. at game start, before a festival booth goes
## offline). True when an open form is ready to show.
func prefetch(link_token: String) -> bool:
	var result: Dictionary = await fetch_form(link_token)
	return str(result.get("status", "")) == FORM_OK


## Build the request body for a player's answers. `answers` are keyed by block
## id (unanswered optional blocks left out); `extra` may hold:
##   contact: {kind, value}, consents: {shareContact, raffle},
##   consent_texts: {shareContact, raffle} (plain text shown next to each box),
##   locale: String (the form's language),
##   checkpoint: String (replaces the context provider's checkpoint).
func build_payload(link_token: String, schema_version: int, answers: Dictionary, extra: Dictionary = {}) -> Dictionary:
	var payload: Dictionary = {
		"linkToken": link_token,
		"schemaVersion": schema_version,
		"answers": answers,
		"clientRequestId": ForgeLoggerModels.generate_uuid(),
	}
	var session_id: String = _session.get_session_id()
	if not session_id.is_empty():
		payload["sessionId"] = session_id
		var build_id: String = _session.get_build_id()
		if not build_id.is_empty():
			payload["buildId"] = build_id
		payload["playtimeSeconds"] = _session.get_session_uptime_sec()
	var scene_name: String = _current_scene_name()
	if not scene_name.is_empty():
		payload["sceneName"] = scene_name
	var checkpoint: String = str(extra.get("checkpoint", "")).strip_edges()
	if checkpoint.is_empty() and checkpoint_source.is_valid():
		checkpoint = str(checkpoint_source.call()).strip_edges()
	if not checkpoint.is_empty() and checkpoint.length() <= CHECKPOINT_MAX:
		payload["checkpoint"] = checkpoint
	var locale: String = str(extra.get("locale", ""))
	if not locale.is_empty():
		payload["locale"] = locale

	var contact: Dictionary = extra.get("contact", {}) as Dictionary
	var consents_in: Dictionary = extra.get("consents", {}) as Dictionary
	var share_contact: bool = bool(consents_in.get("shareContact", false))
	var raffle: bool = bool(consents_in.get("raffle", false))
	if not contact.is_empty() and not str(contact.get("value", "")).strip_edges().is_empty():
		payload["contact"] = {"kind": str(contact.get("kind", "email")), "value": str(contact.get("value", "")).strip_edges()}
	var consents: Dictionary = {}
	if share_contact:
		consents["shareContact"] = true
	if raffle:
		consents["raffle"] = true
	if not consents.is_empty():
		payload["consents"] = consents
		# What exactly the player agreed to: the wording version and, for each
		# consent given, the text next to its checkbox (GDPR art. 7(1)).
		payload["consentTextVersion"] = ForgeLoggerFeedbackTexts.CONSENT_TEXT_VERSION
		var texts_in: Dictionary = extra.get("consent_texts", {}) as Dictionary
		var texts: Dictionary = {}
		for key: String in consents.keys():
			var normalized: String = normalize_consent_text(str(texts_in.get(key, "")))
			if not normalized.is_empty():
				texts[key] = normalized
		if not texts.is_empty():
			payload["consentTexts"] = texts
	return payload


## Submit a payload from build_payload(). Returns {status, …}:
##   sent     — stored (response_id, idempotent, quota_exceeded)
##   queued   — no response / 429 / 5xx: saved to the offline queue, sent later
##   closed   — the form stopped accepting answers (availability)
##   outdated — unknown schemaVersion: the cache is dropped, fetch the form again
##   invalid  — the answers don't fit the form (errors: [{path, code, message}])
##   rejected — any other 4xx (response_code)
func submit(payload: Dictionary) -> Dictionary:
	if not _config.is_ingest_configured():
		_log("Cannot submit feedback: set forge_logger/api_key (or point base_url at your own backend). Queued for retry.")
		_queue.enqueue(payload, ForgeLoggerReportQueue.KIND_FEEDBACK)
		return {"status": SUBMIT_QUEUED, "response_code": 0}

	# On disk BEFORE the request: a game closed (Alt+F4, a booth restart, a
	# Steam Deck going to sleep) while the request hangs on a bad network must
	# not lose the answer. The clientRequestId makes a later resend harmless.
	var entry_id: String = _queue.enqueue(payload, ForgeLoggerReportQueue.KIND_FEEDBACK, true)
	var result: Dictionary = await _http.submit_feedback(payload)
	var classified: Dictionary = _classify_submission(result, str(payload.get("linkToken", "")))
	var status: String = str(classified.get("status", ""))
	_queue.finish_in_flight(entry_id, status == SUBMIT_QUEUED)
	if status == SUBMIT_QUEUED:
		_log("Feedback not sent (HTTP %d), queued for retry." % int(classified.get("response_code", 0)))
	elif status == SUBMIT_SENT:
		_log("Feedback sent (response %s)." % str(classified.get("response_id", "")))
	return classified


## The payload without the contact and everything that hangs on it (consents
## and their wording). Same clientRequestId — the answer is still stored once.
static func without_contact(payload: Dictionary) -> Dictionary:
	var stripped: Dictionary = payload.duplicate(true)
	for key: String in ["contact", "consents", "consentTextVersion", "consentTexts"]:
		stripped.erase(key)
	return stripped


## Whitespace collapsed; empty when over the backend limit.
static func normalize_consent_text(text: String) -> String:
	var regex: RegEx = RegEx.create_from_string("\\s+")
	var normalized: String = regex.sub(text, " ", true).strip_edges()
	if normalized.length() > CONSENT_TEXT_MAX:
		return ""
	return normalized


## Remove the cached copy of a form (next fetch is a full GET).
func invalidate_cache(link_token: String) -> void:
	_delete_cache(link_token)


# ---- Queue handler ----


func _send_queued(payload: Dictionary) -> Dictionary:
	var result: Dictionary = await _http.submit_feedback(payload)
	var classified: Dictionary = _classify_submission(result, str(payload.get("linkToken", "")))
	if payload.has("contact") and _refuses_only_the_contact(classified):
		# Still no way to store this contact (no KMS key / pepper, or the
		# developer switched the contact question off since): keep the
		# answers, leave the contact out.
		_log("Queued feedback: the contact cannot be stored (%s) — sending the answers without it." % str(classified.get("code", "")))
		result = await _http.submit_feedback(without_contact(payload))
		classified = _classify_submission(result, str(payload.get("linkToken", "")))
	var code: int = int(classified.get("response_code", 0))
	match str(classified.get("status", "")):
		SUBMIT_SENT:
			return {"outcome": ForgeLoggerReportQueue.OUTCOME_SENT, "response_code": code}
		SUBMIT_QUEUED:
			return {"outcome": ForgeLoggerReportQueue.OUTCOME_RETRY, "response_code": code}
		_:
			# closed / outdated / invalid / rejected: the answer can never be
			# stored as given — resending would only burn the rate limit.
			return {"outcome": ForgeLoggerReportQueue.OUTCOME_DROP, "response_code": code}


# ---- Internal ----


func _classify_submission(result: Dictionary, link_token: String) -> Dictionary:
	var code: int = int(result.get("response_code", 0))
	var body: Dictionary = result.get("body", {}) as Dictionary
	var error_code: String = str(body.get("code", ""))
	if code >= 200 and code < 300:
		return {
			"status": SUBMIT_SENT,
			"response_code": code,
			"response_id": str(body.get("responseId", "")),
			"idempotent": bool(body.get("idempotent", false)),
			"quota_exceeded": bool(body.get("quotaExceeded", false)),
		}
	if code == 0 or code == 408 or code == 429 or code >= 500:
		return {"status": SUBMIT_QUEUED, "response_code": code, "code": error_code}
	if code == 409 and error_code == "unknown_schema_version":
		_delete_cache(link_token)
		return {"status": SUBMIT_OUTDATED, "response_code": code, "schema_version": int(body.get("schemaVersion", 0))}
	if code == 409:
		return {"status": SUBMIT_CLOSED, "response_code": code, "availability": str(body.get("availability", "closed"))}
	if code == 400 and error_code == "invalid_answers":
		var errors: Array = body.get("errors", []) as Array if body.get("errors", []) is Array else []
		for error: Variant in errors:
			if error is Dictionary and str((error as Dictionary).get("code", "")) == "contact_not_enabled":
				# The form no longer asks for a contact (switched off, no
				# privacy policy, a plan without contacts): the cached copy is
				# out of date — fetch it again, like an unknown revision.
				_delete_cache(link_token)
				return {"status": SUBMIT_OUTDATED, "response_code": code, "code": "contact_not_enabled", "schema_version": 0}
		return {"status": SUBMIT_INVALID, "response_code": code, "errors": errors}
	return {"status": SUBMIT_REJECTED, "response_code": code, "message": str(body.get("message", ""))}


## The server would take the answer, only not with its contact: 503
## contact_unavailable, or the contact question is gone from the form.
func _refuses_only_the_contact(classified: Dictionary) -> bool:
	var code: String = str(classified.get("code", ""))
	return code == "contact_unavailable" or code == "contact_not_enabled"


func _classify_form(form: Dictionary, from_cache: bool, code: int) -> Dictionary:
	if str(form.get("availability", "")) == "open" and form.get("schema", null) is Dictionary:
		return _form_result(FORM_OK, form, from_cache, code)
	return _form_result(FORM_UNAVAILABLE, form, from_cache, code)


func _fallback_to_cache(cached_form: Dictionary, status_without_cache: String, code: int) -> Dictionary:
	if cached_form.is_empty():
		return _form_result(status_without_cache, {}, false, code)
	_log("Feedback form unavailable (HTTP %d) — using the cached copy." % code)
	return _classify_form(cached_form, true, code)


func _form_result(status: String, form: Dictionary, from_cache: bool, code: int) -> Dictionary:
	return {"status": status, "form": form, "from_cache": from_cache, "response_code": code}


func _is_form_shape(form: Dictionary) -> bool:
	if not form.get("availability", null) is String:
		return false
	var schema: Variant = form.get("schema", null)
	if schema == null:
		return true
	return schema is Dictionary and (schema as Dictionary).get("blocks", null) is Array


func _current_scene_name() -> String:
	var tree: SceneTree = Engine.get_main_loop() as SceneTree
	if tree == null or tree.current_scene == null:
		return ""
	# Same value as the bug report context's sceneName.
	return str(tree.current_scene.name)


func _cache_path(link_token: String) -> String:
	return "%s/%s.json" % [CACHE_DIR, link_token]


func _persists_cache() -> bool:
	return _config == null or _config.enable_reports


func _read_cache(link_token: String) -> Dictionary:
	if not _persists_cache():
		return _memory_cache.get(link_token, {})
	var path: String = _cache_path(link_token)
	if not FileAccess.file_exists(path):
		return {}
	var file: FileAccess = FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {}
	var text: String = file.get_as_text()
	file.close()
	var json: JSON = JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {}
	var data: Dictionary = json.data as Dictionary
	if not data.get("form", null) is Dictionary or not _is_form_shape(data["form"] as Dictionary):
		return {}
	return data


func _write_cache(link_token: String, etag: String, form: Dictionary) -> void:
	var entry: Dictionary = {
		"etag": etag,
		"fetched_at": Time.get_datetime_string_from_system(true),
		"form": form,
	}
	if not _persists_cache():
		_memory_cache[link_token] = entry
		return
	DirAccess.make_dir_recursive_absolute(CACHE_DIR)
	var file: FileAccess = FileAccess.open(_cache_path(link_token), FileAccess.WRITE)
	if file == null:
		_log("Failed to cache feedback form %s." % link_token)
		return
	file.store_string(JSON.stringify(entry))
	file.close()


func _delete_cache(link_token: String) -> void:
	if link_token.is_empty() or not is_valid_link_token(link_token):
		return
	_memory_cache.erase(link_token)
	if not _persists_cache():
		return
	var path: String = _cache_path(link_token)
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
