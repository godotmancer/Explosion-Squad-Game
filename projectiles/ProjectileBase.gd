class_name ProjectileBase
extends Node3D

## Base class for visual projectiles.
## Integrates in real-time using the same semi-implicit Euler as
## projectile_compute.glsl, so the visual position is frame-exact with the
## GPU physics projectile.
##
## Usage:
##   var proj: ProjectileBase = MY_SCENE.instantiate()
##   proj.ability = my_ability_resource
##   get_parent().add_child(proj)
##   proj.launch(from_pos, target_pos)
##
## The optional `spawner` export triggers the GPU-side projectile alongside
## the visual one so collision/damage are handled automatically.

enum HitType { GROUND, HOG }

@export var ability: ProjectileAbility

@export_group("Physics")
## Must match SquadMultiMeshInstance3D.Gravity.
@export var gravity: float = 9.8
## Must match SquadMultiMeshInstance3D.YOffset.
@export var y_offset: float = -0.25
@export var projectile_speed: float = 30.0

@export_group("GPU Spawner")
## Optional — if set, launch() also fires the GPU projectile for collision/damage.
@export var spawner: ProjectilesSpawner

@onready var mesh_instance_3d: MeshInstance3D = $MeshInstance3D

# ---- Runtime state ----
var _vel: Vector3 = Vector3.ZERO
var _pos: Vector3 = Vector3.ZERO
var _elapsed: float = 0.0
var _flight_time: float = 0.0   # estimated total flight time (for progress)
var _active: bool = false
var _slot: int = -1              # GPU projectile slot; -1 if no spawner

func _ready() -> void:
  add_to_group("projectile")
  var material = mesh_instance_3d.get_active_material(0) as StandardMaterial3D
  material.albedo_color = Color(0.764, 0.764, 0.0) * 5.4
  if ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_FIRE:
    material.albedo_color = Color(0.909, 0.0, 0.0) * 5.4
  elif ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_POISON:
    material.albedo_color = Color(0.129, 0.737, 0.215) * 5.4
  elif ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_ALCOHOL:
    material.albedo_color = Color(0.367, 0.086, 0.521) * 5.4

  if ability.has_teleport:
    material.albedo_color = material.albedo_color.blend(Color(0.0, 1.382, 1.64))

  material.albedo_color.a = 1.0

## Fire the projectile from [param from] toward [param to].
## Optionally calls the GPU spawner using the exact same velocity.
func launch(from: Vector3, to: Vector3) -> void:
  var dir := (to - from).normalized()
  _vel = dir * projectile_speed
  _pos = from
  _elapsed = 0.0
  _flight_time = _estimate_flight_time(from, dir)
  _active = true
  # Set initial position and orientation before the first frame
  global_position = _pos
  _orient_to_velocity()

  if spawner != null and ability != null:
    # Pass exact velocity so GPU and visual projectiles are in sync
    _slot = spawner.SpawnProjectileWithVelocity(from, _vel, ability)
    if _slot >= 0:
      spawner.RegisterProjectileHitCallback(_slot, _on_gpu_hit)

  Global.projectile_launched.emit(from, to)
  _on_launch()


func _physics_process(delta: float) -> void:
  if not _active:
    return

  # Semi-implicit Euler — matches projectile_compute.glsl exactly:
  #   vel_y -= gravity * dt
  #   pos   += vel * dt
  _vel.y -= gravity * delta
  _pos += _vel * delta
  _elapsed += delta

  global_position = _pos
  _orient_to_velocity()

  _on_update(_elapsed / maxf(_flight_time, 0.001))

  if _pos.y < y_offset:
    kill(_pos, HitType.GROUND)


## Terminates the projectile immediately (called internally or externally).
## [param hit_type] is GROUND when it hits the floor, HOG when the GPU
## reports a body collision.
func kill(at_pos: Vector3, hit_type: HitType = HitType.GROUND) -> void:
  if not _active:
    return
  _active = false
  _slot = -1
  global_position = at_pos
  Global.projectile_impact.emit(at_pos, hit_type)
  _on_impact(at_pos, hit_type)


# Called by the C# hit callback when the GPU projectile hits a body.
func _on_gpu_hit(hit_pos: Vector3) -> void:
  kill(hit_pos, HitType.HOG)


# ---- Private ----

func _orient_to_velocity() -> void:
  if _vel.length_squared() < 0.001:
    return
  var forward := _vel.normalized()
  var up := Vector3.FORWARD if absf(forward.dot(Vector3.UP)) > 0.99 else Vector3.UP
  look_at(_pos + forward, up)


## Analytical estimate of flight time using semi-implicit Euler recurrence.
## y(n) = y0 + v0y*n*dt - g*dt²*n*(n+1)/2;  solve for y(n) = y_offset.
## Falls back to a fixed-step simulation for the case where the arc goes up first.
func _estimate_flight_time(from: Vector3, dir: Vector3) -> float:
  # Walk forward in coarse steps to find ground crossing (same as before, but
  # only to compute duration — no position array needed).
  const EST_DT := 0.05
  const MAX_STEPS := 240
  var vel := dir * projectile_speed
  var pos := from
  for i in MAX_STEPS:
    vel.y -= gravity * EST_DT
    pos   += vel * EST_DT
    if pos.y < y_offset:
      return i * EST_DT
  return MAX_STEPS * EST_DT


# ---- Virtual hooks — override in subclasses ----

## Called once when the projectile begins its arc.
func _on_launch() -> void:
  pass


## Called once when the projectile is killed (ground or hog hit).
## [param hit_type] tells you which case it was.
## Default behaviour is to free the node; call super() in your override if needed.
func _on_impact(_impact_pos: Vector3, _hit_type: HitType) -> void:
  queue_free()


## Called every physics frame while the projectile is in flight.
## [param progress] runs from 0.0 (launch) to ~1.0 (impact).
func _on_update(_progress: float) -> void:
  pass
