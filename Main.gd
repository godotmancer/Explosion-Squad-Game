extends Node3D

@export var projectile_spawner : ProjectilesSpawner
@export var mouse_global_pos : Node3D
@export var projectile_spawn_marker : Node3D
@export var projectile_scn : PackedScene
@export var teleport_marker : Node3D


var projectile_bullet_ability := preload("res://projectiles/BulletProjectile.tres")
var projectile_fire_ability := preload("res://projectiles/FireProjectile.tres")
var projectile_poison_ability := preload("res://projectiles/PoisonProjectile.tres")
var projectile_drunk_ability := preload("res://projectiles/DrunkProjectile.tres")
var projectile_teleport_ability := preload("res://projectiles/TeleportProjectile.tres")
var projectile_mortar_ability := preload("res://projectiles/MortarProjectile.tres")

# Physics time, and the earliest time each ability may fire again (keyed by the resource).
# Holding a key fires at the ability's fire_interval rather than once per physics frame.
var _time := 0.0
var _next_shot := {}

func _ready():
  pass

func _physics_process(delta: float) -> void:
  _time += delta

  if Input.is_action_pressed("spawn_projectile") and _ready_to_fire(projectile_bullet_ability):
    spawn_projectile(projectile_bullet_ability)

  if Input.is_action_pressed("spawn_fire") and _ready_to_fire(projectile_fire_ability):
    spawn_projectile(projectile_fire_ability)

  if Input.is_action_pressed("spawn_poison") and _ready_to_fire(projectile_poison_ability):
    spawn_projectile(projectile_poison_ability)

  if Input.is_action_pressed("spawn_drunk") and _ready_to_fire(projectile_drunk_ability):
    spawn_projectile(projectile_drunk_ability)

  if Input.is_action_pressed("spawn_teleport") and _ready_to_fire(projectile_teleport_ability):
    var new_teleport_ability := projectile_teleport_ability.duplicate()
    new_teleport_ability.teleport_pos = teleport_marker.global_position
    new_teleport_ability.force_dir = (mouse_global_pos.global_position - teleport_marker.global_position).normalized()
    spawn_projectile(new_teleport_ability)

  if Input.is_action_pressed("spawn_mortar") and _ready_to_fire(projectile_mortar_ability):
    spawn_projectile(projectile_mortar_ability)


## True if [param ability] may fire this frame, and if so starts its cooldown. The first
## press always fires at once; holding the key then repeats every fire_interval.
func _ready_to_fire(ability: ProjectileAbility) -> bool:
  if _time + 0.0001 < _next_shot.get(ability, 0.0):
    return false
  _next_shot[ability] = _time + ability.fire_interval
  return true


func spawn_projectile(ability: ProjectileAbility) -> void:
  var projectile := projectile_scn.instantiate() as ProjectileBase
  projectile.spawner = projectile_spawner
  projectile.ability = ability
  get_tree().current_scene.add_child(projectile)
  projectile.launch(projectile_spawn_marker.global_position, mouse_global_pos.global_position)
  Global.total_projectiles += 1
