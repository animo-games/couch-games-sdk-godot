## Channel map of a rigid body inside a CouchReplicatedWorld kind layout: which
## state index is position (x, y), velocity (vx, vy) and, optionally, rotation
## (rot) and angular velocity (w). Pure data; shared by CouchPDFollower and
## CouchOwnerTargets.
##
## CONTRACT. `map` keys "x", "y", "vx", "vy" are required; "rot" and "w" are optional
## but both or neither. is_valid(): every present value is an int >= 0, all present
## indices are distinct, and there are no other keys. An invalid map leaves every
## index -1. fits(kind_channels): is_valid, every index < size, the x/y/vx/vy (and w)
## channels are LERP and rot (when present) is ANGLE.
##
## GAME WIRING. Build one map per body kind, e.g.
## CouchBodyChannels.new({"x": 0, "y": 1, "rot": 2, "vx": 3, "vy": 4, "w": 5}), register
## it on the host with CouchOwnerTargets.set_channels(kind, map) and pass the same map to
## each CouchPDFollower. Channels the map does not name are ignored by the follower but
## still relayed in snapshots.
class_name CouchBodyChannels
extends RefCounted

const _REQUIRED := ["x", "y", "vx", "vy"]
const _OPTIONAL := ["rot", "w"]

var x: int = -1
var y: int = -1
var vx: int = -1
var vy: int = -1
## -1 when absent.
var rot: int = -1
## -1 when absent.
var w: int = -1


func _init(map: Dictionary) -> void:
	if not _map_is_valid(map):
		return
	x = map["x"]
	y = map["y"]
	vx = map["vx"]
	vy = map["vy"]
	if map.has("rot"):
		rot = map["rot"]
		w = map["w"]


## True when the map given to _init was valid.
func is_valid() -> bool:
	return x >= 0


## True when this map is valid and matches the world's channel list of a kind.
func fits(kind_channels: Array) -> bool:
	if not is_valid():
		return false
	for i in [x, y, vx, vy, w, rot]:
		if i >= kind_channels.size():
			return false
	for i in [x, y, vx, vy, w]:
		if i >= 0 and kind_channels[i] != CouchReplicatedWorld.LERP:
			return false
	if rot >= 0 and kind_channels[rot] != CouchReplicatedWorld.ANGLE:
		return false
	return true


func has_rotation() -> bool:
	return rot >= 0


static func _map_is_valid(map: Dictionary) -> bool:
	for key in map.keys():
		if not (key in _REQUIRED or key in _OPTIONAL):
			return false
	for key in _REQUIRED:
		if not map.has(key):
			return false
	if map.has("rot") != map.has("w"):
		return false
	var seen: Dictionary = {}
	for key in map.keys():
		var v: Variant = map[key]
		if typeof(v) != TYPE_INT or v < 0 or seen.has(v):
			return false
		seen[v] = true
	return true
