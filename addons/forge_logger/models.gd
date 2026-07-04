class_name ForgeLoggerModels
extends RefCounted
## Internal data models for the Forge Logger plugin.
## These structures isolate payload building from the API layer.


## Generate a UUIDv4 string (8-4-4-4-12 hex).
## Server accepts this as clientRequestId / upload id; full time-ordered
## UUIDv7 is not required for idempotency.
static func generate_uuid() -> String:
	var bytes: PackedByteArray = PackedByteArray()
	bytes.resize(16)
	for i: int in range(16):
		bytes[i] = randi() & 0xff
	bytes[6] = (bytes[6] & 0x0f) | 0x40  # version 4
	bytes[8] = (bytes[8] & 0x3f) | 0x80  # RFC 4122 variant
	var hex: String = ""
	for b: int in bytes:
		hex += "%02x" % b
	return "%s-%s-%s-%s-%s" % [
		hex.substr(0, 8),
		hex.substr(8, 4),
		hex.substr(12, 4),
		hex.substr(16, 4),
		hex.substr(20, 12),
	]


class SessionData extends RefCounted:
	var session_id: String = ""
	var project_id: String = ""
	var started_at: String = ""
	var game_version: String = ""
	var build_hash: String = ""
	var engine_version: String = ""
	var platform: String = ""
	var device: String = ""
	var locale: String = ""
	var current_scene: String = ""

	func to_dict() -> Dictionary:
		return {
			"session_id": session_id,
			"project_id": project_id,
			"started_at": started_at,
			"game_version": game_version,
			"build_hash": build_hash,
			"engine_version": engine_version,
			"platform": platform,
			"device": device,
			"locale": locale,
			"current_scene": current_scene,
		}

	static func from_dict(data: Dictionary) -> SessionData:
		var s: SessionData = SessionData.new()
		s.session_id = data.get("session_id", "")
		s.project_id = data.get("project_id", "")
		s.started_at = data.get("started_at", "")
		s.game_version = data.get("game_version", "")
		s.build_hash = data.get("build_hash", "")
		s.engine_version = data.get("engine_version", "")
		s.platform = data.get("platform", "")
		s.device = data.get("device", "")
		s.locale = data.get("locale", "")
		s.current_scene = data.get("current_scene", "")
		return s


class UploadData extends RefCounted:
	var upload_id: String = ""
	var type: String = "log_bundle"
	var filename: String = ""
	var mime_type: String = "text/plain"
	var file_path: String = ""
	var size_bytes: int = 0

	func to_dict() -> Dictionary:
		return {
			"upload_id": upload_id,
			"type": type,
			"filename": filename,
			"mime_type": mime_type,
			"file_path": file_path,
			"size_bytes": size_bytes,
		}

	static func from_dict(data: Dictionary) -> UploadData:
		var u: UploadData = UploadData.new()
		u.upload_id = data.get("upload_id", "")
		u.type = data.get("type", "log_bundle")
		u.filename = data.get("filename", "")
		u.mime_type = data.get("mime_type", "text/plain")
		u.file_path = data.get("file_path", "")
		u.size_bytes = data.get("size_bytes", 0)
		return u


class ReportData extends RefCounted:
	var session_id: String = ""
	var title: String = ""
	var description: String = ""
	var severity: String = "medium"
	var reporter_type: String = "player"
	var tags: PackedStringArray = PackedStringArray()
	var custom_data: Dictionary = {}
	var uploads: Array[Dictionary] = []
	var events: Array[Dictionary] = []
	var event_ids: Array[String] = []

	func to_dict() -> Dictionary:
		return {
			"session_id": session_id,
			"title": title,
			"description": description,
			"severity": severity,
			"reporter_type": reporter_type,
			"tags": Array(tags),
			"custom_data": custom_data,
			"uploads": uploads,
			"events": events,
		}

	static func from_dict(data: Dictionary) -> ReportData:
		var r: ReportData = ReportData.new()
		r.session_id = data.get("session_id", "")
		r.title = data.get("title", "")
		r.description = data.get("description", "")
		r.severity = data.get("severity", "medium")
		r.reporter_type = data.get("reporter_type", "player")
		var raw_tags: Variant = data.get("tags", [])
		if raw_tags is Array:
			for t: Variant in raw_tags:
				r.tags.append(str(t))
		r.custom_data = data.get("custom_data", {})
		var raw_uploads: Variant = data.get("uploads", [])
		if raw_uploads is Array:
			for u: Variant in raw_uploads:
				if u is Dictionary:
					r.uploads.append(u as Dictionary)
		var raw_events: Variant = data.get("events", [])
		if raw_events is Array:
			for e: Variant in raw_events:
				if e is Dictionary:
					r.events.append(e as Dictionary)
		return r


class EventData extends RefCounted:
	var id: String = ""
	var session_id: String = ""
	var event_type: String = ""
	var occurred_at: String = ""
	var payload: Dictionary = {}

	func to_dict() -> Dictionary:
		var d: Dictionary = {
			"eventType": event_type,
			"occurredAt": occurred_at,
			"payload": payload,
		}
		if id != "":
			d["id"] = id
		if session_id != "":
			d["sessionId"] = session_id
		return d

	## Returns true if this event has been uploaded and has a backend-assigned ID.
	func has_backend_id() -> bool:
		return id != ""

	static func from_dict(data: Dictionary) -> EventData:
		var e: EventData = EventData.new()
		e.id = str(data.get("id", ""))
		e.session_id = data.get("sessionId", data.get("session_id", ""))
		e.event_type = data.get("eventType", data.get("event_type", ""))
		e.occurred_at = data.get("occurredAt", data.get("occurred_at", ""))
		e.payload = data.get("payload", {})
		return e
