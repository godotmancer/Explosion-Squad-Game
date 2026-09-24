class_name ProjectileBase
extends Node3D

## Base class for visual projectiles.
## Steps its own state with the same semi-implicit Euler as projectile_compute.glsl, with the
## same gravity and ground height, so the drawn projectile follows the GPU one that does the
## damage. The drawn position is interpolated between physics ticks: a fast shot covers
## 1.3 m per tick at 80 m/s, and without this every projectile in a stream would hop in step
## on every other rendered frame, reading as a static dotted grid.
##
## Usage:
##   var proj: ProjectileBase = MY_SCENE.instantiate()
##   proj.ability = my_ability_resource
##   proj.spawner = projectile_spawner          # optional: the GPU copy that does damage
##   get_parent().add_child(proj)
##   proj.launch(from_pos, target_pos)          # aimed per the ability (direct or lobbed)
##   # or: proj.launch_velocity(from_pos, v)    # an explicit velocity vector

enum HitType { GROUND, HOG }

@export var ability: ProjectileAbility

@export_group("Physics")
## Used only without a spawner; with one, the GPU's own gravity and ground height are read
## from it, so the two copies cannot disagree.
@export var gravity: float = 9.8
@export var ground_height: float = 0.0

@export_group("GPU Spawner")
## Optional — if set, launching also fires the GPU projectile for collision/damage.
@export var spawner: ProjectilesSpawner

@onready var mesh_instance_3d: MeshInstance3D = $MeshInstance3D

# ---- Runtime state ----
var _vel: Vector3 = Vector3.ZERO
var _pos: Vector3 = Vector3.ZERO       # at the latest physics tick
var _prev_pos: Vector3 = Vector3.ZERO  # at the tick before; drawn position lerps between
var _gravity: float = 0.0              # world gravity × ability.gravity_scale
var _ground_y: float = 0.0
var _elapsed: float = 0.0
var _flight_time: float = 0.0          # estimated total flight time (for progress)
var _active: bool = false
var _slot: int = -1                    # GPU projectile slot; -1 if no spawner

# One material per projectile colour, shared by every projectile of that colour.
static var _materials_by_color := {}

func _ready() -> void:
  add_to_group("projectile")
  var color := Color(0.764, 0.764, 0.0) * 5.4
  if ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_FIRE:
    color = Color(0.909, 0.0, 0.0) * 5.4
  elif ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_POISON:
    color = Color(0.129, 0.737, 0.215) * 5.4
  elif ability.contagion_type == ProjectileAbility.PROJECTILE_CONTAGION_ALCOHOL:
    color = Color(0.367, 0.086, 0.521) * 5.4
  elif ability.explosion_radius > 0.0:
    color = Color(1.0, 0.42, 0.05) * 5.4

  if ability.has_teleport:
    color = color.blend(Color(0.0, 1.382, 1.64))

  color.a = 1.0
  mesh_instance_3d.set_surface_override_material(0, _material_for(color))


## A copy of the mesh's own material in [param color], made once per colour. The mesh and
## its material are sub-resources of the projectile scene, shared by every instance, so
## recolouring that material itself turned every projectile in flight the colour of the
## latest shot.
func _material_for(color: Color) -> Material:
  var material: StandardMaterial3D = _materials_by_color.get(color)
  if material == null:
    material = (mesh_instance_3d.mesh.surface_get_material(0) as StandardMaterial3D).duplicate()
    material.albedo_color = color
    _materials_by_color[color] = material
  return material


## Fire the projectile from [param from] at [param to], aimed per the ability: straight at
## [member ProjectileAbility.speed], or lobbed at [member ProjectileAbility.launch_angle_deg]
## so it lands on [param to]. Spread and speed variance are applied on top.
func launch(from: Vector3, to: Vector3) -> void:
  _resolve_physics()
  _start(from, aim_velocity(from, to), to)


