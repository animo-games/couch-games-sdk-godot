## Minimal interactive live fixture. No fake results are reported as Steam proof.
extends Node
class FixtureLobbyPanel extends CouchLobbyPanel:
	var visibility := "private"
	func _on_host() -> void:
		_show_response(await sdk.lobby.host({"visibility":visibility, "max_players":2}))

var sdk: Node
var session: CouchSession
var transport: Object
var _revision := 0
var _output: RichTextLabel
var _lines := PackedStringArray()
func _ready() -> void:
	var app_id := 0
	var api_name := ""
	var visibility := "private"
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--app-id="): app_id = int(arg.trim_prefix("--app-id="))
		if arg.begins_with("--achievement="): api_name = arg.trim_prefix("--achievement=")
		if arg.begins_with("--visibility="): visibility = arg.trim_prefix("--visibility=")
	if visibility not in ["private", "friends", "public"]:
		printerr("FAIL: unknown fixture lobby visibility")
		get_tree().quit(1)
		return
	ProjectSettings.set_setting("couch_games/backend", "steam")
	ProjectSettings.set_setting("couch_games/steam/app_id", app_id)
	ProjectSettings.set_setting("couch_games/steam/game_id", "couch-sdk-steam-fixture")
	if not api_name.is_empty():
		ProjectSettings.set_setting("couch_games/achievements/catalog", {"fixture_award": api_name})
	sdk = load("res://addons/couch-games-sdk/core/couch_games_sdk.gd").new()
	add_child(sdk)
	var panel := FixtureLobbyPanel.new()
	panel.sdk = sdk
	panel.visibility = visibility
	panel.title = "Steam SDK acceptance fixture (%s lobby)" % visibility
	add_child(panel)
	panel.start_game_requested.connect(_start_session)
	sdk.lobby.players_changed.connect(func(_players):
		if session != null: session.evaluate(Time.get_ticks_msec()))
	sdk.lobby.event_received.connect(_on_event)
	sdk.lobby.event_send_failed.connect(func(code, message, _peer): _log("SEND FAILED %s: %s" % [code, message]))
	var ping := Button.new()
	ping.text = "Send reliable fixture event"
	ping.pressed.connect(_send_event)
	panel.add_child(ping)
	var award := Button.new()
	award.text = "Read / award configured local achievement"
	award.disabled = api_name.is_empty()
	award.tooltip_text = "Supply a published achievement API name to enable this test."
	award.pressed.connect(_award)
	panel.add_child(award)
	var baseline := Button.new()
	baseline.text = "Start local session"
	baseline.pressed.connect(_start_session)
	panel.add_child(baseline)
	_output = RichTextLabel.new()
	_output.custom_minimum_size = Vector2(540, 180)
	_output.scroll_following = true
	panel.add_child(_output)
	await sdk.init()
	_log("INITIALIZATION %s / %s %s" % [sdk.backend_name, sdk.initialization_state, sdk.initialization_error])

func _log(message: String, display := "") -> void:
	print(message)
	if _output == null: return
	var line := display if not display.is_empty() else message
	_lines.append(line.left(512))
	while _lines.size() > 40: _lines.remove_at(0)
	_output.text = "\n".join(_lines)

func _on_event(event: String, data: Variant, sender: String) -> void:
	var display := ""
	if event == "couch-net" and data is Dictionary:
		display = "Received session packet: %s from %s" % [data.get("kind", "unknown"), sender]
	_log("EVENT %s %s FROM %s" % [event, data, sender], display)

func _send_event() -> void:
	var accepted: bool = sdk.lobby.try_send_event("fixture", {"counter": _revision})
	_log("ACCEPTED %s" % str(accepted), "Steam accepted message for sending" if accepted else "Message rejected")
	_revision += 1

func _start_session() -> void:
	if not sdk.lobby.is_available:
		_log("SESSION NOT STARTED: join a lobby first")
		return
	if session != null:
		_log("SESSION STATE: active=%s slot=%s" % [session.active, session.local_slot])
		return
	transport = CouchLobbyTransport.new(sdk.lobby)
	session = CouchSession.new(sdk.lobby, transport)
	session.hello_received.connect(_send_baseline)
	session.snapshot_received.connect(func(body): _log("BASELINE %s" % str(body)))
	session.session_started.connect(func(epoch, host, slot, _peer, _name):
		_log("SESSION STARTED: host=%s slot=%s epoch=%s" % [host, slot, epoch]))
	session.session_stopped.connect(func(reason): _log("SESSION STOPPED %s" % reason))
	session.rejected.connect(func(reason, sender): _log("SESSION REJECTED %s FROM %s" % [reason, sender]))
	_log("SESSION CREATED: waiting for peer handshake and baseline")
	session.evaluate(Time.get_ticks_msec())
func _send_baseline(_sender: String) -> void:
	_log("BASELINE ACCEPTED %s" % str(session.broadcast_snapshot({"fixture": true, "revision": _revision})))
func _process(_delta: float) -> void:
	if session != null:
		transport.poll(Time.get_ticks_msec())
		session.poll(Time.get_ticks_msec())
func _award() -> void:
	var before: CouchAchievementResult = await sdk.achievements.get_state("fixture_award")
	_log("ACHIEVEMENT READ %s %s" % [before.status, before.error])
	var result: CouchAchievementResult = await sdk.achievements.unlock("fixture_award")
	_log("ACHIEVEMENT UNLOCK %s ACK %s %s" % [result.status, result.provider_acknowledged, result.error])
func _exit_tree() -> void:
	if transport != null: transport.close()
