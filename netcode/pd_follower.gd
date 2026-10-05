## HOST-side critically damped spring that drives a stand-in body toward an owner's
## reported state (see CouchOwnerTargets). Pure maths: no Nodes, no physics server.
##
## CONTRACT. step(current, target) returns {"snap": bool, "accel": Vector2, "alpha": float}.
## An empty target gives zeros (normal before the first report, and in REPORT_ONLY).
## A size mismatch, a channel index out of range or a non-finite used value also gives
## zeros and bumps bad_input_count. Otherwise, with position error ep and shortest-arc
## rotation error er: if |ep| > policy.snap_distance or |er| > policy.snap_angle the
## result is a snap (accel and alpha zero, plus "state" = copy of target, "pos", "vel",
## "rot", "w" for setting the body directly); else
##   accel = w^2 * ep + 2w * (target_v - current_v)       alpha likewise with rot_omega
## where omega() = min(SETTLE_K / settle_s, MAX_W_DT / physics_dt) (settle_ms >= 1).
## The policy is read every step, so edits apply on the next one.
##
## GAME WIRING. Per physics step and stand-in:
##   r = follower.step(state_of(body), targets.target_for(peer, now_ms))
## then on r.snap set the body's transform and velocities from r.pos / r.vel / r.rot /
## r.w; otherwise apply force_from(r, mass, inertia) in RigidBody2D._integrate_forces, or
## velocity_after(r, vel, w, dt) for a kinematic / CharacterBody2D. `current` MUST be the
## FULL kind state, the same size as the target, extra relayed channels included (their
## values are simply ignored by the spring). Finally world.set_entity(eid, kind,
## state_of(body)) before pack().
class_name CouchPDFollower
extends RefCounted

## Inputs refused by step() (size mismatch, bad index, non-finite used value).
var bad_input_count: int = 0

var _channels: CouchBodyChannels
var _policy: CouchPDFollowerPolicy
var _dt: float


func _init(channels: CouchBodyChannels, policy: CouchPDFollowerPolicy, physics_dt: float) -> void:
	_channels = channels
	_policy = policy
	_dt = physics_dt if physics_dt > 0.0 else 1.0 / 60.0


## min(SETTLE_K / (settle_ms / 1000), MAX_W_DT / physics_dt).
func omega() -> float:
	return _omega_for(_policy.settle_ms)


## Same with rot_settle_ms.
func rot_omega() -> float:
	return _omega_for(_policy.rot_settle_ms)


## SETTLE_K / omega() * 1000.
func effective_settle_ms() -> float:
	return CouchPDFollowerPolicy.SETTLE_K / omega() * 1000.0


## Same for rotation.
func effective_rot_settle_ms() -> float:
	return CouchPDFollowerPolicy.SETTLE_K / rot_omega() * 1000.0


func step(current: PackedFloat32Array, target: PackedFloat32Array) -> Dictionary:
	var zero := {"snap": false, "accel": Vector2.ZERO, "alpha": 0.0}
	if target.is_empty():
		return zero
	if current.size() != target.size() or not _usable(current) or not _usable(target):
		bad_input_count += 1
		return zero
	var c := _channels
	var ep := Vector2(target[c.x] - current[c.x], target[c.y] - current[c.y])
	var er: float = 0.0
	if c.has_rotation():
		er = wrapf(target[c.rot] - current[c.rot], -PI, PI)
	if ep.length() > _policy.snap_distance or absf(er) > _policy.snap_angle:
		return {
			"snap": true,
			"accel": Vector2.ZERO,
			"alpha": 0.0,
			"state": target.duplicate(),
			"pos": Vector2(target[c.x], target[c.y]),
			"vel": Vector2(target[c.vx], target[c.vy]),
			"rot": target[c.rot] if c.has_rotation() else 0.0,
			"w": target[c.w] if c.has_rotation() else 0.0,
		}
	var w := omega()
	var dv := Vector2(target[c.vx], target[c.vy]) - Vector2(current[c.vx], current[c.vy])
	var accel: Vector2 = w * w * ep + 2.0 * w * dv
	var alpha: float = 0.0
	if c.has_rotation():
		var wr := rot_omega()
		alpha = wr * wr * er + 2.0 * wr * (target[c.w] - current[c.w])
	return {"snap": false, "accel": accel, "alpha": alpha}


## {"force": accel * mass, "torque": alpha * inertia}; zeros on a snap.
static func force_from(result: Dictionary, mass: float, inertia: float) -> Dictionary:
	if result["snap"]:
		return {"force": Vector2.ZERO, "torque": 0.0}
	return {"force": (result["accel"] as Vector2) * mass, "torque": float(result["alpha"]) * inertia}


## {"linear": vel + accel * dt, "angular": ang_vel + alpha * dt}; on a snap the result's vel / w.
static func velocity_after(result: Dictionary, vel: Vector2, ang_vel: float, dt: float) -> Dictionary:
	if result["snap"]:
		return {"linear": result["vel"], "angular": result["w"]}
	return {
		"linear": vel + (result["accel"] as Vector2) * dt,
		"angular": ang_vel + float(result["alpha"]) * dt,
	}


func _omega_for(settle_ms: float) -> float:
	var settle_s: float = maxf(settle_ms, 1.0) / 1000.0
	return minf(CouchPDFollowerPolicy.SETTLE_K / settle_s, CouchPDFollowerPolicy.MAX_W_DT / _dt)


## True when every channel the spring reads is in range and finite in `state`.
func _usable(state: PackedFloat32Array) -> bool:
	var c := _channels
	var used: Array = [c.x, c.y, c.vx, c.vy]
	if c.has_rotation():
		used.append(c.rot)
		used.append(c.w)
	for i in used:
		if i < 0 or i >= state.size() or not is_finite(state[i]):
			return false
	return true
