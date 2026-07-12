class_name ForgeLoggerReportBuilder
extends RefCounted
## Constructs report payloads. Isolates payload building so it can easily
## adapt when API DTOs change.

const LOG_PREFIX: String = "[ForgeLogger] "


static func build_report_payload(report: ForgeLoggerModels.ReportData) -> Dictionary:
	var report_dto: Dictionary = {
		"title": report.title,
	}
	if report.description != "":
		report_dto["description"] = report.description
	if report.severity != "":
		report_dto["severity"] = report.severity
	if report.reporter_type != "":
		report_dto["reporterType"] = report.reporter_type
	if report.source_channel != "":
		report_dto["sourceChannel"] = report.source_channel
	if report.fingerprint != "":
		report_dto["fingerprint"] = report.fingerprint

	var payload: Dictionary = {
		"sessionId": report.session_id,
		"clientRequestId": ForgeLoggerModels.generate_uuid(),
		"report": report_dto,
	}

	# Runtime context collected by ForgeLogger, plus custom_data and tags in extra.
	var context: Dictionary = report.context.duplicate(true)
	var extra: Dictionary = context.get("extra", {}) as Dictionary
	if not report.custom_data.is_empty():
		extra.merge(report.custom_data, true)
	if not report.tags.is_empty():
		extra["tags"] = Array(report.tags)
	if not extra.is_empty():
		context["extra"] = extra
	if not context.is_empty():
		payload["context"] = context

	# Attach IDs of already-uploaded events.
	if not report.event_ids.is_empty():
		payload["eventIds"] = report.event_ids

	# Build attachments array from uploads (ReportAttachmentDto format).
	if not report.uploads.is_empty():
		var attachments: Array[Dictionary] = []
		for u: Dictionary in report.uploads:
			var att: Dictionary = {
				"uploadId": u.get("upload_id", ""),
				"attachmentType": u.get("type", "other"),
				"fileName": u.get("filename", ""),
			}
			if u.get("mime_type", "") != "":
				att["mimeType"] = u.get("mime_type", "")
			var sz: int = u.get("size_bytes", 0) as int
			if sz > 0:
				att["sizeBytes"] = sz
			attachments.append(att)
		payload["attachments"] = attachments

	return payload


static func build_from_dict(data: Dictionary, session_id: String = "") -> ForgeLoggerModels.ReportData:
	var report: ForgeLoggerModels.ReportData = ForgeLoggerModels.ReportData.new()
	report.title = data.get("title", "Untitled Bug Report")
	report.description = data.get("description", "")
	report.severity = data.get("severity", "medium")
	report.reporter_type = data.get("reporter_type", "player")
	report.fingerprint = data.get("fingerprint", "")
	report.session_id = session_id

	var raw_tags: Variant = data.get("tags", [])
	if raw_tags is Array:
		for t: Variant in raw_tags:
			report.tags.append(str(t))

	var raw_custom: Variant = data.get("custom_data", {})
	if raw_custom is Dictionary:
		report.custom_data = raw_custom as Dictionary

	return report
