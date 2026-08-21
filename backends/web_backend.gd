# Web backend: bridges to the platform's window.CouchGames global over
# JavaScriptBridge. Only active in web exports running inside the Couch Games
# platform page.
#
# The lobby connection is the PLATFORM's WebSocket, owned by the parent page.
# This backend must never open its own: the server allows one connection per
# userId and would kick the platform's socket (close code 1008).
class_name CouchGamesWebBackend
extends CouchGamesBackend

var _window: JavaScriptObject
var _sdk: JavaScriptObject
var _lobby: JavaScriptObject
var _webrtc: JavaScriptObject

# Persistent JS callbacks MUST be held in member vars: a JavaScriptBridge
# callback is garbage-collected as soon as its Godot-side reference dies.
# (_await_promise's local callbacks are fine, since the coroutine frame polling
# `result.completed` keeps them alive for the promise's lifetime.)
var _on_any_event_cb: JavaScriptObject
var _on_players_changed_cb: JavaScriptObject
var _on_webrtc_signal_cb: JavaScriptObject
var _on_webrtc_peer_joined_cb: JavaScriptObject
var _on_webrtc_peer_left_cb: JavaScriptObject
var _on_webrtc_peer_exists_cb: JavaScriptObject
var _on_webrtc_closed_cb: JavaScriptObject
var _on_webrtc_ice_servers_cb: JavaScriptObject
var _on_play_mode_selected_cb: JavaScriptObject

## Derived once from location.href; see build_root().
var _build_root := ""


## True when this export can reach the platform SDK. False for web exports
## hosted outside the platform (itch.io, a local http server), in which case
## the autoload falls back to the mock backend.
static func detect() -> bool:
	if not OS.has_feature("web"):
		return false
	var window := JavaScriptBridge.get_interface("window")
	return window != null and window.CouchGames != null


func is_available() -> bool:
	return _get_sdk() != null


func initialize() -> void:
	_window = JavaScriptBridge.get_interface("window")
	if _window:
		_sdk = _window.CouchGames
	if _sdk:
		_lobby = _sdk.lobby
	if _lobby == null:
		push_warning("CouchGames SDK: platform lobby bridge not available")
		return
	if _lobby.onAnyEvent == null or _lobby.onPlayersChanged == null:
		push_error(
			"CouchGames SDK: platform lobby bridge is outdated. Deploy a platform "
			+ "build with lobby.onAnyEvent/onPlayersChanged before this game build."
		)
		_lobby = null
		return
	_on_any_event_cb = JavaScriptBridge.create_callback(_on_any_event)
	_on_players_changed_cb = JavaScriptBridge.create_callback(_on_players_changed)
	_lobby.onAnyEvent(_on_any_event_cb)
	# Fires immediately with the current roster on registration.
	_lobby.onPlayersChanged(_on_players_changed_cb)
	_setup_webrtc_bridge()
	_setup_play_mode_bridge()


func _setup_webrtc_bridge() -> void:
	if _sdk:
		_webrtc = _sdk.webrtc
	if _webrtc == null:
		push_warning("CouchGames SDK: platform webrtc bridge not available")
		return
	# onSignalingClosed marks the bridge revision that also made connectSignaling
	# default to the lobby room and use the userId as peerId, which is what the
	# game relies on for peer<->player correlation.
	if _webrtc.onSignalingClosed == null:
		push_error(
			"CouchGames SDK: platform webrtc bridge is outdated. Deploy a platform "
			+ "build with webrtc.onSignalingClosed/userId-peerIds before this game build."
		)
		_webrtc = null
		return
	_on_webrtc_signal_cb = JavaScriptBridge.create_callback(_on_webrtc_signal)
	_on_webrtc_peer_joined_cb = JavaScriptBridge.create_callback(_on_webrtc_peer_joined)
	_on_webrtc_peer_left_cb = JavaScriptBridge.create_callback(_on_webrtc_peer_left)
	_on_webrtc_peer_exists_cb = JavaScriptBridge.create_callback(_on_webrtc_peer_exists)
	_on_webrtc_closed_cb = JavaScriptBridge.create_callback(_on_webrtc_closed)
	_on_webrtc_ice_servers_cb = JavaScriptBridge.create_callback(_on_webrtc_ice_servers)
	_webrtc.onSignal(_on_webrtc_signal_cb)
	_webrtc.onPeerJoined(_on_webrtc_peer_joined_cb)
	_webrtc.onPeerLeft(_on_webrtc_peer_left_cb)
	_webrtc.onPeerExists(_on_webrtc_peer_exists_cb)
	_webrtc.onSignalingClosed(_on_webrtc_closed_cb)
	_webrtc.onIceServers(_on_webrtc_ice_servers_cb)


