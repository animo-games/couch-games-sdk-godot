@tool
extends EditorPlugin

func _enter_tree():
  add_autoload_singleton("CouchGames", "./couch_games_sdk.gd")

func _exit_tree():
  remove_autoload_singleton("CouchGames")