## Fire the projectile from [param from] with an explicit [param velocity] (world units per
## second). Gravity, the GPU copy and impact behave exactly as for [method launch].
func launch_velocity(from: Vector3, velocity: Vector3) -> void:
  _resolve_physics()
  _start(from, velocity, from + velocity)


## The launch velocity a shot from [param from] at [param to] would get, spread included.
func aim_velocity(from: Vector3, to: Vector3) -> Vector3:
  _resolve_physics()
  var vel := Vector3.ZERO
  if ability.launch_angle_deg > 0.0 and _gravity > 0.0:
    vel = ballistic_velocity(from, to, deg_to_rad(ability.launch_angle_deg), _gravity)
    if vel != Vector3.ZERO:
      # The analytic arc lands on the target; the per-tick Euler step drops by an extra
      # g·dt/2 per second of flight. Starting that much faster upward makes the stepped
      # path pass through the analytic one at every tick, so the shell lands where aimed.
      vel.y += _gravity * _physics_dt() * 0.5
  if vel == Vector3.ZERO:
    vel = (to - from).normalized() * ability.speed
  return _scatter(vel)


## Velocity that leaves [param from] at [param angle] radians above horizontal and lands on
## [param to] under gravity [param g] — or ZERO if no speed at that angle can reach it (the
## target is too high for it, or straight above or below).
static func ballistic_velocity(from: Vector3, to: Vector3, angle: float, g: float) -> Vector3:
  var flat := Vector3(to.x - from.x, 0.0, to.z - from.z)
  var d := flat.length()
  if d < 0.001:
    return Vector3.ZERO
  var h := to.y - from.y
  var c := cos(angle)
  var denom := 2.0 * c * c * (d * tan(angle) - h)
  if denom <= 0.0:
    return Vector3.ZERO
  var launch_speed := sqrt(g * d * d / denom)
  return flat / d * (launch_speed * c) + Vector3.UP * (launch_speed * sin(angle))


func _physics_process(delta: float) -> void:
  if not _active:
    return
  _step(delta)
  if _active:
    _on_update(_elapsed / maxf(_flight_time, 0.001))


func _process(_delta: float) -> void:
  if not _active:
    return
  global_position = _prev_pos.lerp(_pos, Engine.get_physics_interpolation_fraction())
  _orient_to_velocity()


## Terminates the projectile immediately (called internally or externally).
## [param hit_type] is GROUND when it hits the floor, HOG when the GPU
## reports a body collision.
func kill(at_pos: Vector3, hit_type: HitType = HitType.GROUND) -> void:
  if not _active:
    return
  _active = false
  _slot = -1
  global_position = at_pos
  if ability != null and ability.explosion_radius > 0.0 and spawner != null:
    spawner.Detonate(at_pos, ability.explosion_radius, ability.explosion_force, ability.explosion_damage)
  Global.projectile_impact.emit(at_pos, hit_type)
  _on_impact(at_pos, hit_type)


# Called by the C# hit callback when the GPU projectile hits a body.
func _on_gpu_hit(hit_pos: Vector3) -> void:
  kill(hit_pos, HitType.HOG)


# ---- Private ----

func _start(from: Vector3, velocity: Vector3, aim_point: Vector3) -> void:
  _vel = velocity
  _pos = from
  _prev_pos = from
  _elapsed = 0.0
  _flight_time = _estimate_flight_time(from, velocity)
  _active = true
  global_position = from
  _orient_to_velocity()

  if spawner != null and ability != null:
    # Same start and velocity as this node, so the GPU copy flies the identical path
    _slot = spawner.SpawnProjectileWithVelocity(from, _vel, ability)
    if _slot >= 0:
      spawner.RegisterProjectileHitCallback(_slot, _on_gpu_hit)

  Global.projectile_launched.emit(from, aim_point)
  _on_launch()

  # The GPU copy takes its first step in this same physics frame — it is uploaded and
  # dispatched after this call returns — while this node only starts processing on the
  # next one. Take that step now so the two stay in lockstep instead of the drawn one
  # trailing by a tick. The drawn position still starts at the muzzle and glides from there.
  _step(_physics_dt())


