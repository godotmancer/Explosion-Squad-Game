@tool
extends Node
class_name Animator

enum Mode { NONE, SINE, CIRCULAR, SPRING, BOUNCE, FIGURE_EIGHT, LISSAJOUS, ROTATION }
enum Axis { X, Y, Z }

@export var disabled : bool = false
@export var mode: Mode = Mode.NONE:
  set(value):
    mode = value
    _time = 0.0
    _rotation_initialized = false

@export_group("General")
@export var speed: float = 1.0
@export var amplitude: float = 1.0
@export var axis: Axis = Axis.Y
@export var use_local_axis: bool = false
@export var preview_in_editor: bool = false:
  set(value):
    preview_in_editor = value
    if not value and Engine.is_editor_hint() and _parent:
      _parent.global_transform = _editor_transform
      _parent.scale = Vector3.ONE
      _time = 0.0
      _spring_velocity = 0.0
      _spring_offset = 0.0
      _rotation_initialized = false


@export_group("Sine")
@export var sine_frequency: float = 1.0

@export_group("Circular")
@export var circular_radius: float = 2.0
@export var circular_plane: Axis = Axis.Y

@export_group("Spring")
@export var spring_stiffness: float = 5.0
@export var spring_damping: float = 0.3

@export_group("Bounce")
@export var bounce_height: float = 2.0
@export var bounce_squash: float = 0.3

@export_group("Figure Eight")
@export var eight_width: float = 2.0
@export var eight_height: float = 1.0

@export_group("Rotation")
@export var rotation_axis: Axis = Axis.Y
@export var rotation_pivot: Node3D

@export_group("Lissajous")
@export var lissajous_a: float = 3.0
@export var lissajous_b: float = 2.0
@export var lissajous_delta: float = 1.57

## Store the editor position/transform so runtime always starts from the right place
@export_storage var _editor_origin: Vector3
@export_storage var _editor_transform: Transform3D

var _time: float = 0.0
var _origin: Vector3
var _parent: Node3D
var _spring_velocity: float = 0.0
var _spring_offset: float = 0.0
var _rotation_pivot_offset: Vector3
var _rotation_initial_basis: Basis
var _rotation_initial_position: Vector3
var _rotation_initialized: bool = false


func _ready() -> void:
  _parent = get_parent() as Node3D
  if not _parent:
    return

  if Engine.is_editor_hint():
    _editor_origin = _parent.global_position
    _editor_transform = _parent.global_transform
    _origin = _editor_origin
  else:
    # At runtime, restore to where it was placed in the editor
    _parent.global_transform = _editor_transform
    _origin = _editor_origin



func _process(delta: float) -> void:
  if not _parent or disabled:
    return

  if Engine.is_editor_hint():
    if not preview_in_editor:
      # Keep tracking editor position/transform when not previewing
      _editor_origin = _parent.global_position
      _editor_transform = _parent.global_transform
      _origin = _editor_origin
      _time = 0.0
      return
    # Update editor origin to where the node was before animation started
    _origin = _editor_origin

  _time += delta * speed

  match mode:
    Mode.NONE:
      _parent.global_position = _origin
    Mode.SINE:
      _apply_sine()
    Mode.CIRCULAR:
      _apply_circular()
    Mode.SPRING:
      _apply_spring(delta)
    Mode.BOUNCE:
      _apply_bounce()
    Mode.FIGURE_EIGHT:
      _apply_figure_eight()
    Mode.LISSAJOUS:
      _apply_lissajous()
    Mode.ROTATION:
      _apply_rotation()


func _apply_sine() -> void:
  var offset = sin(_time * sine_frequency * TAU) * amplitude
  _parent.global_position = _origin + _axis_vector() * offset


func _apply_circular() -> void:
  var a: Vector3
  var b: Vector3

  match circular_plane:
    Axis.Y:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.BACK)
    Axis.X:
      a = _to_world(Vector3.UP)
      b = _to_world(Vector3.BACK)
    Axis.Z:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.UP)

  var offset = a * cos(_time * TAU) * circular_radius + b * sin(_time * TAU) * circular_radius
  _parent.global_position = _origin + offset


