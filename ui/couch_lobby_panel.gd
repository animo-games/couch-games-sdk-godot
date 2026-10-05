## Reusable entry controls only. The game owns start rules and active-match state.
class_name CouchLobbyPanel
extends VBoxContainer
signal start_game_requested
@export var title := "Multiplayer"
@export var match_active := false
var sdk: Node
var _host: Button
var _join: Button
var _invite: Button
var _leave: Button
var _start: Button
var _id: LineEdit
var _status: Label
var _roster: Label
var _confirmation: ConfirmationDialog
var _pending_invite := ""
var _confirm_leave := false
var _entry_ready := false

func _ready() -> void:
	if sdk == null: sdk = get_node_or_null("/root/CouchGames")
	var heading := Label.new()
	heading.text = title
	add_child(heading)
	_host = _button("Host", _on_host)
	_id = LineEdit.new()
	_id.placeholder_text = "Lobby ID"
	add_child(_id)
	_join = _button("Join", func(): _join_lobby(_id.text.strip_edges()))
	_invite = _button("Invite", _on_invite)
	_leave = _button("Leave", _on_leave)
	_start = _button("Start game", start_game_requested.emit)
	_roster = Label.new()
	add_child(_roster)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	add_child(_status)
	_confirmation = ConfirmationDialog.new()
	_confirmation.dialog_text = "Leave the current match? Unsaved match progress may be lost."
	_confirmation.confirmed.connect(_accept_switch)
	_confirmation.canceled.connect(func(): _pending_invite = ""; _confirm_leave = false)
	add_child(_confirmation)
	if sdk == null:
		_status.text = "CouchGames is unavailable"
		return
	sdk.capabilities_changed.connect(_refresh)
	sdk.initialization_state_changed.connect(func(_state): _refresh())
	sdk.lobby.state_changed.connect(func(_state): _refresh())
	sdk.lobby.players_changed.connect(func(_players): _refresh())
	sdk.lobby.operation_failed.connect(func(code, message): _status.text = code + ": " + message)
	sdk.lobby.join_requested.connect(_on_join_requested)
	await sdk.init()
	_refresh()
	_entry_ready = true
	var launch_id: String = sdk.lobby.consume_join_request()
	if launch_id.is_empty(): launch_id = _pending_invite
	_pending_invite = ""
	if not launch_id.is_empty(): _on_join_requested(launch_id)

func _button(label: String, callback: Callable) -> Button:
	var button := Button.new()
	button.text = label
	button.pressed.connect(callback)
	add_child(button)
	return button

func _refresh() -> void:
	if sdk == null: return
	var entering: bool = sdk.lobby.state in ["creating", "joining", "leaving"]
	var joined: bool = sdk.lobby.state == "joined"
	_host.visible = sdk.supports("lobby_host")
	_join.visible = sdk.supports("lobby_join")
	_id.visible = _join.visible
	_invite.visible = sdk.supports("friend_invites")
	_leave.visible = _host.visible or _join.visible
	_host.disabled = joined or entering
	_join.disabled = joined or entering
	_invite.disabled = not joined or entering
	_leave.disabled = sdk.lobby.state == "idle"
	_start.visible = sdk.lobby.is_host() and sdk.lobby.is_available
	_start.disabled = match_active or entering
	var lines := PackedStringArray()
	for player in sdk.lobby.get_players():
		lines.append("%s (%s)" % [player.username, player.role])
	_roster.text = "\n".join(lines)
	_status.text = sdk.initialization_error if sdk.initialization_state == "failed" else sdk.lobby.state + (" · " + sdk.lobby.lobby_id if joined else "")

func _on_host() -> void:
	_show_response(await sdk.lobby.host())
func _on_invite() -> void:
	_show_response(await sdk.lobby.open_invite_overlay())
func _on_leave() -> void:
	if match_active:
		_confirm_leave = true
		_confirmation.popup_centered()
	else:
		sdk.lobby.leave()
func _on_join_requested(id: String) -> void:
	if not _entry_ready:
		_pending_invite = id
		return
	if sdk.lobby.lobby_id == id: return
	_pending_invite = id
	if match_active or sdk.lobby.state != "idle":
		_confirmation.popup_centered()
	else:
		_accept_switch()
func _accept_switch() -> void:
	sdk.lobby.consume_join_request()
	if _confirm_leave:
		_confirm_leave = false
		sdk.lobby.leave()
		return
	var id := _pending_invite
	_pending_invite = ""
	if id.is_empty(): return
	sdk.lobby.leave()
	_join_lobby(id)
func _join_lobby(id: String) -> void:
	_show_response(await sdk.lobby.join(id))
func _show_response(response: CouchGamesSDKResponse) -> void:
	if not response.success:
		_status.text = str(response.metadata.get("error_code", "error")) + ": " + response.error
