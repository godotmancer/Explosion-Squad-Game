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

func _ready():
  pass

func _physics_process(_delta: float) -> void:
  if Input.is_action_pressed("spawn_projectile"):
    spawn_projectile(projectile_bullet_ability)

  if Input.is_action_pressed("spawn_fire"):
    spawn_projectile(projectile_fire_ability)

  if Input.is_action_pressed("spawn_poison"):
    spawn_projectile(projectile_poison_ability)

  if Input.is_action_pressed("spawn_drunk"):
    spawn_projectile(projectile_drunk_ability)

  if Input.is_action_pressed("spawn_teleport"):
    var new_teleport_ability := projectile_teleport_ability.duplicate()
    new_teleport_ability.teleport_pos = teleport_marker.global_position
    new_teleport_ability.force_dir = (mouse_global_pos.global_position - teleport_marker.global_position).normalized()
    spawn_projectile(new_teleport_ability)


func spawn_projectile(ability: ProjectileAbility) -> void:
  var projectile := projectile_scn.instantiate() as ProjectileBase
  projectile.spawner = projectile_spawner
  projectile.ability = ability
  get_tree().current_scene.add_child(projectile)
  projectile.global_position = projectile_spawn_marker.global_position
  projectile.launch(projectile_spawn_marker.global_position, mouse_global_pos.global_position)
  Global.total_projectiles += 1