func _apply_spring(delta: float) -> void:
  var target_offset = sin(_time * TAU) * amplitude
  var force = -spring_stiffness * (_spring_offset - target_offset)
  var damping_force = -spring_damping * _spring_velocity
  _spring_velocity += (force + damping_force) * delta
  _spring_offset += _spring_velocity * delta
  _parent.global_position = _origin + _axis_vector() * _spring_offset


func _apply_bounce() -> void:
  var bounce = abs(sin(_time * TAU)) * bounce_height
  var stretch_factor = 1.0 + bounce_squash * (1.0 - abs(sin(_time * TAU)))

  _parent.global_position = _origin + _axis_vector() * bounce

  match axis:
    Axis.Y:
      _parent.scale = Vector3(1.0 / sqrt(stretch_factor), stretch_factor, 1.0 / sqrt(stretch_factor))
    Axis.X:
      _parent.scale = Vector3(stretch_factor, 1.0 / sqrt(stretch_factor), 1.0 / sqrt(stretch_factor))
    Axis.Z:
      _parent.scale = Vector3(1.0 / sqrt(stretch_factor), 1.0 / sqrt(stretch_factor), stretch_factor)


func _apply_figure_eight() -> void:
  var a: Vector3
  var b: Vector3

  match axis:
    Axis.Y:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.FORWARD)
    Axis.X:
      a = _to_world(Vector3.UP)
      b = _to_world(Vector3.FORWARD)
    Axis.Z:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.UP)

  var offset = a * sin(_time * TAU) * eight_width + b * sin(_time * TAU * 2.0) * eight_height
  _parent.global_position = _origin + offset


func _apply_lissajous() -> void:
  var a: Vector3
  var b: Vector3

  match axis:
    Axis.Y:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.FORWARD)
    Axis.X:
      a = _to_world(Vector3.UP)
      b = _to_world(Vector3.FORWARD)
    Axis.Z:
      a = _to_world(Vector3.RIGHT)
      b = _to_world(Vector3.UP)

  var x = sin(lissajous_a * _time * TAU + lissajous_delta) * amplitude
  var y = sin(lissajous_b * _time * TAU) * amplitude
  _parent.global_position = _origin + a * x + b * y


func _apply_rotation() -> void:
  if not _rotation_initialized:
    _rotation_initial_basis = _parent.transform.basis
    _rotation_initial_position = _parent.position
    if rotation_pivot:
      # Pivot position in parent's local space
      _rotation_pivot_offset = _rotation_initial_position + _rotation_initial_basis * rotation_pivot.position
    _rotation_initialized = true

  var angle = _time * TAU

  var rot_axis: Vector3
  match rotation_axis:
    Axis.X:
      rot_axis = Vector3.RIGHT
    Axis.Y:
      rot_axis = Vector3.UP
    Axis.Z:
      rot_axis = Vector3.BACK

  var rot = Basis(rot_axis, angle)

  if rotation_pivot:
    var offset = _rotation_initial_position - _rotation_pivot_offset
    _parent.transform = Transform3D(
      rot * _rotation_initial_basis,
      _rotation_pivot_offset + rot * offset
    )
  else:
    _parent.transform.basis = rot * _rotation_initial_basis


func _to_world(v: Vector3) -> Vector3:
  return _parent.global_transform.basis * v if use_local_axis else v


func _axis_vector() -> Vector3:
  match axis:
    Axis.X:
      return _to_world(Vector3.RIGHT)
    Axis.Y:
      return _to_world(Vector3.UP)
    Axis.Z:
      return _to_world(Vector3.BACK)
  return _to_world(Vector3.UP)


func reset_origin() -> void:
  if _parent:
    _origin = _parent.global_position
    _editor_origin = _origin
    _time = 0.0
    _spring_velocity = 0.0
    _spring_offset = 0.0
