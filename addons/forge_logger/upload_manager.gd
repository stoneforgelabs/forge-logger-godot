class_name ForgeLoggerUploadManager
extends RefCounted
## Handles file upload logic: collecting log files and sending them to the API.

const LOG_PREFIX: String = "[ForgeLogger] "

var _config: ForgeLoggerConfig = null
var _http: ForgeLoggerHttpClient = null


func initialize(config: ForgeLoggerConfig, http: ForgeLoggerHttpClient) -> void:
	_config = config
	_http = http


func collect_log_files() -> Array[ForgeLoggerModels.UploadData]:
	var uploads: Array[ForgeLoggerModels.UploadData] = []
	var log_dir: String = OS.get_user_data_dir()

	var candidates: PackedStringArray = PackedStringArray([
		"godot.log",
		"logs/godot.log",
	])

	for candidate: String in candidates:
		var full_path: String = log_dir.path_join(candidate)
		if FileAccess.file_exists(full_path):
			var upload: ForgeLoggerModels.UploadData = ForgeLoggerModels.UploadData.new()
			upload.type = "log_bundle"
			upload.filename = candidate.get_file()
			upload.mime_type = "text/plain"
			upload.file_path = full_path
			uploads.append(upload)

	return uploads


func upload_file(session_id: String, upload_data: ForgeLoggerModels.UploadData) -> String:
	if not FileAccess.file_exists(upload_data.file_path):
		_log("Upload file not found: %s" % upload_data.file_path)
		return ""

	var file: FileAccess = FileAccess.open(upload_data.file_path, FileAccess.READ)
	if file == null:
		_log("Cannot open file for upload: %s" % upload_data.file_path)
		return ""

	var size_bytes: int = file.get_length()
	var file_bytes: PackedByteArray = file.get_buffer(size_bytes)
	file.close()
	upload_data.size_bytes = size_bytes

	# Empty files happen legitimately: release exports buffer godot.log and
	# flush it only on exit. A zero-byte PUT is also rejected by GCS (411),
	# so skip early with a clear message instead of failing downstream.
	if size_bytes == 0:
		_log("Upload skipped, file is empty: %s" % upload_data.file_path)
		return ""

	# Step 1: Create upload record in GCS via the API.
	var payload: Dictionary = {
		"sessionId": session_id,
		"attachmentType": upload_data.type,
		"fileName": upload_data.filename,
		"mimeType": upload_data.mime_type,
		"sizeBytes": size_bytes,
	}

	var result: Dictionary = await _http.create_upload(payload)
	if not result.get("success", false):
		var err_body: Dictionary = result.get("body", {})
		var error_msg: String = str(err_body.get("message", ""))
		_log("Upload create failed for %s (HTTP %d). %s" % [upload_data.filename, result.get("response_code", 0), error_msg])
		return ""

	var body: Dictionary = result.get("body", {})
	var upload_id: String = str(body.get("uploadId", body.get("id", "")))
	var upload_url: String = str(body.get("uploadUrl", body.get("upload_url", "")))

	if upload_url.is_empty():
		_log("No upload URL returned for %s (id: %s)." % [upload_data.filename, upload_id])
		return ""

	# Step 2: PUT file content to the signed upload URL.
	var put_result: Dictionary = await _http.put_raw(upload_url, upload_data.mime_type, file_bytes)
	if put_result.get("success", false):
		upload_data.upload_id = upload_id
		_log("Uploaded: %s -> %s" % [upload_data.filename, upload_id])
		return upload_id
	else:
		_log("Upload PUT failed for %s (HTTP %d)." % [upload_data.filename, put_result.get("response_code", 0)])
		return ""


func upload_all_logs(session_id: String) -> Array[Dictionary]:
	var log_files: Array[ForgeLoggerModels.UploadData] = collect_log_files()
	var upload_refs: Array[Dictionary] = []

	for log_file: ForgeLoggerModels.UploadData in log_files:
		var upload_id: String = await upload_file(session_id, log_file)
		if upload_id != "":
			upload_refs.append(log_file.to_dict())

	return upload_refs


## Upload the in-memory engine log capture as a log_bundle attachment.
## The text is staged to a file so it goes through the same upload path
## (and size accounting) as file-based logs.
func upload_captured_log(session_id: String, text: String) -> Array[Dictionary]:
	if text.is_empty():
		return []

	var dir_path: String = OS.get_user_data_dir().path_join("forge_logger")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var file_path: String = dir_path.path_join("capture.log")
	var file: FileAccess = FileAccess.open(file_path, FileAccess.WRITE)
	if file == null:
		_log("Cannot stage captured log: %s" % file_path)
		return []
	file.store_string(text)
	file.close()

	var upload_data: ForgeLoggerModels.UploadData = ForgeLoggerModels.UploadData.new()
	upload_data.type = "log_bundle"
	upload_data.filename = "game.log"
	upload_data.mime_type = "text/plain"
	upload_data.file_path = file_path

	var upload_id: String = await upload_file(session_id, upload_data)
	if upload_id != "":
		return [upload_data.to_dict()]
	return []


func capture_screenshot(viewport: Viewport) -> String:
	var image: Image = viewport.get_texture().get_image()
	if image == null:
		_log("Failed to capture screenshot: could not get viewport image.")
		return ""

	var timestamp: String = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var dir_path: String = OS.get_user_data_dir().path_join("screenshots")
	DirAccess.make_dir_recursive_absolute(dir_path)
	var file_path: String = dir_path.path_join("screenshot_%s.png" % timestamp)

	var err: Error = image.save_png(file_path)
	if err != OK:
		_log("Failed to save screenshot: %s (error %d)." % [file_path, err])
		return ""

	_log("Screenshot saved: %s" % file_path)
	return file_path


func upload_screenshot(session_id: String, screenshot_path: String) -> Array[Dictionary]:
	if screenshot_path.is_empty() or not FileAccess.file_exists(screenshot_path):
		return []

	var upload_data: ForgeLoggerModels.UploadData = ForgeLoggerModels.UploadData.new()
	upload_data.type = "screenshot"
	upload_data.filename = screenshot_path.get_file()
	upload_data.mime_type = "image/png"
	upload_data.file_path = screenshot_path

	var upload_id: String = await upload_file(session_id, upload_data)
	if upload_id != "":
		return [upload_data.to_dict()]
	return []


func _log(msg: String) -> void:
	print(LOG_PREFIX + msg)
