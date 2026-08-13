## Conformance fixture for the shared net-id spec. ONE spec, TWO implementations:
## CouchStarTransport.derive_net_id here, and RollbackTransport.derive_net_id in
## the rollback addon (github.com/animo-games/rollback-godot,
## transport/rollback_transport.gd). Neither repo can depend on the other, so the
## function is duplicated and THIS FILE is what proves the copies agree.
##
## It is written to be liftable: it names no class from either side, holds only
## data, and can be dropped into duo's suite unchanged.
##
## Each entry is [peer_id: String, expected_net_id: int]. The expectations are the
## spec, not a recording of current behaviour: FNV-1a 32-bit over the UTF-8 BYTES
## (offset basis 2166136261, prime 16777619, masked to 32 bits after each
## multiply), then (h & 0x3FFFFFFF) + 2.
##
## `"héllo"` and `"こんにちは"` are load-bearing and must never be removed: an
## implementation that folds over CODE POINTS instead of UTF-8 bytes agrees on
## every ASCII vector above and diverges on exactly these two.
##
## COLLIDING_PAIR is a real fold collision -- the two full 32-bit hashes differ
## (3062872253 vs 915388605) and only collapse under the 30-bit mask. It exists so
## the collision branch, which must be a LOUD failure and never silent
## mis-addressing, has a test that can actually reach it.
class_name CouchNetIdVectors
extends RefCounted

const NET_ID_MIN := 2
const NET_ID_MAX := 1073741825   # 2^30 + 1

const VECTORS := [
	["", 18652615],
	["a", 604776750],
	["abc", 440920333],
	["0", 890022065],
	["1", 873244446],
	["host", 805217649],
	["g1", 270542999],
	["guest", 1046273013],
	["user-1", 894663030],
	["user-00000000-0000-0000-0000-000000000001", 256275912],
	["héllo", 178554178],
	["こんにちは", 486186191],
	["AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA", 155285895],
]

## Two distinct peer ids that fold to the SAME net id.
const COLLIDING_PAIR := ["u0068724", "u0498200"]
const COLLIDING_NET_ID := 915388607