func _setup_play_mode_bridge() -> void:
	if _sdk == null or _sdk.onPlayModeSelected == null:
		return
	_on_play_mode_selected_cb = JavaScriptBridge.create_callback(_on_play_mode_selected)
	_sdk.onPlayModeSelected(_on_play_mode_selected_cb)


# --- Experience files ---

func experience_list_files() -> PackedStringArray:
	var api := _get_experience_api()
	var out := PackedStringArray()
	if not api:
		return out
	var names = api.listFiles()
	if not names:
		return out
	for i in range(int(names.length)):
		out.append(str(names[i]))
	return out


func experience_get_file(file_name: String) -> Dictionary:
	var api := _get_experience_api()
	if not api:
		return {"success": false, "error": "SDK not available"}
	var settled: Dictionary = await _await_promise_settled(api.getFile(file_name))
	if not settled.get("ok", false):
		return {"success": false, "error": _js_error_text(settled.get("value"))}
	# The platform hands back a raw ArrayBuffer here, not the {success, payload}
	# envelope every other verb uses -- and one built by the PARENT realm, so it
	# has to be adopted into this one before the engine will read it.
	var buffer = _adopt_js_buffer(settled.get("value"))
	if buffer == null:
		return {"success": false, "error": "Expected an ArrayBuffer for '%s'" % file_name}
	return {
		"success": true,
		"bytes": JavaScriptBridge.js_buffer_to_packed_byte_array(buffer),
	}


## Re-views a JS buffer through THIS realm's Uint8Array. Null for anything that
## is not buffer-like.
##
## Both `is_js_buffer()` and `js_buffer_to_packed_byte_array()` brand-check with
## `obj instanceof ArrayBuffer`, which is bound to the realm whose constructor
## built the object. The platform hands this frame the PARENT page's SDK by
## reference -- `window.CouchGames` IS the parent's object -- so
## `experience.getFile` resolves with a parent-realm ArrayBuffer. The check
## reports false for it, and the transfer, which repeats the same check, then
## writes no bytes. Symptom: every file fails as "Expected an ArrayBuffer"
## while the network tab shows it downloaded perfectly.
##
## create_object() runs `new window.Uint8Array(value)` in THIS realm, which a
## typed-array constructor accepts from any realm. Going through the
## constructor rather than an eval'd helper keeps this working under a page CSP
## that forbids eval, and leaves nothing behind on window.
func _adopt_js_buffer(value: Variant) -> Variant:
	if not value is JavaScriptObject:
		return null
	# A same-realm buffer already passes; this keeps the whole thing a no-op
	# wherever the realm split does not apply.
	if JavaScriptBridge.is_js_buffer(value):
		return value
	# Duck-typed, because every brand check reachable from here is the same
	# realm-bound one that caused the problem. Without it a non-buffer would
	# construct an empty Uint8Array and be reported as a successful zero-byte
	# read rather than as the error it is.
	if value.byteLength == null:
		return null
	var adopted = JavaScriptBridge.create_object("Uint8Array", value)
	if not JavaScriptBridge.is_js_buffer(adopted):
		return null
	return adopted


func _get_experience_api() -> JavaScriptObject:
	var sdk = _get_sdk()
	if not sdk:
		return null
	# Older platform builds have no experience namespace. Losing files is better
	# reported than crashed on.
	return sdk.experience


func _js_error_text(value: Variant) -> String:
	if value == null:
		return "Unknown error"
	if value is JavaScriptObject:
		var message = value.message
		if message != null:
			return str(message)
	return str(value)


# --- Build files ---

## The directory this build was served from, taken from the running frame's own
## URL. That is the only source: the platform mints each build's path with a
## random suffix (games/<slug>/v73-1a2b3c4d) precisely so it cannot be guessed,
## and the SDK has no other handle on it — get_url() returns the EXPERIENCE url,
## which is a different thing with a rotating id inside it.
func build_root() -> String:
	if not _build_root.is_empty():
		return _build_root
	if _window == null:
		# build_root() is reachable before initialize() (nothing awaits init to
		# call it), so don't depend on that having run.
		_window = JavaScriptBridge.get_interface("window")
	if _window == null:
		return ""

	var href := str(_window.location.href)
	# The play page appends ?cgcap=hook in one capture mode, and a fragment can
	# arrive from anywhere. Neither is part of the path. Fragment first: it sits
	# after the query, and may itself contain a '?'.
	var fragment := href.find("#")
	if fragment != -1:
		href = href.substr(0, fragment)
	var query := href.find("?")
	if query != -1:
		href = href.substr(0, query)

	# Not get_base_dir(): this is a URL, and cutting at the last slash is the
	# whole rule. The guard keeps a pathless URL ("https://host") from being
	# truncated into its own scheme.
	var scheme_end := href.find("://")
	var last_slash := href.rfind("/")
	if scheme_end == -1 or last_slash <= scheme_end + 2:
		push_warning("CouchGames SDK: cannot derive a build root from '%s'" % href)
		return ""
	_build_root = href.substr(0, last_slash)
	return _build_root


