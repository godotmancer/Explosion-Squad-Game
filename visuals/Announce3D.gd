@tool
extends Node3D
class_name Announce3D

@export var text: String = "1000":
  set(value):
    text = value

@export var color: Color = Color(0.663, 1.0, 0.224):
  set(value):
    color = value

@export_group("2D Movement")
@export var move_towards_2d_position: bool
@export var ui_target_marker: Marker2D
@export var move_speed: float = 5.0
@export var target_depth: float = 2.0 # Distance from the camera in 3D space where the object will end up


@onready var text_mesh_node: MeshInstance3D = $TextMesh3D


@export_tool_button("Announce") var announce_button = _announce

var mesh: TextMesh
var material: StandardMaterial3D
var camera3d: Camera3D
var is_animating: bool = false

func _ready() -> void:
  set_process(false)
  mesh = text_mesh_node.mesh as TextMesh
  mesh.text = text
  material = text_mesh_node.get_active_material(0) as StandardMaterial3D

  _announce()

func _physics_process(delta: float) -> void:
  if not is_animating or camera3d == null or ui_target_marker == null:
    return

  # 1. Get the screen-space coordinate of the 2D marker.
  var screen_pos_2d: Vector2 = ui_target_marker.get_global_transform_with_canvas().origin

  # 2. Convert to 3D position
  var target_pos_3d: Vector3 = camera3d.project_position(screen_pos_2d, target_depth)

  # 3. Move the TEXT MESH smoothly towards the calculated 3D position, NOT the parent.
  text_mesh_node.global_position = text_mesh_node.global_position.lerp(target_pos_3d, move_speed * delta)

  scale = scale.lerp(Vector3.ONE*0.1, move_speed * delta)


  #if camera3d.projection == Camera3D.PROJECTION_PERSPECTIVE:
    ## Notice I changed 52.0 to 52.6 to match your exact FOV
    #var scale_factor = tan(deg_to_rad(camera3d.fov) / 2.0) / tan(deg_to_rad(75) / 2.0)
    #scale = Vector3.ONE * scale_factor

  # 4. Check the distance on the text_mesh_node, not the parent
  if text_mesh_node.global_position.distance_to(target_pos_3d) < 0.05:
    text_mesh_node.global_position = target_pos_3d
    is_animating = false
    set_process(false) # Good practice to turn off process when done
    Global.emit_score_hit(ui_target_marker)
    queue_free() # Clean up the node once it hits the UI


func _announce() -> void:
  material.albedo_color = color
  material.emission = color
  text_mesh_node.scale = Vector3.ZERO
  text_mesh_node.position = Vector3.ZERO
  text_mesh_node.transparency = 0.0
  var tween = create_tween().set_parallel()
  tween.tween_property(text_mesh_node, "scale", Vector3.ONE, 0.2).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
  tween.tween_property(text_mesh_node, "position", Vector3(0, randf_range(6.0, 7.5), 0), 0.25).set_trans(Tween.TRANS_BOUNCE).set_ease(Tween.EASE_OUT)
  tween.tween_property(material, "emission_energy_multiplier", 16, 0.3)
  tween.set_parallel(false)
  #tween.tween_property(material, "emission_energy_multiplier", 0, 0.1)
  #tween.set_parallel()
  if not move_towards_2d_position:
    tween.tween_property(text_mesh_node, "transparency", 1.0, 0.1)
  #tween.tween_property(text_mesh_node, "scale", Vector3.ONE*1.1, 0.2)
  tween.set_parallel(false)
  if not Engine.is_editor_hint():
    if move_towards_2d_position:
      tween.tween_callback(start_score_animation)
    else:
      tween.tween_callback(queue_free)
  else:
    tween.tween_callback(_reset)

func start_score_animation() -> void:
  is_animating = true
  camera3d = get_viewport().get_camera_3d()
  set_process(true)


func _reset() -> void:
  text_mesh_node.scale = Vector3.ONE
  text_mesh_node.position = Vector3.ZERO
  text_mesh_node.transparency = 0.0
