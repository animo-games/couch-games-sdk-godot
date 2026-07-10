# Mock-only debug panel for the CouchGames SDK. Lets you fake a lobby while
# testing in the editor: add/remove guests, change their status, and send
# tunnel events as any fake player. Toggle with the key configured in
# couch_games/mock/overlay_toggle_key (F10 by default — F12 is commonly
# grabbed system-wide on Linux, e.g. by drop-down terminals).
#
# Only ever instantiated by the CouchGames autoload when the mock backend is
# active — it never exists against the real platform.
class_name CouchGamesDebugOverlay
extends CanvasLayer

const _TOGGLE_KEY_SETTING := "couch_games/mock/overlay_toggle_key"
const _STATUSES := ["lobby", "playing", "browsing", "disconnected"]
const _LOG_LIMIT := 50
const _PANEL_WIDTH := 340.0

var _mock: CouchGamesMockBackend
var _toggle_key := KEY_F10

var _panel: PanelContainer
var _players_box: VBoxContainer
var _guest_name_edit: LineEdit
var _sender_option: OptionButton
var _event_edit: LineEdit
var _data_edit: TextEdit
var _target_user_option: OptionButton
var _target_role_option: OptionButton
var _send_error_label: Label
var _status_label: Label
var _log_label: RichTextLabel
var _log_lines: PackedStringArray = []


static func create(mock: CouchGamesMockBackend) -> CouchGamesDebugOverlay:
	var overlay := CouchGamesDebugOverlay.new()
	overlay._mock = mock
	overlay.name = "CouchGamesDebugOverlay"
	return overlay


func _init() -> void:
	layer = 128
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_toggle_key = int(ProjectSettings.get_setting(_TOGGLE_KEY_SETTING, KEY_F10)) as Key
	_build_ui()
	_panel.visible = false
	_mock.mock_event_logged.connect(_on_event_logged)
	_mock.lobby_players_updated.connect(_on_players_updated)
	_refresh_players()


func toggle_visible() -> void:
	_panel.visible = not _panel.visible


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key and key.pressed and not key.echo and key.keycode == _toggle_key:
		toggle_visible()
		get_viewport().set_input_as_handled()


# ────────────────────────────────────────────────
# UI construction (in code — keeps the addon scene-free)
# ────────────────────────────────────────────────

func _build_ui() -> void:
	_panel = PanelContainer.new()
	_panel.anchor_left = 1.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 1.0
	_panel.offset_left = -(_PANEL_WIDTH + 12.0)
	_panel.offset_right = -12.0
	_panel.offset_top = 12.0
	_panel.offset_bottom = -12.0
	add_child(_panel)

	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_panel.add_child(scroll)

	var root := VBoxContainer.new()
	root.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	root.add_theme_constant_override("separation", 8)
	scroll.add_child(root)

	var title := Label.new()
	title.text = "CouchGames Mock"
	root.add_child(title)
	_status_label = _section_label("")
	root.add_child(_status_label)

	root.add_child(_section_label("Players"))
	_players_box = VBoxContainer.new()
	root.add_child(_players_box)

	var add_row := HBoxContainer.new()
	_guest_name_edit = LineEdit.new()
	_guest_name_edit.placeholder_text = "Guest name (optional)"
	_guest_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_row.add_child(_guest_name_edit)
	var add_button := Button.new()
	add_button.text = "Add Guest"
	add_button.pressed.connect(_on_add_guest)
	add_row.add_child(add_button)
	root.add_child(add_row)

	root.add_child(_section_label("Send event"))
	_sender_option = OptionButton.new()
	root.add_child(_labeled_row("As", _sender_option))
	_event_edit = LineEdit.new()
	_event_edit.placeholder_text = "event name"
	root.add_child(_labeled_row("Event", _event_edit))
	_data_edit = TextEdit.new()
	_data_edit.custom_minimum_size = Vector2(0, 64)
	_data_edit.text = "{}"
	root.add_child(_data_edit)
	_target_user_option = OptionButton.new()
	root.add_child(_labeled_row("To user", _target_user_option))
	_target_role_option = OptionButton.new()
	_target_role_option.add_item("(any role)")
	_target_role_option.add_item("host")
	_target_role_option.add_item("guest")
	root.add_child(_labeled_row("To role", _target_role_option))
	_send_error_label = Label.new()
	_send_error_label.visible = false
	_send_error_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	root.add_child(_send_error_label)
	var send_button := Button.new()
	send_button.text = "Send"
	send_button.pressed.connect(_on_send_pressed)
	root.add_child(send_button)

	root.add_child(_section_label("Event log"))
	_log_label = RichTextLabel.new()
	_log_label.custom_minimum_size = Vector2(0, 160)
	_log_label.scroll_following = true
	_log_label.selection_enabled = true
	root.add_child(_log_label)


