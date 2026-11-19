## Native storage owns one request until its callback, even after await timeouts.
## The journal is an award intent, never evidence of provider acknowledgment.
extends Node
signal ready_changed(is_ready: bool)
signal unlocked(key: String)
signal stored(keys: Array)
signal failed(key: String, code: String, message: String)
var bridge: Node
var catalog: Dictionary = {}
var timeout_ms := 5000
var journal_root := "user://couch_games_steam"
var pending: Dictionary = {}
var _acknowledged: Dictionary = {}
var _local: Dictionary = {}
var _inflight: Array = []
var _retry_at := 0
var _retry_delay := 1000
var _ready := false
var _journal_path := ""
var _account := ""
var _journal_valid := true
var _closed := false

func setup(provider: Node, definitions: Dictionary) -> void:
	bridge = provider
	catalog = definitions.duplicate(true)
	_account = bridge.app_id + "/" + bridge.user_id
	bridge.stats_stored.connect(_on_stored)
	# Opaque Steam IDs are constrained here ONLY for safe journal filenames.
	if not str(bridge.app_id).is_valid_int() or int(bridge.app_id) <= 0 or not str(bridge.user_id).is_valid_int() or int(bridge.user_id) <= 0:
		return
	_journal_path = journal_root.path_join(bridge.app_id + "_" + bridge.user_id + ".json")
	_load_journal()
	_update_ready()

func _same_account() -> bool:
	return not _closed and bridge != null and bridge.initialized and _account == bridge.app_id + "/" + bridge.user_id and not _journal_path.is_empty()

func is_ready() -> bool:
	return _same_account() and _journal_valid

func _update_ready() -> void:
	var value := is_ready()
	if value != _ready:
		_ready = value
		ready_changed.emit(value)

func poll(now_ms: int) -> void:
	_update_ready()
	if not is_ready() or not bridge.connected() or not _inflight.is_empty() or pending.is_empty() or now_ms < _retry_at:
		return
	# A local unlocked bit cannot reconcile away a journal: it may be the exact
	# unconfirmed SetAchievement from an earlier process. Re-store pending keys.
	var batch := []
	for key in pending:
		if not catalog.has(key):
			continue
		var read: Dictionary = bridge.read_achievement(_api_name(key))
		if not read.get("success", false):
			failed.emit(key, str(read.get("error_code", "read-failed")), "Cannot read achievement definition/state")
			continue
		if not read.get("unlocked", false) and not bridge.set_achievement(_api_name(key)):
			failed.emit(key, "set-failed", "Steam rejected the achievement")
			continue
		_mark_local(key)
		batch.append(key)
	if batch.is_empty():
		_backoff(now_ms)
		return
	_inflight = batch
	if not bridge.store_stats():
		_inflight = []
		for key in batch:
			failed.emit(key, "store-rejected", "Steam did not accept storage; award retained")
		_backoff(now_ms)

func unlock(key: String) -> Dictionary:
	if key.is_empty() or key.length() > 128 or not catalog.has(key):
		return _result(key, "error", "unknown-key", "Unknown or invalid achievement key")
	if not is_ready():
		return _result(key, "unavailable", "unavailable", "Steam account or award journal unavailable")
	if _acknowledged.has(key):
		return _result(key, "already_unlocked")
	if not pending.has(key):
		var read: Dictionary = bridge.read_achievement(_api_name(key))
		if not read.get("success", false):
			return _result(key, "error", str(read.get("error_code", "read-failed")), "Cannot read achievement definition/state")
		if read.get("unlocked", false):
			_acknowledged[key] = true
			_local[key] = true
			return _result(key, "already_unlocked")
		if pending.size() >= 128:
			return _result(key, "error", "journal-full", "Pending award journal is full")
		pending[key] = true
		if not _save_journal():
			pending.erase(key)
			return _result(key, "error", "journal-write-failed", "Cannot persist the pending award")
		# Signal first local transition only after SetAchievement succeeds.
		if bridge.set_achievement(_api_name(key)):
			_mark_local(key)
		_retry_at = 0
	var deadline := Time.get_ticks_msec() + timeout_ms
	while pending.has(key) and is_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return _result(key, "stored" if _acknowledged.has(key) else "pending")

func get_state(key: String) -> Dictionary:
	if key.is_empty() or key.length() > 128 or not catalog.has(key):
		return _result(key, "error", "unknown-key", "Unknown or invalid achievement key")
	if not is_ready():
		return _result(key, "unavailable", "unavailable", "Steam account unavailable")
	if pending.has(key):
		return _result(key, "pending")
	var read: Dictionary = bridge.read_achievement(_api_name(key))
	if not read.get("success", false):
		return _result(key, "error", str(read.get("error_code", "read-failed")), "Achievement read failed")
	if read.get("unlocked", false):
		_acknowledged[key] = true
		_local[key] = true
		return _result(key, "unlocked")
	return _result(key, "locked")

