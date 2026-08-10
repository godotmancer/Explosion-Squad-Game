@tool
extends Node
class_name LookAtTracker

## Smoothly rotates the parent [Node3D] toward a target.
##
## Axis weights (0–1) are per-axis soft constraints:
##   weight_y = 0.0  → yaw frozen (e.g. a head that only tilts up/down)
##   weight_x = 0.0  → pitch frozen (e.g. a turret barrel locked horizontal)
##   weight_y = 0.5  → tracks at half angular response (lazy/floaty feel)
##
## ELASTIC, BOUNCE, and SPRING transition types activate spring-physics mode,
## producing overshoot and oscillation that settles on the target.
## All other Tween transition + ease types apply easing to the lerp alpha.

enum ForwardAxis {
  NEGATIVE_Z,  ## Default Godot forward (-Z → target)
  POSITIVE_Z,
  POSITIVE_X,
  NEGATIVE_X,
  POSITIVE_Y,  ## Top faces the target (e.g. a flower toward the sun)
  NEGATIVE_Y,
}

@export var disabled: bool = false

## Node to track.
@export var target: Node3D

@export var preview_in_editor: bool = false:
  set(value):
    preview_in_editor = value
    if not value and Engine.is_editor_hint() and _parent:
      _parent.global_transform = _editor_transform
      _angular_vel = Vector3.ZERO


@export_group("Tracking Speed")
## Base angular catch-up rate. Higher = snappier.
@export var speed: float = 5.0
## Easing curve for the catch-up motion.
## ELASTIC / BOUNCE / SPRING activate spring-physics mode (ignore ease_type).
@export var transition: Tween.TransitionType = Tween.TRANS_CUBIC
## Ease direction (ignored in spring-physics mode).
@export var ease_type: Tween.EaseType = Tween.EASE_OUT
## Clamp rotation speed to this many degrees/second. 0 = no limit.
## Useful for turrets or cameras with mechanical rotation constraints.
@export var max_degrees_per_second: float = 0.0


@export_group("Axis Weights")
## Per-axis tracking strength. 0 = frozen, 1 = full tracking.
@export_range(0.0, 1.0) var weight_x: float = 1.0
@export_range(0.0, 1.0) var weight_y: float = 1.0
@export_range(0.0, 1.0) var weight_z: float = 1.0


@export_group("Aiming")
## Which local axis faces the target.
@export var forward_axis: ForwardAxis = ForwardAxis.NEGATIVE_Z
## World-space up reference for the look rotation.
@export var up_vector: Vector3 = Vector3.UP
## World-space offset added to the target position before tracking.
## Use this to aim above/ahead of a target (e.g. lead a moving character's head).
@export var look_offset: Vector3 = Vector3.ZERO


@export_group("Prediction")
## Lead the target by projecting its estimated velocity forward.
## 0 = track current position. ~0.2 is good for aiming at brisk walkers.
@export_range(0.0, 2.0) var predict_seconds: float = 0.0


@export_group("Dead Zone")
## Tracking is suppressed while the error angle is below this value.
## Prevents micro-jitter when the target is nearly aligned.
@export_range(0.0, 45.0) var dead_zone_degrees: float = 0.0


@export_group("Distance Speed Scaling")
## Scale catch-up speed by distance. Farther = faster, closer = slower.
## Gives a natural feel: a distant target snaps into view quickly,
## a nearby target gets a gentle, gentle nudge.
@export var use_distance_scaling: bool = false
## Distance at which speed equals [member speed] exactly.
@export var reference_distance: float = 10.0


@export_group("Tilt / Bank")
## Roll into yaw turns for an organic, weighted feel (great for cameras and animals).
@export var tilt_enabled: bool = false
## Maximum tilt roll in degrees.
@export_range(0.0, 45.0) var tilt_strength: float = 8.0
## How quickly tilt decays back to zero after the turn ends.
@export var tilt_recovery_speed: float = 4.0


@export_storage var _editor_transform: Transform3D

# ---- Runtime state ----
var _parent: Node3D
var _current_euler: Vector3 = Vector3.ZERO
var _prev_raw_target: Vector3 = Vector3.ZERO
var _target_vel: Vector3 = Vector3.ZERO    # smoothed for prediction
var _angular_vel: Vector3 = Vector3.ZERO   # spring-mode angular velocity
var _tilt_angle: float = 0.0