func _section_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_color_override("font_color", Color(1, 1, 1, 0.5))
	return label


func _labeled_row(text: String, control: Control) -> HBoxContainer:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = text
	label.custom_minimum_size = Vector2(64, 0)
	row.add_child(label)
	control.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(control)
	return row


# ────────────────────────────────────────────────
# Players section
# ────────────────────────────────────────────────

func _refresh_players() -> void:
	_status_label.text = _mock.get_network_status()
	for child in _players_box.get_children():
		child.queue_free()

	_sender_option.clear()
	_target_user_option.clear()
	_target_user_option.add_item("(broadcast)")

	for player in _mock.get_mock_players():
		var uid := str(player.get("userId", ""))
		var username := str(player.get("username", ""))
		var role := str(player.get("role", "guest"))
		var status := str(player.get("status", "lobby"))

		var row := HBoxContainer.new()
		var name_label := Label.new()
		name_label.text = "%s (%s)" % [username, role]
		name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		row.add_child(name_label)

		var status_option := OptionButton.new()
		for s in _STATUSES:
			status_option.add_item(s)
		status_option.selected = maxi(0, _STATUSES.find(status))
		status_option.item_selected.connect(func(index: int):
			_mock.set_player_status(uid, _STATUSES[index])
		)
		row.add_child(status_option)

		if uid != _mock.local_user_id:
			var remove_button := Button.new()
			remove_button.text = "✕"
			remove_button.pressed.connect(func():
				_mock.remove_player(uid)
			)
			row.add_child(remove_button)

			# Only fake players can be senders — game-originated sends belong
			# in game code via CouchGames.lobby.send_event.
			_sender_option.add_item("%s (%s)" % [username, uid])
			_sender_option.set_item_metadata(_sender_option.item_count - 1, uid)

		_target_user_option.add_item("%s (%s)" % [username, uid])
		_target_user_option.set_item_metadata(_target_user_option.item_count - 1, uid)

		_players_box.add_child(row)


func _on_players_updated(_players: Array) -> void:
	_refresh_players()


func _on_add_guest() -> void:
	_mock.add_guest(_guest_name_edit.text.strip_edges())
	_guest_name_edit.clear()


# ────────────────────────────────────────────────
# Send-event section
# ────────────────────────────────────────────────

func _on_send_pressed() -> void:
	_send_error_label.visible = false
	var event := _event_edit.text.strip_edges()
	if event.is_empty():
		_show_send_error("Event name is required")
		return
	if _sender_option.item_count == 0 or _sender_option.selected < 0:
		_show_send_error("Add a guest first — events are sent as a fake player")
		return

	var data: Variant = null
	var data_text := _data_edit.text.strip_edges()
	if not data_text.is_empty() and data_text != "null":
		data = JSON.parse_string(data_text)
		if data == null:
			_show_send_error("Invalid JSON in data")
			return

	var sender_id := str(_sender_option.get_item_metadata(_sender_option.selected))
	var target := {}
	if _target_user_option.selected > 0:
		target["userId"] = str(_target_user_option.get_item_metadata(_target_user_option.selected))
	if _target_role_option.selected > 0:
		target["role"] = _target_role_option.get_item_text(_target_role_option.selected)

	_mock.simulate_event(event, data, sender_id, target)


func _show_send_error(message: String) -> void:
	_send_error_label.text = message
	_send_error_label.visible = true


# ────────────────────────────────────────────────
# Event log
# ────────────────────────────────────────────────

func _on_event_logged(entry: Dictionary) -> void:
	var recipients: Array = entry.get("delivered_to", [])
	var to_text := "(no recipients)"
	if not recipients.is_empty():
		var parts := PackedStringArray()
		for recipient in recipients:
			parts.append(str(recipient))
		to_text = ", ".join(parts)
	var line := "[%s] %s %s  from %s → %s  %s" % [
		entry.get("time", ""),
		"IN " if entry.get("direction") == "in" else "OUT",
		entry.get("event", ""),
		entry.get("sender_user_id", ""),
		to_text,
		JSON.stringify(entry.get("data")),
	]
	_log_lines.append(line)
	if _log_lines.size() > _LOG_LIMIT:
		_log_lines = _log_lines.slice(_log_lines.size() - _LOG_LIMIT)
	_log_label.text = "\n".join(_log_lines)
