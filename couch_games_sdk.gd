# couch_games_sdk.gd
# Autoload singleton for the CouchGames SDK.
#
# Thin facade: every verb delegates to a backend. Inside the Couch Games
# platform (web export) that's CouchGamesWebBackend, which talks to the parent
# page's window.CouchGames via JavaScriptBridge. Everywhere else (editor,
# standalone builds) it's CouchGamesMockBackend — a full local simulation with
# persistence under user://couch_games_mock/ and a debug overlay (F10) for
# faking lobby players and events.

extends Node

const _FORCE_MOCK_SETTING := "couch_games/mock/force_mock"
const _OVERLAY_ENABLED_SETTING := "couch_games/mock/enable_debug_overlay"
const _LOCAL_ENABLED_SETTING := "couch_games/local/enabled"

const _WebBackend := preload("res://addons/couch-games-sdk/backends/web_backend.gd")
const _MockBackend := preload("res://addons/couch-games-sdk/backends/mock_backend.gd")
const _LocalBackend := preload("res://addons/couch-games-sdk/backends/local_backend.gd")
const _Lobby := preload("res://addons/couch-games-sdk/lobby/couch_lobby.gd")
const _Overlay := preload("res://addons/couch-games-sdk/debug/debug_overlay.gd")

# ------------------------------------------------
# Public
# ------------------------------------------------

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

## The mock backend, for tests and debug tooling. Null when the real platform
## backend is active.
var mock: CouchGamesMockBackend:
	get:
		return _backend as CouchGamesMockBackend

var _backend: CouchGamesBackend
var _initialized := false
var _initializing := false

# ────────────────────────────────────────────────
# Setup
# ────────────────────────────────────────────────

func _ready() -> void:
	_backend = _create_backend()
	_backend.name = "Backend"
	add_child(_backend)
	lobby = _Lobby.new()
	lobby.name = "Lobby"
	lobby.setup(_backend)
	add_child(lobby)
	if _backend.is_mock():
		print("CouchGames SDK: using mock backend (persistence at %s)" % _MockBackend.SAVE_DIR)
		if _overlay_enabled():
			add_child(_Overlay.create(_backend as CouchGamesMockBackend))


func init() -> void:
	if _initialized:
		return
	if _initializing:
		# A concurrent caller is already initializing — park until it finishes
		# so every `await CouchGames.init()` resolves after setup completed.
		while _initializing:
			await get_tree().process_frame
		return
	_initializing = true
	await _backend.initialize()
	var data := await get_experience_data()
	if data.success and data.payload:
		experience_data = data.payload
		_backend.load_resource_packs(data.payload)
	_initializing = false
	_initialized = true


func _create_backend() -> CouchGamesBackend:
	var force_mock: bool = ProjectSettings.get_setting(_FORCE_MOCK_SETTING, false) \
		or OS.get_cmdline_user_args().has("--couch-mock")
	if not force_mock and _WebBackend.detect():
		return _WebBackend.new()
	# Local relay: real lobby between multiple local instances over a loopback
	# WebSocket. Debug builds only — a release build must never open a socket.
	if not force_mock and OS.is_debug_build() \
			and ProjectSettings.get_setting(_LOCAL_ENABLED_SETTING, true):
		return _LocalBackend.new()
	return _MockBackend.new()


func _overlay_enabled() -> bool:
	if DisplayServer.get_name() == "headless":
		return false
	return ProjectSettings.get_setting(_OVERLAY_ENABLED_SETTING, true)

# ────────────────────────────────────────────────
# Public API
# ────────────────────────────────────────────────

func save_game(save_data: Dictionary, progress: float = 0.0) -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.save_game(save_data, progress))


func load_latest_save() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.load_latest_save())


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
	return CouchGamesSDKResponse.from_dict(await _backend.unlock_achievement(key))


func get_achievements() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_achievements())


func get_session_stats() -> CouchGamesSDKResponse:
	return CouchGamesSDKResponse.from_dict(await _backend.get_session_stats())


func get_url(_experience_id: String = "") -> String:
	return str(experience_data.get("experienceUrl", ""))