func _ready() -> void:
  _parent = get_parent() as Node3D
  if not _parent:
    return
  if Engine.is_editor_hint():
    _editor_transform = _parent.global_transform
  _current_euler = _parent.global_transform.basis.get_euler()
  if target:
    _prev_raw_target = target.global_position + look_offset


func _process(delta: float) -> void:
  if not _parent or disabled:
    return

  if Engine.is_editor_hint():
    if not preview_in_editor:
      _editor_transform = _parent.global_transform
      _current_euler = _parent.global_transform.basis.get_euler()
      _angular_vel = Vector3.ZERO
      return

  if not target:
    return

  # ---- Target position + optional prediction ----
  var raw_target := target.global_position + look_offset
  var tracked_pos := raw_target
  if predict_seconds > 0.0 and delta > 0.0:
    var raw_vel := (raw_target - _prev_raw_target) / delta
    _target_vel = lerp(_target_vel, raw_vel, clampf(delta * 8.0, 0.0, 1.0))
    tracked_pos += _target_vel * predict_seconds
  _prev_raw_target = raw_target

  # ---- Desired look rotation ----
  var to_dir := (tracked_pos - _parent.global_position).normalized()
  if to_dir.length_squared() < 0.0001:
    return
  var desired_euler := _look_euler(to_dir)

  # ---- Dead zone: skip if already close enough ----
  if dead_zone_degrees > 0.0:
    var diff_mag := Vector3(
      angle_difference(_current_euler.x, desired_euler.x),
      angle_difference(_current_euler.y, desired_euler.y),
      angle_difference(_current_euler.z, desired_euler.z)
    ).length()
    if rad_to_deg(diff_mag) < dead_zone_degrees:
      return

  # ---- Tracking step ----
  var prev_yaw := _current_euler.y
  var use_spring := transition == Tween.TRANS_ELASTIC \
    or transition == Tween.TRANS_BOUNCE \
    or transition == Tween.TRANS_SPRING
  if use_spring:
    _step_spring(delta, desired_euler)
  else:
    _step_lerp(delta, desired_euler)

  # ---- Tilt / bank: roll proportional to yaw change rate ----
  if tilt_enabled:
    var yaw_rate := angle_difference(prev_yaw, _current_euler.y) / maxf(delta, 0.0001)
    var target_tilt = clamp(
      -yaw_rate / maxf(speed * PI, 0.001) * deg_to_rad(tilt_strength),
      -deg_to_rad(tilt_strength),
      deg_to_rad(tilt_strength)
    )
    _tilt_angle = lerp(_tilt_angle, target_tilt, clampf(delta * tilt_recovery_speed, 0.0, 1.0))

  # ---- Write to parent ----
  var final_quat := Quaternion.from_euler(_current_euler)
  if tilt_enabled and absf(_tilt_angle) > 0.0001:
    # Roll applied in local space around the forward axis
    final_quat = final_quat * Quaternion(Vector3.FORWARD, _tilt_angle)
  _parent.global_transform = Transform3D(Basis(final_quat), _parent.global_position)


# ---- Standard lerp tracking (all non-spring transitions) ----
func _step_lerp(delta: float, desired_euler: Vector3) -> void:
  var raw_t := clampf(delta * speed, 0.0, 1.0)
  if use_distance_scaling and reference_distance > 0.0:
    var d := _parent.global_position.distance_to(target.global_position + look_offset)
    raw_t = clampf(raw_t * (d / reference_distance), 0.0, 1.0)
  var t := _apply_ease(raw_t)

  var new_euler := Vector3(
    lerp_angle(_current_euler.x, desired_euler.x, weight_x * t),
    lerp_angle(_current_euler.y, desired_euler.y, weight_y * t),
    lerp_angle(_current_euler.z, desired_euler.z, weight_z * t)
  )

  if max_degrees_per_second > 0.0:
    var max_rad := deg_to_rad(max_degrees_per_second) * delta
    var d_euler := new_euler - _current_euler
    if d_euler.length() > max_rad:
      new_euler = _current_euler + d_euler.normalized() * max_rad

  _current_euler = new_euler


