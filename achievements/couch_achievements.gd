## Shared convenience facade. Classic Couch calls remain on the backend unchanged.
class_name CouchAchievements
extends Node
signal ready_changed(is_ready: bool)
signal unlocked(key: String)
signal stored(keys: Array)
signal failed(key: String, code: String, message: String)
var timeout_ms := 5000
var catalog: Dictionary = {}
var _backend: CouchGamesBackend
var _adapter: Node
var _local: Dictionary = {}
var _acknowledged: Dictionary = {}
var _pending: Dictionary = {}
var _jobs: Dictionary = {}
var _retry_at := 0
var _ready := false

func setup(backend: CouchGamesBackend, definitions: Dictionary) -> void:
	_backend = backend
	catalog = definitions.duplicate(true)
	if backend.has_method("achievement_adapter"):
		_adapter = backend.achievement_adapter()
		if _adapter != null:
			_adapter.ready_changed.connect(ready_changed.emit)
			_adapter.unlocked.connect(unlocked.emit)
			_adapter.stored.connect(stored.emit)
			_adapter.failed.connect(failed.emit)

func is_ready() -> bool:
	return _adapter.is_ready() if _adapter != null else _backend != null and _backend.supports("achievements")

func _process(_delta: float) -> void:
	var value := is_ready()
	if value != _ready:
		_ready = value
		ready_changed.emit(value)
	if _adapter != null or not value or Time.get_ticks_msec() < _retry_at:
		return
	for key in _pending.keys():
		if not _jobs.has(key):
			_start_unlock(key)
	_retry_at = Time.get_ticks_msec() + 2000

func unlock(key: String) -> CouchAchievementResult:
	if _adapter != null:
		return CouchAchievementResult.from_dict(await _adapter.unlock(key))
	if not catalog.has(key):
		return _result(key, "error", "unknown-key", "Unknown achievement key")
	if not is_ready():
		return _result(key, "unavailable", "unavailable", "Achievements unavailable")
	if _acknowledged.has(key):
		return _result(key, "already_unlocked")
	var job: Dictionary
	if not _jobs.has(key):
		job = _start_unlock(key)
	else:
		job = _jobs[key]
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not job.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not job.done:
		_pending[key] = true
		return _result(key, "pending", "timeout", "Achievement completion is uncertain")
	return job.result

func _start_unlock(key: String) -> Dictionary:
	var job := {"done": false}
	_jobs[key] = job
	_perform_unlock(key, job)
	return job

func _perform_unlock(key: String, job: Dictionary) -> void:
	var response: Dictionary = await _backend.unlock_achievement(key)
	if response.get("success", false):
		_pending.erase(key)
		_acknowledged[key] = true
		var already: bool = bool(response.get("alreadyUnlocked", false))
		if not _local.has(key):
			_local[key] = true
			if not already:
				unlocked.emit(key)
		stored.emit([key])
		job.result = _result(key, "already_unlocked" if already else "stored")
	else:
		var code := str(response.get("metadata", {}).get("error_code", "provider-error"))
		if code == "pending":
			_pending[key] = true
			if not _local.has(key):
				_local[key] = true
				unlocked.emit(key)
		job.result = _result(key, "pending" if code == "pending" else "error", code, str(response.get("error", "Achievement failed")))
	job.done = true
	_jobs.erase(key)

func get_state(key: String) -> CouchAchievementResult:
	if _adapter != null:
		return CouchAchievementResult.from_dict(_adapter.get_state(key))
	if not catalog.has(key):
		return _result(key, "error", "unknown-key", "Unknown achievement key")
	if _pending.has(key):
		return _result(key, "pending")
	var response := await get_unlocked()
	if not response.success:
		return _result(key, "unavailable", "unavailable", response.error)
	for entry in response.payload.get("achievements", []):
		if (entry is Dictionary and entry.get("key", "") == key) or entry == key:
			_acknowledged[key] = true
			_local[key] = true
			return _result(key, "unlocked")
	return _result(key, "locked")

func get_unlocked() -> CouchGamesSDKResponse:
	if _adapter != null:
		return CouchGamesSDKResponse.from_dict(_adapter.get_unlocked())
	if not is_ready():
		return CouchGamesSDKResponse.from_dict(CouchGamesBackend._unavailable("Achievements unavailable"))
	var job := {"done": false}
	_read_unlocked(job)
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not job.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not job.done:
		return CouchGamesSDKResponse.from_dict(CouchGamesBackend._unavailable("Achievement read timed out"))
	return CouchGamesSDKResponse.from_dict(job.response)

func _read_unlocked(job: Dictionary) -> void:
	job.response = await _backend.get_achievements()
	if job.response.get("success", false):
		var payload: Variant = job.response.get("payload")
		if payload is String:
			var parser := JSON.new()
			if parser.parse(payload) == OK: payload = parser.data
		if not payload is Dictionary or not payload.get("achievements") is Array:
			job.response = CouchGamesBackend._unavailable("Achievement list is missing or invalid")
		else:
			job.response["payload"] = payload
	job.done = true

func flush() -> CouchGamesSDKResponse:
	if _adapter != null:
		return CouchGamesSDKResponse.from_dict(await _adapter.flush())
	_retry_at = 0
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not _pending.is_empty() and is_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return CouchGamesSDKResponse.from_dict({"success": _pending.is_empty() and is_ready(), "metadata": {"pending_keys": _pending.keys(), "error_code": "" if _pending.is_empty() and is_ready() else "pending" if is_ready() else "unavailable"}})

func _result(key: String, status: String, code := "", message := "") -> CouchAchievementResult:
	if status in ["error", "unavailable"]:
		failed.emit(key, code, message)
	return CouchAchievementResult.from_dict({"key": key, "status": status, "locally_unlocked": _local.has(key), "provider_acknowledged": _acknowledged.has(key), "already_unlocked": status == "already_unlocked", "error_code": code, "error": message})
