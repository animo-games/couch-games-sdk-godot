## Tuning of CouchPDFollower: a critically damped spring chosen by settle time.
## Data only. Values are read at every step, so an edit takes effect next step.
class_name CouchPDFollowerPolicy
extends RefCounted

## Critically damped: e(t) = e0 (1 + wt) e^-wt is 5% at wt = 4.74.
const SETTLE_K := 4.74
## Stability clamp for a symplectic-Euler body (no overshoot up to about 0.7).
const MAX_W_DT := 0.5

## Time to close ~95% of a position error, milliseconds.
var settle_ms: float = 150.0
## Same for rotation.
var rot_settle_ms: float = 100.0
## World units; snap iff the position error is strictly greater than this.
var snap_distance: float = 256.0
## Radians; snap iff the absolute rotation error is strictly greater (PI = never).
var snap_angle: float = PI