# ---- Spring-physics tracking (ELASTIC / BOUNCE / SPRING) ----
func _step_spring(delta: float, desired_euler: Vector3) -> void:
  var stiffness := speed * speed
  var damping: float
  match transition:
    Tween.TRANS_BOUNCE:  damping = speed * 3.0   # heavy → decaying bounces
    Tween.TRANS_SPRING:  damping = speed * 2.0   # medium → one soft overshoot
    _:                   damping = speed * 0.6   # ELASTIC → free oscillation

  var error := Vector3(
    angle_difference(_current_euler.x, desired_euler.x) * weight_x,
    angle_difference(_current_euler.y, desired_euler.y) * weight_y,
    angle_difference(_current_euler.z, desired_euler.z) * weight_z
  )
  _angular_vel += (stiffness * error - damping * _angular_vel) * delta

  if max_degrees_per_second > 0.0:
    var max_rad_s := deg_to_rad(max_degrees_per_second)
    if _angular_vel.length() > max_rad_s:
      _angular_vel = _angular_vel.normalized() * max_rad_s

  _current_euler += _angular_vel * delta


# ---- Build Euler angles for a given look direction ----
func _look_euler(dir: Vector3) -> Vector3:
  var safe_up := up_vector
  if absf(dir.dot(safe_up)) > 0.999:
    safe_up = Vector3.RIGHT if absf(dir.dot(Vector3.RIGHT)) < 0.999 else Vector3.FORWARD
  var base := Basis.looking_at(dir, safe_up)
  # Remap so the chosen local axis points toward the target
  match forward_axis:
    ForwardAxis.POSITIVE_Z:  base = base * Basis(Vector3.UP, PI)
    ForwardAxis.POSITIVE_X:  base = base * Basis(Vector3.UP, -PI * 0.5)
    ForwardAxis.NEGATIVE_X:  base = base * Basis(Vector3.UP,  PI * 0.5)
    ForwardAxis.POSITIVE_Y:  base = base * Basis(Vector3.RIGHT,  PI * 0.5)
    ForwardAxis.NEGATIVE_Y:  base = base * Basis(Vector3.RIGHT, -PI * 0.5)
  return base.get_euler()


# ---- Apply easing to lerp alpha ----
func _apply_ease(t: float) -> float:
  match ease_type:
    Tween.EASE_IN:
      return _trans_in(t)
    Tween.EASE_OUT:
      return 1.0 - _trans_in(1.0 - t)
    Tween.EASE_IN_OUT:
      return 0.5 * _trans_in(t * 2.0) if t < 0.5 \
        else 1.0 - 0.5 * _trans_in(2.0 - t * 2.0)
    Tween.EASE_OUT_IN:
      return 0.5 * (1.0 - _trans_in(1.0 - t * 2.0)) if t < 0.5 \
        else 0.5 + 0.5 * _trans_in(t * 2.0 - 1.0)
  return t


# ---- Ease-in curve for each Tween.TransitionType ----
func _trans_in(t: float) -> float:
  match transition:
    Tween.TRANS_QUAD:   return t * t
    Tween.TRANS_CUBIC:  return t * t * t
    Tween.TRANS_QUART:  return t * t * t * t
    Tween.TRANS_QUINT:  return t * t * t * t * t
    Tween.TRANS_SINE:   return 1.0 - cos(t * PI * 0.5)
    Tween.TRANS_EXPO:   return 0.0 if t == 0.0 else pow(2.0, 10.0 * t - 10.0)
    Tween.TRANS_CIRC:   return 1.0 - sqrt(maxf(0.0, 1.0 - t * t))
    Tween.TRANS_BACK:   return t * t * (2.70158 * t - 1.70158)  # slight overshoot on ease-out
  return t  # TRANS_LINEAR and anything unhandled


## Re-sync current state from the parent's actual transform and clear velocities.
## Call this after teleporting the parent or changing the target abruptly.
func reset() -> void:
  if _parent:
    _current_euler = _parent.global_transform.basis.get_euler()
  _angular_vel = Vector3.ZERO
  _tilt_angle = 0.0
  _target_vel = Vector3.ZERO
  if target:
    _prev_raw_target = target.global_position + look_offset
