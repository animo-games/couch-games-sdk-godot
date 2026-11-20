## CouchConnection's built-in notice: draws CouchConnection.overlay_lines() at
## the top of the screen, and nothing when there are none. It runs while the
## game is paused, so a game that pauses on a drop still shows it. Built from
## BiProduct's net_connection_status.gd.
##
## CouchConnection adds it as a child when overlay_enabled is on and the
## platform does not draw its own notices (not on the web). To draw your own,
## turn overlay_enabled off and read the same overlay_lines().
class_name CouchConnectionOverlay
extends CanvasLayer

var connection: Node = null

var _panel: PanelContainer
var _label: Label
var _shown := ""


## Built here, not in _ready, so it is complete as soon as it exists.
func _init() -> void:
	layer = 110
	process_mode = Node.PROCESS_MODE_ALWAYS

	_panel = PanelContainer.new()
	_panel.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_panel.offset_left = -190.0
	_panel.offset_top = 24.0
	_panel.offset_right = 190.0
	_panel.offset_bottom = 88.0
	_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.055, 0.063, 0.08, 0.94)
	style.border_color = Color(1.0, 0.66, 0.2, 1.0)
	style.set_border_width_all(2)
	style.set_corner_radius_all(10)
	style.content_margin_left = 18.0
	style.content_margin_right = 18.0
	style.content_margin_top = 10.0
	style.content_margin_bottom = 10.0
	_panel.add_theme_stylebox_override(&"panel", style)
	add_child(_panel)

	_label = Label.new()
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_label.add_theme_font_size_override(&"font_size", 18)
	_panel.add_child(_label)
	_panel.hide()


func _process(_delta: float) -> void:
	var lines: Array = connection.overlay_lines() if connection != null else []
	var text := "\n".join(PackedStringArray(lines))
	if text == _shown:
		return
	_shown = text
	_label.text = text
	_panel.visible = not text.is_empty()
