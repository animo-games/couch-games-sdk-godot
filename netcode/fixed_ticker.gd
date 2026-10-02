## The host's fixed simulation step, drift-free.
##
## CONTRACT. Tick k is due at start_ms + ((k - first_tick) * 1000) / tick_hz
## (integer division), always computed from k, never by accumulating a rounded
## step. So with start(S, F) a call advance(T) leaves
## next_tick == F + (((T - S + 1) * tick_hz - 1) / 1000) + 1 for T >= S: tick F is
## due AT start_ms. advance() returns how many ticks became due since the last
## call (>= 0), never skips one, and a `now_ms` earlier than the last call
## returns 0. next_tick is the next tick to simulate: an input stamped for a tick
## < next_tick is late.
## advance() before start() returns 0. Integer-only.
class_name CouchFixedTicker
extends RefCounted

## The next tick to simulate.
var next_tick: int = 0
var started: bool = false

var _tick_hz: int
var _start_ms: int = 0
var _first_tick: int = 0


func _init(tick_hz: int) -> void:
	_tick_hz = tick_hz


## Begin the timeline: tick `first_tick` is due AT `now_ms`.
func start(now_ms: int, first_tick: int = 0) -> void:
	_start_ms = now_ms
	_first_tick = first_tick
	next_tick = first_tick
	started = true


## Number of ticks that became due since the previous call.
func advance(now_ms: int) -> int:
	if not started or now_ms < _start_ms:
		return 0
	# Tick j (counted from first_tick) is due when j * 1000 / hz <= elapsed
	# (integer division), i.e. j <= ((elapsed + 1) * hz - 1) / 1000.
	var elapsed: int = now_ms - _start_ms
	var last_due: int = _first_tick + ((elapsed + 1) * _tick_hz - 1) / 1000
	var due: int = last_due + 1 - next_tick
	if due <= 0:
		return 0
	next_tick += due
	return due
