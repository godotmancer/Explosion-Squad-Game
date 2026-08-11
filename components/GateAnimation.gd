@tool
extends Node
class_name GateAnimation

## Swings the parent [Node3D] between a closed and an open angle around a pivot.
##
## The parent's transform as placed in the editor is the reference pose:
## [member closed_angle] and [member open_angle] are both measured from it, so a gate
## placed at any orientation works without re-authoring the angles. The angle is
## absolute rather than accumulated, so flipping [member open] mid-swing reverses
## smoothly instead of drifting.
##
## [b]GPU obstacles:[/b] a gate hogs must collide with has to live under
## [code]Obstacles/Movable[/code]. Shapes under [code]Obstacles/Static[/code] are baked
## into the obstacle buffer once at startup and will not follow the swing.

enum Axis { X, Y, Z }

## Emitted the frame the gate comes to rest fully open.
##
## Fires once per completed swing, so reversing before the gate arrives and then letting
## it finish emits once, at the end. Not emitted for the pose set up in [method _ready]
## (listeners are not connected yet), by [method reset], or while previewing in the
## editor.
signal fully_opened

## Emitted the frame the gate comes to rest fully closed. Same rules as
## [signal fully_opened].
signal fully_closed

@export var disabled: bool = false

## Target state. Flip it in the inspector (with [member preview_in_editor] on) or call
## [method toggle] / [method set_open] at runtime; the gate eases to the new state over
## [member duration].
@export var open: bool = false:
  set(value):
    open = value
    _target_progress = 1.0 if value else 0.0

@export var preview_in_editor: bool = false:
  set(value):
    preview_in_editor = value
    if not value and Engine.is_editor_hint() and _parent:
      _parent.transform = _closed_transform
      _progress = _target_progress
      _hinge_ready = false


@export_group("Hinge")
## Node the gate swings around. May be a child of the gate, a sibling, or anywhere else
## in the tree — only its position is used. Leave empty to swing about the gate's own
## origin.
@export var rotation_pivot: Node3D:
  set(value):
    rotation_pivot = value
    _hinge_ready = false
## Axis to swing around.
@export var rotation_axis: Axis = Axis.Y:
  set(value):
    rotation_axis = value
    _hinge_ready = false
## Interpret [member rotation_axis] in the gate's own placed orientation rather than in
## its parent's space.
@export var use_local_axis: bool = false:
  set(value):
    use_local_axis = value
    _hinge_ready = false


@export_group("Angles")
## Closed state, in degrees from the placed orientation.
@export_range(-360.0, 360.0, 0.1, "or_less", "or_greater") var closed_angle: float = 0.0
## Fully open state, in degrees from the placed orientation.
@export_range(-360.0, 360.0, 0.1, "or_less", "or_greater") var open_angle: float = 90.0


@export_group("Motion")
## Seconds for a full closed → open sweep. 0 snaps instantly.
@export var duration: float = 0.5
## Easing curve for the sweep. ELASTIC / BOUNCE / BACK overshoot, which reads well on a
## slammed gate.
@export var transition: Tween.TransitionType = Tween.TRANS_CUBIC
## Ease direction. EASE_IN_OUT is symmetric, so reversing mid-swing stays smooth;
## EASE_IN / EASE_OUT are tied to the opening direction and will kink on a reversal.
@export var ease_type: Tween.EaseType = Tween.EASE_IN_OUT


## The parent's local transform as placed in the editor — the pose both angles are
## measured from.
@export_storage var _closed_transform: Transform3D
## Whether [member _closed_transform] holds a real capture. False for a gate built in
## code, where an identity default would otherwise teleport the parent to its origin.
@export_storage var _closed_captured: bool = false


var _parent: Node3D
var _progress: float = 0.0        ## 0 = closed, 1 = fully open
var _target_progress: float = 0.0
var _hinge_ready: bool = false
var _pivot_local: Vector3         ## pivot in the space the parent's transform lives in


func _ready() -> void:
  _parent = get_parent() as Node3D
  if not _parent:
    push_warning("GateAnimation expects a Node3D parent — doing nothing.")
    return

  if Engine.is_editor_hint():
    _capture_closed()
    return

  if _closed_captured:
    # An editor preview may have left the gate mid-swing — rewind to the placed pose.
    _parent.transform = _closed_transform
  else:
    # Built in code, so there is no editor pose: wherever the gate is now is closed.
    _capture_closed()

  # Jump to the configured state so a gate saved as open is already open on frame one.
  _progress = _target_progress
  _apply_angle()