func _get_sdk() -> JavaScriptObject:
	if not _sdk:
		if not _window:
			_window = JavaScriptBridge.get_interface("window")
		if _window:
			_sdk = _window.CouchGames
	return _sdk


# --- Classic SDK verbs ---

func save_game(save_data: Dictionary, progress: float) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		push_error("CouchGames SDK: Not available")
		return {"success": false, "error": "SDK not available"}
	var promise = sdk.saveGame(_dict_to_js(save_data), progress)
	return _js_to_dict(await _await_promise(promise))


func load_latest_save() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	# The SDK returns the save data string or null
	var data = sdk.loadLatestSave()
	if data == null:
		return {"success": true, "payload": {}}
	return {"success": true, "payload": data}


func gameplay_start() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayStart()))


func gameplay_end() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayEnd()))


func gameplay_completed() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.gameplayComplete()))


func get_experience_data() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getExperienceData()))


func get_experience_date() -> Variant:
	var sdk = _get_sdk()
	if sdk:
		return sdk.getExperienceDate()
	return null


func get_game_metadata() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(sdk.getGameMetadata())


func set_game_metadata(category: String, key: String, value: Variant) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.setGameMetadata(category, key, value)))


func unlock_achievement(key: String) -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.unlockAchievement(key)))


func get_achievements() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getAchievements()))


func get_session_stats() -> Dictionary:
	var sdk = _get_sdk()
	if not sdk:
		return {"success": false, "error": "SDK not available"}
	return _js_to_dict(await _await_promise(sdk.getSessionStats()))


# --- Lobby ---

func lobby_is_available() -> bool:
	return _lobby != null


func lobby_get_current_game() -> Dictionary:
	if _lobby == null:
		return {}
	return _js_to_dict(_lobby.getCurrentGame())


func lobby_get_players() -> Array:
	if _lobby == null:
		return []
	var players = _js_to_variant(_lobby.getLobbyPlayers())
	return players if players is Array else []


func lobby_get_me() -> Dictionary:
	if _lobby == null:
		return {}
	return _js_to_dict(_lobby.getMe())


func lobby_send_event(event: String, data: Variant, target: Dictionary) -> void:
	if _lobby == null:
		push_warning("CouchGames SDK: lobby not available; event '%s' dropped" % event)
		return
	if target.is_empty():
		_lobby.sendEvent(event, _variant_to_js(data), null)
	else:
		_lobby.sendEvent(event, _variant_to_js(data), _dict_to_js(target))


func _on_any_event(args: Array) -> void:
	# args: [event: String, data: any, senderUserId: String]
	if args.is_empty():
		return
	var event := str(args[0])
	var data: Variant = _js_to_variant(args[1]) if args.size() >= 2 else null
	var sender := ""
	if args.size() >= 3 and args[2] != null:
		sender = str(args[2])
	lobby_event_received.emit(event, data, sender)


func _on_players_changed(args: Array) -> void:
	if args.is_empty():
		return
	var players = _js_to_variant(args[0])
	if players is Array:
		lobby_players_updated.emit(players)


# --- WebRTC signaling ---

func webrtc_is_available() -> bool:
	return _webrtc != null


func webrtc_connect_signaling(room_id: String) -> Dictionary:
	if _webrtc == null:
		return {"success": false, "error": "WebRTC bridge not available"}
	var promise: JavaScriptObject
	if room_id.is_empty():
		# No argument: the platform defaults to the active lobby's room.
		promise = _webrtc.connectSignaling()
	else:
		promise = _webrtc.connectSignaling(room_id)
	return _js_to_dict(await _await_promise(promise))


func webrtc_send_signal(target_peer_id: String, data: Variant) -> void:
	if _webrtc == null:
		push_warning("CouchGames SDK: webrtc bridge not available; signal dropped")
		return
	_webrtc.sendSignal(target_peer_id, _variant_to_js(data))


func webrtc_request_ice_servers() -> void:
	if _webrtc != null:
		_webrtc.requestIceServers()


func webrtc_disconnect() -> void:
	# disconnectSignaling, not disconnect: a JS method named "disconnect" is
	# unreachable through JavaScriptObject (shadowed by Object.disconnect).
	if _webrtc != null:
		_webrtc.disconnectSignaling()


func _on_webrtc_signal(args: Array) -> void:
	# args: [senderPeerId: String, data: Variant (object; JSON string on older platform builds)]
	if args.size() < 2:
		return
	var data: Variant = _js_to_variant(args[1])
	if data is String:
		data = JSON.parse_string(data)
	webrtc_signal_received.emit(str(args[0]), data)