func get_unlocked() -> Dictionary:
	if not is_ready():
		return {"success": false, "error": "Steam account unavailable", "metadata": {"error_code": "unavailable"}}
	var entries := []
	for key in catalog:
		var state: Dictionary = get_state(key)
		if state.status in ["error", "unavailable"]:
			return {"success": false, "error": state.error, "metadata": {"error_code": state.error_code}}
		if state.provider_acknowledged:
			entries.append({"key": key})
	return {"success": true, "payload": {"achievements": entries}, "metadata": {"pending_keys": pending.keys()}}

func flush() -> Dictionary:
	if not is_ready():
		return {"success": false, "error": "Steam account unavailable", "metadata": {"error_code": "unavailable", "pending_keys": pending.keys()}}
	_retry_at = 0
	var deadline := Time.get_ticks_msec() + timeout_ms
	while not pending.is_empty() and is_ready() and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	return {"success": pending.is_empty(), "metadata": {"error_code": "" if pending.is_empty() else "pending", "pending_keys": pending.keys()}}

func _on_stored(callback_app_id: String, success: bool) -> void:
	if not _same_account() or callback_app_id != bridge.app_id or _inflight.is_empty():
		return
	var batch := _inflight.duplicate()
	_inflight.clear()
	if success:
		for key in batch:
			pending.erase(key)
			_acknowledged[key] = true
		# If journal removal fails, keep it on disk and safely re-store at restart.
		_save_journal()
		_retry_delay = 1000
		_retry_at = 0
		stored.emit(batch)
	else:
		for key in batch:
			failed.emit(key, "store-failed", "Steam storage callback failed; award retained")
		_backoff(Time.get_ticks_msec())

func _backoff(now_ms: int) -> void:
	_retry_at = now_ms + _retry_delay
	_retry_delay = mini(_retry_delay * 2, 60000)

func _mark_local(key: String) -> void:
	if not _local.has(key):
		_local[key] = true
		if pending.has(key) and not _save_journal():
			failed.emit(key, "journal-write-failed", "Cannot persist local transition; award intent remains journaled")
		unlocked.emit(key)

func _api_name(key: String) -> String:
	var value: Variant = catalog[key]
	var api := str(value.get("steam", key)) if value is Dictionary else str(value)
	return key if api.is_empty() else api

func _result(key: String, status: String, code := "", message := "") -> Dictionary:
	if status in ["error", "unavailable"]:
		failed.emit(key, code, message)
	return {"key": key, "status": status, "locally_unlocked": _local.has(key), "provider_acknowledged": _acknowledged.has(key), "already_unlocked": status == "already_unlocked", "error_code": code, "error": message}

func _load_journal() -> void:
	if not FileAccess.file_exists(_journal_path):
		return
	var file := FileAccess.open(_journal_path, FileAccess.READ)
	if file == null or file.get_length() > 65536:
		_journal_valid = false
		return
	var parser := JSON.new()
	var value: Variant = null
	if file != null and parser.parse(file.get_as_text()) == OK:
		value = parser.data
	if not value is Dictionary or value.get("account", "") != _account or not value.get("pending") is Array:
		_journal_valid = false
		return
	var local_keys: Variant = value.get("local_keys", [])
	if value.pending.size() > 128 or not local_keys is Array or local_keys.size() > 128:
		_journal_valid = false
		return
	# Validate the whole file before accepting any entry; malformed awards must
	# never become a partial successful recovery or overwrite the original file.
	var recovered := {}
	for key in value.pending:
		if not key is String or key.is_empty() or key.length() > 128 or recovered.has(key):
			_journal_valid = false
			return
		recovered[key] = true
	var local_recovered := {}
	for key in local_keys:
		if not key is String or not recovered.has(key) or local_recovered.has(key):
			_journal_valid = false
			return
		local_recovered[key] = true
	# Removed catalog entries remain recorded; only known keys retry.
	pending = recovered
	_local = local_recovered

func _save_journal() -> bool:
	if not _same_account():
		return false
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(journal_root)) != OK:
		return false
	var temp := _journal_path + ".tmp"
	var file := FileAccess.open(temp, FileAccess.WRITE)
	if file == null:
		return false
	var serialized := JSON.stringify({"account": _account, "pending": pending.keys(), "local_keys": _local.keys().filter(func(key): return pending.has(key))})
	if serialized.to_utf8_buffer().size() > 65536:
		file.close()
		return false
	file.store_string(serialized)
	file.flush()
	var error := file.get_error()
	file.close()
	return error == OK and DirAccess.rename_absolute(ProjectSettings.globalize_path(temp), ProjectSettings.globalize_path(_journal_path)) == OK

func shutdown() -> void:
	_closed = true
	if bridge != null and bridge.stats_stored.is_connected(_on_stored):
		bridge.stats_stored.disconnect(_on_stored)
	_update_ready()