## One physics tick of flight — the same semi-implicit Euler as projectile_compute.glsl:
##   vel_y -= gravity * dt
##   pos   += vel * dt
func _step(dt: float) -> void:
  _prev_pos = _pos
  _vel.y -= _gravity * dt
  _pos += _vel * dt
  _elapsed += dt
  if _pos.y < _ground_y:
    # Where this step crossed the ground, as the GPU copy computes it
    var t := 0.0
    if _pos.y < _prev_pos.y:
      t = clampf((_ground_y - _prev_pos.y) / (_pos.y - _prev_pos.y), 0.0, 1.0)
    kill(_prev_pos.lerp(_pos, t), HitType.GROUND)
  elif _elapsed >= ability.lifetime:
    # The GPU copy runs out on this same step (its lifetime counts down by the same dt),
    # and C# fires no hit callback for that — so without this, a shot that never came down
    # would fly on forever.
    expire()


## Retires the projectile without an impact: its lifetime ran out in flight. Unlike
## [method kill] it emits no [signal Global.projectile_impact] and sets off no explosion,
## since it hit nothing.
func expire() -> void:
  if not _active:
    return
  _active = false
  _slot = -1
  _on_expire()


func _resolve_physics() -> void:
  var g := gravity
  _ground_y = ground_height
  if spawner != null:
    g = spawner.GetGravity()
    _ground_y = spawner.GetGroundHeight()
  _gravity = g * (ability.gravity_scale if ability != null else 0.0)


## Random aim error within the ability's spread cone, and muzzle speed error.
func _scatter(vel: Vector3) -> Vector3:
  var launch_speed := vel.length()
  if launch_speed < 0.0001:
    return vel
  var dir := vel / launch_speed
  if ability.spread_deg > 0.0:
    # sqrt keeps the shots evenly spread over the cone's cross-section rather than bunched
    # at its centre
    var off := deg_to_rad(ability.spread_deg) * sqrt(randf())
    var around := randf() * TAU
    var side := dir.cross(Vector3.UP)
    if side.length_squared() < 0.0001:
      side = dir.cross(Vector3.RIGHT)
    side = side.normalized()
    var up := side.cross(dir)
    dir = (dir * cos(off) + (side * cos(around) + up * sin(around)) * sin(off)).normalized()
  if ability.speed_variance > 0.0:
    launch_speed *= 1.0 + randf_range(-ability.speed_variance, ability.speed_variance)
  return dir * launch_speed


static func _physics_dt() -> float:
  return 1.0 / float(Engine.physics_ticks_per_second)


func _orient_to_velocity() -> void:
  if _vel.length_squared() < 0.001:
    return
  var forward := _vel.normalized()
  var up := Vector3.FORWARD if absf(forward.dot(Vector3.UP)) > 0.99 else Vector3.UP
  look_at(global_position + forward, up)


## Estimate of flight time: steps the same arc coarsely until it reaches the ground.
func _estimate_flight_time(from: Vector3, velocity: Vector3) -> float:
  const EST_DT := 0.05
  const MAX_STEPS := 240
  var vel := velocity
  var pos := from
  for i in MAX_STEPS:
    vel.y -= _gravity * EST_DT
    pos   += vel * EST_DT
    if pos.y < _ground_y:
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


## Called once when the projectile's lifetime runs out in flight, having hit nothing.
## Default behaviour is to free the node; call super() in your override if needed.
func _on_expire() -> void:
  queue_free()


## Called every physics frame while the projectile is in flight.
## [param progress] runs from 0.0 (launch) to ~1.0 (impact).
func _on_update(_progress: float) -> void:
  pass
