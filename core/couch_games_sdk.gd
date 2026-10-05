# One SDK autoload with Couch, optional Steam, native local relay, and mock
# providers. Dependency presence does not select a backend. Shared APIs parse
# without Steam installed; only explicit selection loads its runtime adapter.

extends Node

## Play-mode selection made on the parent platform page ("1-device",
## "2-devices"); empty when none has been made (or not on the platform).
signal play_mode_selected(mode: String, code: String)
signal initialization_state_changed(state: String)
signal capabilities_changed
var backend_name := ""
var initialization_state := "initializing"
var initialization_error := ""
var initialization_timeout_ms := 10000
var backend_override: CouchGamesBackend # Test injection before entering the tree.
var achievements: CouchAchievements
const _Achievements := preload("res://addons/couch-games-sdk/achievements/couch_achievements.gd")
var _init_generation := 0
var _init_job: Dictionary = {}

const _FORCE_MOCK_SETTING := "couch_games/mock/force_mock"
const _OVERLAY_ENABLED_SETTING := "couch_games/mock/enable_debug_overlay"
const _LOCAL_ENABLED_SETTING := "couch_games/local/enabled"

const _WebBackend := preload("res://addons/couch-games-sdk/backends/web_backend.gd")
const _MockBackend := preload("res://addons/couch-games-sdk/backends/mock_backend.gd")
const _LocalBackend := preload("res://addons/couch-games-sdk/backends/local_backend.gd")
const _Lobby := preload("res://addons/couch-games-sdk/lobby/couch_lobby.gd")
const _WebRTC := preload("res://addons/couch-games-sdk/webrtc/couch_webrtc.gd")
const _Experience := preload("res://addons/couch-games-sdk/experience/couch_experience.gd")
const _GameFiles := preload("res://addons/couch-games-sdk/game/couch_game_files.gd")
const _Overlay := preload("res://addons/couch-games-sdk/debug/debug_overlay.gd")
const _PathProbe := preload("res://addons/couch-games-sdk/webrtc/path_probe.gd")

var is_available: bool:
	get:
		return _backend != null and _backend.is_available()

## True when running against the local mock instead of the real platform. Use
## this (not is_available, which is true under the mock too) for code that
## must only run on the real platform.
var is_mock: bool:
	get:
		return _backend != null and _backend.is_mock()

var experience_data: Dictionary = {}

## Multiplayer lobby abstraction: players roster + event tunnel.
var lobby: CouchLobby

## WebRTC signaling: handshake relay, peer presence, ICE/TURN configuration.
var webrtc: CouchWebRTC

## The current experience's uploaded files, addressed by basename.
var experience: CouchExperience

## Files that shipped inside this build, addressed by their path relative to it.
var game: CouchGameFiles

## The mock backend, for tests and debug tooling. Null when the real platform
## backend is active.
var mock: CouchGamesMockBackend:
	get:
		return _backend as CouchGamesMockBackend

var _backend: CouchGamesBackend
var _initialized := false
var _initializing := false


# --- Setup ---

func _ready() -> void:
	# The path probe has to go in before anything can create a peer connection.
	# Autoload _ready() runs before the main scene; if a game creates peer
	# connections from an earlier autoload, move CouchGames up that project's
	# autoload list.
	_backend = backend_override if backend_override != null else _create_backend()
	if backend_override != null:
		backend_name = "steam" if backend_override.has_method("achievement_adapter") else "injected"
	if backend_name != "steam":
		_PathProbe.install()
	_backend.name = "Backend"
	add_child(_backend)
	_backend.play_mode_selected.connect(play_mode_selected.emit)
	_backend.capabilities_changed.connect(_on_capabilities_changed)
	achievements = _Achievements.new()
	achievements.name = "Achievements"
	achievements.timeout_ms = int(ProjectSettings.get_setting("couch_games/achievements/timeout_ms", 5000))
	achievements.setup(_backend, ProjectSettings.get_setting("couch_games/achievements/catalog", {}))
	add_child(achievements)
	achievements.ready_changed.connect(func(_value): _on_capabilities_changed())
	lobby = _Lobby.new()
	lobby.name = "Lobby"
	lobby.setup(_backend)
	add_child(lobby)
	webrtc = _WebRTC.new()
	webrtc.name = "WebRTC"
	webrtc.setup(_backend)
	add_child(webrtc)
	experience = _Experience.new()
	experience.name = "Experience"
	experience.setup(_backend)
	add_child(experience)
	game = _GameFiles.new()
	game.name = "GameFiles"
	game.setup(_backend)
	add_child(game)
	if _backend.is_mock():
		print("CouchGames SDK: using mock backend (persistence at %s)" % _MockBackend.SAVE_DIR)
		if _overlay_enabled():
			add_child(_Overlay.create(_backend as CouchGamesMockBackend))