func _on_webrtc_peer_joined(args: Array) -> void:
	if not args.is_empty():
		webrtc_peer_joined.emit(str(args[0]))


func _on_webrtc_peer_left(args: Array) -> void:
	if not args.is_empty():
		webrtc_peer_left.emit(str(args[0]))


func _on_webrtc_peer_exists(args: Array) -> void:
	if not args.is_empty():
		webrtc_peer_exists.emit(str(args[0]))


func _on_webrtc_closed(args: Array) -> void:
	var room := str(args[0]) if not args.is_empty() else ""
	webrtc_signaling_closed.emit(room)


func _on_webrtc_ice_servers(args: Array) -> void:
	if args.is_empty():
		return
	var servers = _js_to_variant(args[0])
	if servers is Array:
		webrtc_ice_servers_updated.emit(servers)


# --- Play mode ---

func multiplayer_get_play_mode() -> String:
	var sdk = _get_sdk()
	if sdk == null or sdk.getPlayMode == null:
		return ""
	var mode = sdk.getPlayMode()
	return str(mode) if mode != null else ""


func multiplayer_get_share_code() -> String:
	var sdk = _get_sdk()
	if sdk == null or sdk.getShareCode == null:
		return ""
	var code = sdk.getShareCode()
	return str(code) if code != null else ""


func multiplayer_is_joining() -> bool:
	var sdk = _get_sdk()
	if sdk == null or sdk.isJoining == null:
		return false
	return bool(sdk.isJoining())


func _on_play_mode_selected(args: Array) -> void:
	var mode := str(args[0]) if args.size() > 0 and args[0] != null else ""
	var code := str(args[1]) if args.size() > 1 and args[1] != null else ""
	play_mode_selected.emit(mode, code)


# --- Awaiting JS promises ---

func _await_promise(promise: JavaScriptObject) -> Variant:
	if not promise:
		return null

	var result = {"completed": false, "data": null}

	var on_success = JavaScriptBridge.create_callback(func(args):
		result.data = args[0]
		result.completed = true
	)
	var on_error = JavaScriptBridge.create_callback(func(args):
		result.data = args[0]
		result.completed = true
	)

	promise.then(on_success).catch(on_error)

	while not result.completed:
		await get_tree().process_frame

	return result.data


## Like _await_promise, but reports WHICH way the promise settled. The classic
## verbs resolve to a {success, error} envelope so they can ignore the
## difference; `experience.getFile` resolves to a bare ArrayBuffer and signals
## failure by rejecting, so for it the difference is the whole message.
## Returns {ok: bool, value: Variant}.
func _await_promise_settled(promise: JavaScriptObject) -> Dictionary:
	if not promise:
		return {"ok": false, "value": "No promise returned"}

	var result = {"completed": false, "ok": false, "value": null}

	var on_success = JavaScriptBridge.create_callback(func(args):
		result.value = args[0]
		result.ok = true
		result.completed = true
	)
	var on_error = JavaScriptBridge.create_callback(func(args):
		result.value = args[0]
		result.ok = false
		result.completed = true
	)

	promise.then(on_success).catch(on_error)

	while not result.completed:
		await get_tree().process_frame

	return {"ok": result.ok, "value": result.value}


# --- Data conversion helpers ---

func _dict_to_js(dict: Dictionary) -> JavaScriptObject:
	var js_obj = JavaScriptBridge.create_object("Object")
	for key in dict.keys():
		var value = dict[key]
		if value is Dictionary:
			js_obj[key] = _dict_to_js(value)
		elif value is Array:
			js_obj[key] = _array_to_js(value)
		else:
			js_obj[key] = value
	return js_obj


func _array_to_js(arr: Array) -> JavaScriptObject:
	var js_arr = JavaScriptBridge.create_object("Array")
	for i in range(arr.size()):
		var value = arr[i]
		if value is Dictionary:
			js_arr[i] = _dict_to_js(value)
		elif value is Array:
			js_arr[i] = _array_to_js(value)
		else:
			js_arr[i] = value
	return js_arr


func _variant_to_js(value: Variant) -> Variant:
	if value is Dictionary:
		return _dict_to_js(value)
	if value is Array:
		return _array_to_js(value)
	return value


func _js_to_variant(js_value: Variant) -> Variant:
	# Scalars cross the bridge as native Variants; only JS objects and arrays
	# need the JSON round-trip. That round-trip is also what makes JSON's usual
	# type degradation (ints arriving as floats) consistent everywhere.
	if typeof(js_value) != TYPE_OBJECT:
		return js_value
	var json = JavaScriptBridge.get_interface("JSON")
	var stringified = json.stringify(js_value)
	if stringified == null:
		return null
	return JSON.parse_string(stringified)


func _js_to_dict(js_obj: Variant) -> Dictionary:
	var parsed = _js_to_variant(js_obj)
	return parsed if parsed is Dictionary else {}
