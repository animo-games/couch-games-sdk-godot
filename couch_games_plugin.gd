@tool
extends EditorPlugin

const _MENU_ITEM := "Couch Games: Build & Upload Web…"
const _SLUG_SETTING := "couch_games/deploy/slug"
const _UPLOAD_SCRIPT := "res://addons/couch-games-sdk/build_and_upload.gd"

# name, default, type, hint, hint_string
const _SETTINGS := [
	["couch_games/mock/force_mock", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/enable_debug_overlay", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/overlay_toggle_key", KEY_F10, TYPE_INT, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/latency_ms", 0, TYPE_INT, PROPERTY_HINT_RANGE, "0,2000,10"],
	["couch_games/mock/local_username", "Player 1", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_name", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_url", "https://couch.games/mock", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/local/enabled", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/local/port", 8974, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535,1"],
	[_SLUG_SETTING, "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
]

var _dialog: ConfirmationDialog
var _slug_edit: LineEdit
var _result_dialog: AcceptDialog
var _thread: Thread
var _running := false


func _enter_tree():
	for setting in _SETTINGS:
		_define_setting(setting[0], setting[1], setting[2], setting[3], setting[4])
	add_autoload_singleton("CouchGames", "./couch_games_sdk.gd")
	_build_dialogs()
	add_tool_menu_item(_MENU_ITEM, _open_upload_dialog)


func _exit_tree():
	remove_tool_menu_item(_MENU_ITEM)
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if is_instance_valid(_dialog):
		_dialog.queue_free()
	if is_instance_valid(_result_dialog):
		_result_dialog.queue_free()
	remove_autoload_singleton("CouchGames")


# --- Build & Upload button -------------------------------------------------

func _build_dialogs() -> void:
	var base := EditorInterface.get_base_control()

	_dialog = ConfirmationDialog.new()
	_dialog.title = "Couch Games — Build & Upload"
	_dialog.ok_button_text = "Build & Upload"
	var box := VBoxContainer.new()
	var label := Label.new()
	label.text = "Exports the \"Web\" preset and uploads it as a new dev version.\nGame slug (developer portal):"
	box.add_child(label)
	_slug_edit = LineEdit.new()
	_slug_edit.placeholder_text = "my-game-slug"
	box.add_child(_slug_edit)
	_dialog.add_child(box)
	_dialog.register_text_enter(_slug_edit)
	_dialog.confirmed.connect(_on_confirmed)
	base.add_child(_dialog)

	_result_dialog = AcceptDialog.new()
	_result_dialog.title = "Couch Games"
	base.add_child(_result_dialog)


func _open_upload_dialog() -> void:
	if _running:
		_show_result("Couch Games", "An upload is already in progress.")
		return
	_slug_edit.text = str(ProjectSettings.get_setting(_SLUG_SETTING, ""))
	_dialog.popup_centered()
	_slug_edit.grab_focus()


func _on_confirmed() -> void:
	var slug := _slug_edit.text.strip_edges()
	if slug == "":
		_show_result("Couch Games", "A game slug is required.")
		return
	# Persist the slug so next time the field is pre-filled.
	ProjectSettings.set_setting(_SLUG_SETTING, slug)
	ProjectSettings.save()

	_running = true
	print("[Couch Games] Building & uploading \"%s\"… (output below)" % slug)
	_thread = Thread.new()
	_thread.start(_run_upload.bind(slug))


# Runs on a background thread so the editor stays responsive. Reuses the exact
# same headless pipeline as the CLI launchers.
func _run_upload(slug: String) -> void:
	var args := [
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", _UPLOAD_SCRIPT,
		"--", slug,
	]
	var output := []
	var rc := OS.execute(OS.get_executable_path(), args, output, true)
	call_deferred("_on_upload_finished", rc, "\n".join(PackedStringArray(output)))


func _on_upload_finished(rc: int, text: String) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	_running = false
	print(text)
	if rc == 0:
		_show_result("Couch Games — Success", "Upload complete. See the Output panel for details.")
	else:
		_show_result("Couch Games — Failed", "Build/upload failed (exit %d).\nSee the Output panel for details." % rc)


func _show_result(title: String, message: String) -> void:
	_result_dialog.title = title
	_result_dialog.dialog_text = message
	_result_dialog.popup_centered()


# Registers a project setting with its default, without overwriting a value
# the user already changed. The runtime reads these with the same defaults, so
# exports work even if the plugin never ran.
func _define_setting(name: String, default_value: Variant, type: int, hint: int, hint_string: String) -> void:
	if not ProjectSettings.has_setting(name):
		ProjectSettings.set_setting(name, default_value)
	ProjectSettings.set_initial_value(name, default_value)
	ProjectSettings.add_property_info({
		"name": name,
		"type": type,
		"hint": hint,
		"hint_string": hint_string,
	})