func init() -> void:
	if _initialized:
		return
	if _initializing:
		while _initializing:
			await get_tree().process_frame
		return
	_initializing = true
	_init_generation += 1
	_init_job = {"done": false, "generation": _init_generation}
	var job := _init_job
	_set_initialization_state("initializing")
	_initialize_backend(job)
	var deadline := Time.get_ticks_msec() + maxi(1, int(ProjectSettings.get_setting("couch_games/initialization_timeout_ms", initialization_timeout_ms)))
	while not job.done and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	if not job.done:
		_init_generation += 1
		initialization_error = "Backend initialization timed out"
		_backend.shutdown()
		_set_initialization_state("failed")
	elif not _backend.initialization_error.is_empty() or not _backend.is_available():
		initialization_error = _backend.initialization_error if not _backend.initialization_error.is_empty() else "Backend unavailable"
		_set_initialization_state("failed")
	else:
		achievements.setup(_backend, ProjectSettings.get_setting("couch_games/achievements/catalog", {}))
		lobby.refresh_players()
		_set_initialization_state("ready")
		_on_capabilities_changed()
		# Preserve populated get_url()/experience_data for responsive Couch/local
		# providers. Unsupported or stuck metadata cannot fail initialization or
		# hold it past either the optional grace period or the overall deadline.
		if _backend.supports("experience_files"):
			var metadata_job := {"done": false}
			_load_experience_data(_init_generation, metadata_job)
			var metadata_deadline := mini(deadline, Time.get_ticks_msec() + maxi(0, int(ProjectSettings.get_setting("couch_games/experience_metadata_timeout_ms", 1000))))
			while not metadata_job.done and Time.get_ticks_msec() < metadata_deadline:
				await get_tree().process_frame
	_initializing = false
	_initialized = true

func _initialize_backend(job: Dictionary) -> void:
	await _backend.initialize()
	if job.generation != _init_generation:
		_backend.shutdown()
		return
	job.done = true

func _load_experience_data(generation: int, job: Dictionary) -> void:
	var response := await get_experience_data()
	if generation == _init_generation and response.success and response.payload is Dictionary:
		experience_data = response.payload
	job.done = true

func supports(capability: String) -> bool:
	return initialization_state in ["ready", "degraded"] and _backend != null and _backend.supports(capability)

func _set_initialization_state(value: String) -> void:
	if initialization_state == value: return
	initialization_state = value
	initialization_state_changed.emit(value)

func _on_capabilities_changed() -> void:
	capabilities_changed.emit()
	if initialization_state in ["ready", "degraded"]:
		if not _backend.supports("lobby_events") or not _backend.supports("achievements"):
			_set_initialization_state("degraded")
		else:
			_set_initialization_state("ready")

## Pure selection policy: extension presence is deliberately not an input.
static func select_backend(requested: String, force_mock: bool, couch_detected: bool, web: bool, steam_feature: bool, debug: bool, local_enabled: bool) -> String:
	if force_mock: return "mock"
	if requested != "auto": return requested
	if couch_detected: return "couch"
	if steam_feature: return "steam"
	if not web and debug and local_enabled: return "local"
	return "mock"

func _create_backend() -> CouchGamesBackend:
	backend_name = select_backend(str(ProjectSettings.get_setting("couch_games/backend", "auto")), ProjectSettings.get_setting(_FORCE_MOCK_SETTING, false) or OS.get_cmdline_user_args().has("--couch-mock"), _WebBackend.detect(), OS.has_feature("web"), OS.has_feature("steam"), OS.is_debug_build(), ProjectSettings.get_setting(_LOCAL_ENABLED_SETTING, true))
	match backend_name:
		"couch": return _WebBackend.new()
		"local":
			if not OS.has_feature("web") and OS.is_debug_build(): return _LocalBackend.new()
		"mock": return _MockBackend.new()
		"steam":
			if not OS.has_feature("web"):
				return load("res://addons/couch-games-sdk/backends/steam_backend.gd").new()
	var unavailable := CouchGamesBackend.new()
	unavailable.initialization_error = "Unsupported backend/platform selection: " + backend_name
	return unavailable