func _process(delta: float) -> void:
  if not _parent or disabled:
    return

  if Engine.is_editor_hint() and not preview_in_editor:
    # Not previewing: however the gate is posed in the editor IS the closed pose.
    _capture_closed()
    _progress = _target_progress
    return

  if not is_moving():
    return

  _progress = (
    move_toward(_progress, _target_progress, delta / duration) if duration > 0.0
    else _target_progress
  )
  _apply_angle()

  # Only reachable while moving, so arrival is detected exactly once per swing — the
  # early-out above blocks re-entry on later frames.
  if not is_moving():
    _announce_arrival()


## Sets the target state. Pass [param instant] to jump there without easing.
func set_open(value: bool, instant: bool = false) -> void:
  var was_moving := is_moving()
  var state_changed := value != open
  open = value
  if not instant:
    return

  _progress = _target_progress
  if _parent:
    _apply_angle()

  # A snap to the state the gate was already resting in is a no-op, not an arrival.
  if was_moving or state_changed:
    _announce_arrival()


func open_gate(instant: bool = false) -> void:
  set_open(true, instant)


func close_gate(instant: bool = false) -> void:
  set_open(false, instant)


func toggle(instant: bool = false) -> void:
  set_open(not open, instant)


## True while the gate is still travelling toward its target state.
func is_moving() -> bool:
  return not is_equal_approx(_progress, _target_progress)


## True once the gate has finished opening.
func is_fully_open() -> bool:
  return open and not is_moving()


## True once the gate has finished closing.
func is_fully_closed() -> bool:
  return not open and not is_moving()


## Sweep position: 0 = closed, 1 = fully open. Linear, before easing.
func progress() -> float:
  return _progress


## Current swing angle in degrees, measured from the placed orientation.
func current_angle() -> float:
  return lerpf(closed_angle, open_angle, _eased_progress())


## Re-captures the parent's current transform as the closed pose and settles the gate
## there. Call after moving or re-parenting the gate at runtime.
func reset() -> void:
  if not _parent:
    return
  _capture_closed()
  open = false
  _progress = 0.0


func _announce_arrival() -> void:
  if Engine.is_editor_hint():
    return # an editor preview should not run gameplay handlers
  if open:
    fully_opened.emit()
  else:
    fully_closed.emit()


func _capture_closed() -> void:
  _closed_transform = _parent.transform
  _closed_captured = true
  _hinge_ready = false


func _apply_angle() -> void:
  if not _hinge_ready:
    _init_hinge()

  var rot := Basis(_hinge_axis(), deg_to_rad(current_angle()))
  # Rotate the placed pose about the pivot. With no pivot the offset is zero, so this
  # degenerates to a spin in place.
  _parent.transform = Transform3D(
    rot * _closed_transform.basis,
    _pivot_local + rot * (_closed_transform.origin - _pivot_local)
  )


func _init_hinge() -> void:
  _hinge_ready = true
  _pivot_local = _closed_transform.origin
  if not rotation_pivot:
    return

  if _parent.is_ancestor_of(rotation_pivot):
    # The pivot rides along with the gate, so its live global position depends on the
    # current swing. Read it in the gate's own space (invariant) and place it with the
    # closed pose instead.
    _pivot_local = _closed_transform * _parent.to_local(rotation_pivot.global_position)
  else:
    var host := _parent.get_parent() as Node3D
    _pivot_local = (
      host.to_local(rotation_pivot.global_position) if host
      else rotation_pivot.global_position
    )


func _hinge_axis() -> Vector3:
  var v := Vector3.UP
  match rotation_axis:
    Axis.X:
      v = Vector3.RIGHT
    Axis.Y:
      v = Vector3.UP
    Axis.Z:
      v = Vector3.BACK
  return (_closed_transform.basis * v).normalized() if use_local_axis else v


func _eased_progress() -> float:
  # Easing the sweep position (rather than elapsed time) is what keeps a mid-swing
  # reversal continuous — the eased value is a pure function of _progress.
  return Tween.interpolate_value(0.0, 1.0, _progress, 1.0, transition, ease_type)
