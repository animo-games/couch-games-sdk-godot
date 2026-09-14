@tool
extends EditorPlugin

const _BUILD_MENU_ITEM := "Couch Games: Build & Upload Web…"
const _SHARED_MENU_ITEM := "Couch Games: Upload Shared Assets…"
const _SLUG_SETTING := "couch_games/deploy/slug"
const _PRESET_SETTING := "couch_games/deploy/preset"
const _DEFAULT_PRESET := "Web"
const _SHARED_DIR_SETTING := "couch_games/mock/shared_files_dir"
const _DEFAULT_SHARED_DIR := "res://shared_files"
const _BUILD_UPLOAD_SCRIPT := "res://addons/couch-games-sdk/tools/build_and_upload.gd"
const _SHARED_UPLOAD_SCRIPT := "res://addons/couch-games-sdk/tools/upload_shared_assets.gd"
const _AUTOLOAD_SCRIPT := "res://addons/couch-games-sdk/core/couch_games_sdk.gd"
const _PresentPathExportPlugin := preload(
	"res://addons/couch-games-sdk/editor/present_path_export_plugin.gd"
)

# name, default, type, hint, hint_string
const _SETTINGS := [
	["couch_games/mock/force_mock", false, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/enable_debug_overlay", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/overlay_toggle_key", KEY_F10, TYPE_INT, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/latency_ms", 0, TYPE_INT, PROPERTY_HINT_RANGE, "0,2000,10"],
	["couch_games/mock/local_username", "Player 1", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_name", "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_url", "https://couch.games/mock", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	["couch_games/mock/experience_files_dir", "res://experience_files", TYPE_STRING, PROPERTY_HINT_DIR, ""],
	["couch_games/mock/build_files_dir", "res://build/web", TYPE_STRING, PROPERTY_HINT_DIR, ""],
	[_SHARED_DIR_SETTING, _DEFAULT_SHARED_DIR, TYPE_STRING, PROPERTY_HINT_DIR, ""],
	["couch_games/local/enabled", true, TYPE_BOOL, PROPERTY_HINT_NONE, ""],
	["couch_games/local/port", 8974, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535,1"],
	[_SLUG_SETTING, "", TYPE_STRING, PROPERTY_HINT_NONE, ""],
	[_PRESET_SETTING, _DEFAULT_PRESET, TYPE_STRING, PROPERTY_HINT_NONE, ""],
]

var _build_dialog: ConfirmationDialog
var _build_dialog_label: Label
var _build_slug_edit: LineEdit
var _shared_dialog: ConfirmationDialog
var _shared_slug_edit: LineEdit
var _shared_dir_edit: LineEdit
var _shared_overwrite_check: CheckBox
var _result_dialog: AcceptDialog
var _thread: Thread
var _running := false
var _present_path_export_plugin: EditorExportPlugin


func _enter_tree():
	for setting in _SETTINGS:
		_define_setting(setting[0], setting[1], setting[2], setting[3], setting[4])
	_present_path_export_plugin = _PresentPathExportPlugin.new()
	add_export_plugin(_present_path_export_plugin)
	add_autoload_singleton("CouchGames", _AUTOLOAD_SCRIPT)
	_build_dialogs()
	add_tool_menu_item(_BUILD_MENU_ITEM, _open_build_dialog)
	add_tool_menu_item(_SHARED_MENU_ITEM, _open_shared_dialog)


func _exit_tree():
	remove_tool_menu_item(_BUILD_MENU_ITEM)
	remove_tool_menu_item(_SHARED_MENU_ITEM)
	if _present_path_export_plugin:
		remove_export_plugin(_present_path_export_plugin)
		_present_path_export_plugin = null
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if is_instance_valid(_build_dialog):
		_build_dialog.queue_free()
	if is_instance_valid(_shared_dialog):
		_shared_dialog.queue_free()
	if is_instance_valid(_result_dialog):
		_result_dialog.queue_free()
	remove_autoload_singleton("CouchGames")


# --- Dialog construction ---

func _build_dialogs() -> void:
	var base := EditorInterface.get_base_control()

	_build_dialog = ConfirmationDialog.new()
	_build_dialog.title = "Couch Games: Build & Upload"
	_build_dialog.ok_button_text = "Build & Upload"
	var build_box := VBoxContainer.new()
	_build_dialog_label = Label.new()
	# Filled in on open, not here: the preset is a project setting the user can
	# change after the plugin loaded, and a stale name in this dialog is exactly
	# the kind of thing that gets a build deployed from the wrong preset.
	build_box.add_child(_build_dialog_label)
	_build_slug_edit = LineEdit.new()
	_build_slug_edit.placeholder_text = "my-game-slug"
	build_box.add_child(_build_slug_edit)
	_build_dialog.add_child(build_box)
	_build_dialog.register_text_enter(_build_slug_edit)
	_build_dialog.confirmed.connect(_on_build_confirmed)
	base.add_child(_build_dialog)

	_shared_dialog = ConfirmationDialog.new()
	_shared_dialog.title = "Couch Games: Upload Shared Assets"
	_shared_dialog.ok_button_text = "Upload"
	var shared_box := VBoxContainer.new()
	var shared_slug_label := Label.new()
	shared_slug_label.text = "Game slug (developer portal):"
	shared_box.add_child(shared_slug_label)
	_shared_slug_edit = LineEdit.new()
	_shared_slug_edit.placeholder_text = "my-game-slug"
	shared_box.add_child(_shared_slug_edit)
	var shared_dir_label := Label.new()
	shared_dir_label.text = "Shared assets directory:"
	shared_box.add_child(shared_dir_label)
	_shared_dir_edit = LineEdit.new()
	_shared_dir_edit.placeholder_text = _DEFAULT_SHARED_DIR
	shared_box.add_child(_shared_dir_edit)
	_shared_overwrite_check = CheckBox.new()
	_shared_overwrite_check.text = "Replace files that already exist on the platform"
	shared_box.add_child(_shared_overwrite_check)
	_shared_dialog.add_child(shared_box)
	_shared_dialog.register_text_enter(_shared_slug_edit)
	_shared_dialog.confirmed.connect(_on_shared_confirmed)
	base.add_child(_shared_dialog)

	_result_dialog = AcceptDialog.new()
	_result_dialog.title = "Couch Games"
	base.add_child(_result_dialog)


# --- Build & Upload Web… ---

func _open_build_dialog() -> void:
	if _running:
		_show_result("Couch Games", "A tool is already running.")
		return
	_build_dialog_label.text = (
		"Exports the \"%s\" preset and uploads it as a new dev version."
		% _resolve_preset()
		+ "\nGame slug (developer portal):"
	)
	_build_slug_edit.text = str(ProjectSettings.get_setting(_SLUG_SETTING, ""))
	_build_dialog.popup_centered()
	_build_slug_edit.grab_focus()


func _on_build_confirmed() -> void:
	var slug := _build_slug_edit.text.strip_edges()
	if slug == "":
		_show_result("Couch Games", "A game slug is required.")
		return
	# Persist the slug so next time the field is pre-filled.
	ProjectSettings.set_setting(_SLUG_SETTING, slug)
	ProjectSettings.save()
	_run_tool(_BUILD_UPLOAD_SCRIPT, [slug], "Building & uploading \"%s\"" % slug)


# --- Upload Shared Assets… ---

func _open_shared_dialog() -> void:
	if _running:
		_show_result("Couch Games", "A tool is already running.")
		return
	_shared_slug_edit.text = str(ProjectSettings.get_setting(_SLUG_SETTING, ""))
	var dir := str(ProjectSettings.get_setting(_SHARED_DIR_SETTING, _DEFAULT_SHARED_DIR)).strip_edges()
	_shared_dir_edit.text = dir if dir != "" else _DEFAULT_SHARED_DIR
	_shared_overwrite_check.button_pressed = false
	_shared_dialog.popup_centered()
	_shared_slug_edit.grab_focus()


func _on_shared_confirmed() -> void:
	var slug := _shared_slug_edit.text.strip_edges()
	if slug == "":
		_show_result("Couch Games", "A game slug is required.")
		return
	var dir := _shared_dir_edit.text.strip_edges()
	if dir == "":
		dir = _DEFAULT_SHARED_DIR
	# Persist slug and directory -- the same knob the mock reads, so what you
	# tested locally is what gets published.
	ProjectSettings.set_setting(_SLUG_SETTING, slug)
	ProjectSettings.set_setting(_SHARED_DIR_SETTING, dir)
	ProjectSettings.save()

	var args := [slug, dir]
	if _shared_overwrite_check.button_pressed:
		args.append("--overwrite")
	_run_tool(_SHARED_UPLOAD_SCRIPT, args, "Uploading shared assets for \"%s\"" % slug)


# --- Shared background-thread runner ---

# Runs one of the headless tool scripts on a background thread so the editor
# stays responsive. Same pipeline the CLI launchers use. _running guards both
# menu items so at most one tool runs at a time.
func _run_tool(script_path: String, user_args: Array, label: String) -> void:
	_running = true
	print("[Couch Games] %s… (output below)" % label)
	_thread = Thread.new()
	_thread.start(_run_tool_thread.bind(script_path, user_args))


func _run_tool_thread(script_path: String, user_args: Array) -> void:
	var args := [
		"--headless",
		"--path", ProjectSettings.globalize_path("res://"),
		"--script", script_path,
		"--",
	]
	args.append_array(user_args)
	var output := []
	var rc := OS.execute(OS.get_executable_path(), args, output, true)
	call_deferred("_on_tool_finished", rc, "\n".join(PackedStringArray(output)))


func _on_tool_finished(rc: int, text: String) -> void:
	if _thread:
		_thread.wait_to_finish()
		_thread = null
	_running = false
	print(text)
	if rc == 0:
		_show_result("Couch Games: Success", "Done. See the Output panel for details.")
	else:
		_show_result("Couch Games: Failed", "Failed (exit %d).\nSee the Output panel for details." % rc)


func _show_result(title: String, message: String) -> void:
	_result_dialog.title = title
	_result_dialog.dialog_text = message
	_result_dialog.popup_centered()


# Mirrors build_and_upload.gd's own resolution, so the dialog names the preset
# the upload will actually export.
func _resolve_preset() -> String:
	var preset := str(ProjectSettings.get_setting(_PRESET_SETTING, _DEFAULT_PRESET)).strip_edges()
	return preset if preset != "" else _DEFAULT_PRESET


# Registers a project setting with its default without clobbering a value the
# user already changed. The runtime reads these with the same defaults, so
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
