extends CouchGamesSaveWriteResult
class_name CouchGamesFlushResult

# What flush_saves() answers with: a save write, plus how many it sent.
# Branch on `persisted`, as after save_game().

## How many saves it sent (0 when none were waiting).
var flushed: int = 0


static func from_dict(response: Dictionary) -> CouchGamesFlushResult:
	var res := CouchGamesFlushResult.new()
	res._read(response)
	return res


func _read(response: Dictionary) -> void:
	super(response)
	flushed = _as_int(response.get("flushed"), 0)
