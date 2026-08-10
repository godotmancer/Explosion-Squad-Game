@tool
extends Camera3D
class_name RotatableCamera3D

@export var calculate: bool = true:
  set(value):
    calculate = value
    if calculate:
      target = _calculate_plane_intersection()

## The point the camera orbits around
@export var target: Vector3 = Vector3.ZERO
## Distance from the target
@export var distance: float = 10.0
## Horizontal rotation speed
@export var sensitivity: float = 0.003
## Min/max vertical angle (radians)
@export var min_pitch: float = -1.4
@export var max_pitch: float = 1.4
## Mouse button used to orbit
@export var orbit_button: MouseButton = MOUSE_BUTTON_LEFT
## Zoom settings
@export var zoom_speed: float = 0.02
@export var min_distance: float = 2.0
@export var max_distance: float = 50.0

var _yaw: float = 0.0
var _pitch: float = -0.5
var _paused := false
var _is_dragging := false


func _ready() -> void:
  if calculate:
    target = _calculate_plane_intersection()
  var offset := global_position - target
  distance = offset.length()
  distance = clampf(distance, min_distance, max_distance)
  _pitch = asin(offset.y / distance)
  _yaw = atan2(offset.x, offset.z)
  _update_camera()


func _input(event: InputEvent) -> void:
  if event.is_action_pressed("pause"):
    _paused = !_paused
    var tween = create_tween()
    if _paused:
      tween.tween_property(Engine, "time_scale", 0.1, 0.8)
    else:
      tween.tween_property(Engine, "time_scale", 1.0, 0.8)
    return

  if event is InputEventMouseButton:
    var mb := event as InputEventMouseButton
    if mb.button_index == orbit_button:
      _is_dragging = mb.pressed

  if event is InputEventMouseMotion and _is_dragging:
    var motion := event as InputEventMouseMotion
    if Input.is_key_pressed(KEY_SHIFT):
      # Pan: move target along camera's local right and up axes
      var right := global_transform.basis.x
      var up := global_transform.basis.y
      var pan_scale := distance * sensitivity
      target -= right * motion.relative.x * pan_scale
      target += up * motion.relative.y * pan_scale
    else:
      _yaw -= motion.relative.x * sensitivity
      _pitch += motion.relative.y * sensitivity  # inverted
      _pitch = clampf(_pitch, min_pitch, max_pitch)
    Global.mouse_dragging = true
    _update_camera()
  else:
    Global.mouse_dragging = false

  # Pinch-to-zoom (trackpad magnify gesture)
  if event is InputEventMagnifyGesture:
    var magnify := event as InputEventMagnifyGesture
    distance = clampf(distance / magnify.factor, min_distance, max_distance)
    _update_camera()

  # Fallback: two-finger scroll (trackpad pan gesture) for zoom
  if event is InputEventPanGesture:
    var pan := event as InputEventPanGesture
    distance = clampf(distance + pan.delta.y * zoom_speed, min_distance, max_distance)
    _update_camera()

  if event.is_action_released("ui_cancel"):
    get_tree().quit()


func _update_camera() -> void:
  var offset := Vector3.ZERO
  offset.x = distance * cos(_pitch) * sin(_yaw)
  offset.y = distance * sin(_pitch)
  offset.z = distance * cos(_pitch) * cos(_yaw)

  global_position = target + offset
  look_at(target, Vector3.UP)


func _calculate_plane_intersection() -> Vector3:
  # Cast a ray from the camera along its forward direction
  var origin = global_position
  var forward = -global_transform.basis.z

  # Intersect with the Y=0 plane
  # Plane equation: y = 0, normal = Vector3.UP
  # t = -origin.y / forward.y
  if is_zero_approx(forward.y):
    return target  # ray is parallel to the plane, keep current target

  var t = -origin.y / forward.y
  if t < 0:
    return target  # intersection is behind the camera, keep current target

  return origin + forward * t