func _exit_tree() -> void:
	_init_generation += 1
	if _backend != null:
		_backend.shutdown()


func _overlay_enabled() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return ProjectSettings.get_setting(_OVERLAY_ENABLED_SETTING, true)


# --- Public API ---

## Writes the player's save.
##
## Branch on `response.persisted`, NOT `response.success`. The platform reports
## a refused write as success: true, persisted: false, conflict: true — so a
## game that trusts `success` believes a save landed when it did not.
##
## `expected_revision` (an int from load_save_result()) asserts the revision
## this write replaces, and is the reliable way to overwrite deliberately.
##
## `on_conflict` is left to the game: "" uses the platform default ("no-op"),
## "error" turns a refusal into success: false. Only pass "error" if your retry
## loop is BOUNDED — an uncapped one would spin for the whole session. The SDK
## never sets it for you, precisely because it cannot know that about your game.
func save_game(
	save_data: Dictionary,
	progress: float = 0.0,
	expected_revision: Variant = null,
	on_conflict: String = "",
) -> CouchGamesSDKResponse:
	if expected_revision != null \
			and not (expected_revision is int or expected_revision is float):
		# The platform compares this with a strict ===, so a stringified
		# revision silently refuses every write. Warn rather than coerce: the
		# refusal is the platform's real answer, and hiding it here would make
		# the editor disagree with production.
		push_warning(
			"CouchGames: expected_revision must be the number from "
			+ "load_save_result().revision. The platform will refuse this write."
		)
	return CouchGamesSDKResponse.from_dict(
		await _backend.save_game(save_data, progress, expected_revision, on_conflict)
	)


## The synchronous save the platform handed this session at startup.
##
## An empty payload is AMBIGUOUS: this player has no save, the session had not
## finished starting, or they joined someone else's session and their save was
## withheld. Do not read it as "new player" — starting fresh and saving on that
## basis is what destroys real progress.
##
## Use it only to re-read state you have already established. To decide whether
## a player is new, use load_save_result().
func load_latest_save() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.load_latest_save())


## The awaitable, honest counterpart to load_latest_save(): says WHY there is no
## save, and serves a joined guest their own save as a merge base.
##
## Only `is_safe_to_start_fresh()` (status "not_found") means "new player".
## "unavailable" means a save may well exist and could not be read — start the
## player somewhere sensible, but keep writes disabled.
func load_save_result() -> CouchGamesSaveLoadResult:
	return CouchGamesSaveLoadResult.from_dict(await _backend.load_save_result())


func gameplay_start() -> void:
	await _backend.gameplay_start()


func gameplay_end() -> void:
	await _backend.gameplay_end()


func gameplay_completed() -> void:
	await _backend.gameplay_completed()


func get_experience_date() -> Variant:
	return _backend.get_experience_date()


func get_experience_data() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_experience_data())


func get_game_metadata() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_game_metadata())


func set_game_metadata(category: String, key: String, value: Variant) -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.set_game_metadata(category, key, value))


func unlock_achievement(key: String) -> CouchGamesSDKResponse:
	# Couch's existing response semantics are deliberately preserved. Steam's
	# adapter maps pending to success=false and never changes save-only persisted.
	return CouchGamesSDKResponse.from_dict(await _backend.unlock_achievement(key))


func get_achievements() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_achievements())


func get_session_stats() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_session_stats())


func get_url(_experience_id: String = "") -> String:
	return str(experience_data.get("experienceUrl", ""))


func get_play_mode() -> String:
	return _backend.multiplayer_get_play_mode() if _backend != null else ""


func get_share_code() -> String:
	return _backend.multiplayer_get_share_code() if _backend != null else ""


func is_joining() -> bool:
	return _backend != null and _backend.multiplayer_is_joining()
