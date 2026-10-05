## Real loopback relay contract smoke test (requires native socket permission).
extends SceneTree
var failures := 0
func _initialize() -> void:
	_run.call_deferred()
func check(value: bool, message: String) -> void:
	if not value:
		failures += 1
		printerr("FAIL: " + message)
func _run() -> void:
	ProjectSettings.set_setting("couch_games/local/port", 0)
	var host := CouchGamesLocalBackend.new()
	var host_lobby := CouchLobby.new()
	root.add_child(host)
	root.add_child(host_lobby)
	host_lobby.setup(host)
	await host.initialize()
	var server: TCPServer = host.get("_server")
	if server == null:
		printerr("FAIL: real local relay could not listen")
		quit(1)
		return
	ProjectSettings.set_setting("couch_games/local/port", server.get_local_port())
	var guest := CouchGamesLocalBackend.new()
	var guest_lobby := CouchLobby.new()
	root.add_child(guest)
	root.add_child(guest_lobby)
	guest_lobby.setup(guest)
	await guest.initialize()
	var deadline := Time.get_ticks_msec() + 2000
	while host_lobby.get_players().size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(host_lobby.is_host() and not guest_lobby.is_host(), "relay assigns host and guest")
	check(host_lobby.get_players().size() == 2 and guest_lobby.get_players().size() == 2, "relay publishes shared roster")
	var received := []
	guest_lobby.event_received.connect(func(event, data, sender): received.append([event, data, sender]))
	var echoed := []
	host_lobby.event_received.connect(func(event, _data, _sender): echoed.append(event))
	check(host_lobby.try_send_event("broadcast", {"number": 9}), "local relay accepts broadcast")
	deadline = Time.get_ticks_msec() + 2000
	while received.is_empty() and Time.get_ticks_msec() < deadline:
		await process_frame
	check(received.size() == 1 and echoed.is_empty(), "relay broadcasts without self echo")
	if not received.is_empty():
		check(typeof(received[0][1].number) == TYPE_FLOAT and received[0][2] == host_lobby.get_me().user_id, "relay JSON and authenticated sender preserved")
	host_lobby.try_send_event("excluded", null, {"user_id": guest_lobby.get_me().user_id, "role": "host"})
	host_lobby.try_send_event("targeted", null, {"user_id": guest_lobby.get_me().user_id, "role": "guest"})
	deadline = Time.get_ticks_msec() + 2000
	while received.size() < 2 and Time.get_ticks_msec() < deadline:
		await process_frame
	check(received.size() == 2 and received[1][0] == "targeted", "relay intersecting targets preserved")
	guest_lobby.free()
	guest.free()
	host_lobby.free()
	host.free()
	print("LOCAL_LOBBY_SMOKE: %s" % ("PASS" if failures == 0 else "FAIL"))
	quit(1 if failures else 0)
