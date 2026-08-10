extends Node3D
class_name Bomb

@export var grenade: Node3D
@onready var bomb_trail: GPUParticles3D = $BombTrail
@onready var black_hole: Node3D = $BlackHole
@onready var black_hole_mesh: MeshInstance3D = %BlackHoleMesh
@onready var omni_light_3d: OmniLight3D = $OmniLight3D

var final_global_position : Vector3
var drop_bomb_action : Callable
var radius : float = 3.0
var light_energy_up : float

func _ready() -> void:
  bomb_trail.set_emitting.call_deferred(true)
  omni_light_3d.visible = false
  light_energy_up = omni_light_3d.light_energy
  omni_light_3d.light_energy = 0.0
  black_hole.visible = false
  black_hole.rotate_y(randf_range(-PI*2, PI*2))

  var tween = create_tween()

  tween.tween_property(self, "global_position", final_global_position, 0.6).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)

  tween.tween_callback(drop_bomb_action.bind(final_global_position))
  tween.tween_callback(grenade.set_visible.bind(false))
  tween.tween_callback(black_hole.set_visible.bind(true))
  tween.tween_callback(omni_light_3d.set_visible.bind(true))

  tween.set_parallel(true)
  tween.tween_property(black_hole,"scale",Vector3(radius, radius, radius),0.1)
  tween.tween_property(omni_light_3d,"light_energy",light_energy_up,0.1)
  tween.set_parallel(false)

  tween.tween_callback(bomb_trail.set_emitting.bind(false))

  radius = radius*1.2
  tween.parallel()

  tween.tween_property(black_hole,"scale",Vector3(radius, radius, radius),0.06)
  tween.tween_property(black_hole_mesh,"transparency",1.0,0.04)
  tween.tween_property(omni_light_3d,"light_energy",0.0,0.06)

  tween.set_parallel(false)
  tween.tween_interval(0.3)
  tween.tween_callback(queue_free)
