extends Node
class_name GateTrigger

@export var allowed_triggers: int = 10
@export var mesh_instance_3d: MeshInstance3D
@export var gate_mesh_3d: MeshInstance3D
@export var ui_target_marker: Marker2D


@onready var announce_scn := preload("res://visuals/Announce3D.tscn")

var tween : Tween
var material: StandardMaterial3D
var damage_effect: bool
var initial_triggers: int

func _ready() -> void:
  initial_triggers = allowed_triggers
  material = mesh_instance_3d.get_active_material(0) as StandardMaterial3D

func trigger(
  _hog_index: int,
  _position: Vector3,
  _zone: CollisionShape3D,
  _effect: int
  ) -> void:
  material.emission_energy_multiplier = 0.0
  damage_effect = _effect == 0
  if tween:
    tween.kill()

  if damage_effect:
    material.emission = Color.DARK_RED

  tween = create_tween()
  tween.tween_property(material, "emission_energy_multiplier", 16.0, 0.15)
  tween.tween_property(material, "emission_energy_multiplier", 0.0, 0.05)
  allowed_triggers -= 1
  var announce := announce_scn.instantiate() as Announce3D
  if damage_effect:
    announce.text = "%d" % [initial_triggers - allowed_triggers]
    announce.color = Color.FIREBRICK
  else:
    var amount = _zone.get_meta("add") as int if _zone.has_meta("add") else _zone.get_meta("multiply") as int
    announce.text = "x%d" % [amount]

  if ui_target_marker:
    announce.move_towards_2d_position = true
    announce.ui_target_marker = ui_target_marker

  get_tree().root.add_child(announce)
  announce.global_position = _position

  if allowed_triggers <= 0:
    _zone.disabled = true
    _zone.visible = false
    if gate_mesh_3d:
      gate_mesh_3d.visible = false
