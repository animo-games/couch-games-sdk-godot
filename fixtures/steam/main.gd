## Minimal interactive live fixture. No fake results are reported as Steam proof.
extends Node
var sdk: Node
var session: CouchSession
var transport: Object
var _revision := 0
func _ready() -> void:
	var app_id := 0
	var api_name := ""
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--app-id="): app_id = int(arg.trim_prefix("--app-id="))
		if arg.begins_with("--achievement="): api_name = arg.trim_prefix("--achievement=")
	ProjectSettings.set_setting("couch_games/backend", "steam")
	ProjectSettings.set_setting("couch_games/steam/app_id", app_id)
	ProjectSettings.set_setting("couch_games/steam/game_id", "couch-sdk-steam-fixture")
	if not api_name.is_empty():
		ProjectSettings.set_setting("couch_games/achievements/catalog", {"fixture_award": api_name})
	sdk = load("res://addons/couch-games-sdk/core/couch_games_sdk.gd").new()
	add_child(sdk)
	var panel := CouchLobbyPanel.new()
	panel.sdk = sdk
	panel.title = "Steam SDK acceptance fixture"
	add_child(panel)
	panel.start_game_requested.connect(_start_session)
	sdk.lobby.players_changed.connect(func(_players):
		if session != null: session.evaluate(Time.get_ticks_msec()))
	sdk.lobby.event_received.connect(func(event, data, sender): print("EVENT ", event, " ", data, " FROM ", sender))
	var ping := Button.new()
	ping.text = "Send reliable fixture event"
	ping.pressed.connect(func(): print("ACCEPTED ", sdk.lobby.try_send_event("fixture", {"counter": _revision})); _revision += 1)
	panel.add_child(ping)
	var award := Button.new()
	award.text = "Read / award configured local achievement"
	award.pressed.connect(_award)
	panel.add_child(award)
	var baseline := Button.new()
	baseline.text = "Start local session / request baseline"
	baseline.pressed.connect(_start_session)
	panel.add_child(baseline)
func _start_session() -> void:
	if session != null: return
	transport = CouchLobbyTransport.new(sdk.lobby)
	session = CouchSession.new(sdk.lobby, transport)
	session.hello_received.connect(_send_baseline)
	session.snapshot_received.connect(func(body): print("BASELINE ", body))
	session.session_stopped.connect(func(reason): print("SESSION STOPPED ", reason))
	session.evaluate(Time.get_ticks_msec())
func _send_baseline(_sender: String) -> void:
	print("BASELINE ACCEPTED ", session.broadcast_snapshot({"fixture": true, "revision": _revision}))
func _process(_delta: float) -> void:
	if session != null:
		transport.poll(Time.get_ticks_msec())
		session.poll(Time.get_ticks_msec())
func _award() -> void:
	var before: CouchAchievementResult = await sdk.achievements.get_state("fixture_award")
	print("ACHIEVEMENT READ ", before.status, " ", before.error)
	var result: CouchAchievementResult = await sdk.achievements.unlock("fixture_award")
	print("ACHIEVEMENT UNLOCK ", result.status, " ACK ", result.provider_acknowledged, " ", result.error)
func _exit_tree() -> void:
	if transport != null: transport.close()
