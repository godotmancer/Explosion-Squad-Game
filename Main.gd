extends Node3D

@export var projectile_spawner : ProjectilesSpawner
@export var mouse_global_pos : Node3D
@export var projectile_spawn_marker : Node3D
@export var projectile_scn : PackedScene
@export var teleport_marker : Node3D

@export_group("Lob modifier")
## Holding the lob modifier (Shift) lobs whichever projectile is fired onto the target at this
## elevation and gravity, instead of firing it straight. Defaults match the mortar.
@export_range(1.0, 89.0) var lob_angle_deg := 55.0
@export var lob_gravity_scale := 2.5


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

# Lobbed copies of the shared abilities, made on first use and reused (keyed by the original).
var _lobbed := {}

func _ready():
  pass

func _physics_process(delta: float) -> void:
  _time += delta
  var lob := Input.is_action_pressed("lob_modifier")

  if Input.is_action_pressed("spawn_projectile") and _ready_to_fire(projectile_bullet_ability):
    spawn_projectile(_as_fired(projectile_bullet_ability, lob))

  if Input.is_action_pressed("spawn_fire") and _ready_to_fire(projectile_fire_ability):
    spawn_projectile(_as_fired(projectile_fire_ability, lob))

  if Input.is_action_pressed("spawn_poison") and _ready_to_fire(projectile_poison_ability):
    spawn_projectile(_as_fired(projectile_poison_ability, lob))

  if Input.is_action_pressed("spawn_drunk") and _ready_to_fire(projectile_drunk_ability):
    spawn_projectile(_as_fired(projectile_drunk_ability, lob))

  if Input.is_action_pressed("spawn_teleport") and _ready_to_fire(projectile_teleport_ability):
    var new_teleport_ability := projectile_teleport_ability.duplicate()
    new_teleport_ability.teleport_pos = teleport_marker.global_position
    new_teleport_ability.force_dir = (mouse_global_pos.global_position - teleport_marker.global_position).normalized()
    if lob:
      # Already a fresh copy per shot, so lob it in place rather than caching a copy of it
      _make_lobbed(new_teleport_ability)
    spawn_projectile(new_teleport_ability)

  if Input.is_action_pressed("spawn_mortar") and _ready_to_fire(projectile_mortar_ability):
    spawn_projectile(_as_fired(projectile_mortar_ability, lob))


## [param ability] as it should be fired: unchanged, or — with the lob modifier held — a copy
## lobbed onto the target (see [method _make_lobbed]). An ability that lobs by itself, like the
## mortar, is returned as is. The cooldown stays keyed on the original, so lobbed and straight
## shots of one ability share their fire rate.
func _as_fired(ability: ProjectileAbility, lob: bool) -> ProjectileAbility:
  if not lob or ability.launch_angle_deg > 0.0:
    return ability
  var lobbed: ProjectileAbility = _lobbed.get(ability)
  if lobbed == null:
    lobbed = ability.duplicate()
    _make_lobbed(lobbed)
    _lobbed[ability] = lobbed
  return lobbed


## Turns [param ability] into a lob: launched at lob_angle_deg under lob_gravity_scale, with
## ProjectileBase solving the speed that lands it on the target. Everything else — damage,
## contagion, teleport, spread — is kept.
func _make_lobbed(ability: ProjectileAbility) -> void:
  ability.launch_angle_deg = lob_angle_deg
  ability.gravity_scale = lob_gravity_scale


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
