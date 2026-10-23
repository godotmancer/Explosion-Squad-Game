@tool
extends Node3D
class_name DrawableGround

@export var hogs_mesh_instances: SquadMultiMeshInstance3D
@export var size: Vector2i = Vector2i(2048, 2048)
@export var color: Color = Color.AQUA :
  set(value):
    color = value

@export var explosion_texture: Texture2D
@export var projectile_texture: Texture2D
@export var explosions_per_frame: int = 5
## Number of pre-baked rotation variants per texture/state combination.
## Higher = more variety, more memory. 32 is imperceptible vs 360.
@export var num_baked_rotations: int = 32

@onready var albedo_texture: DrawableTexture2D
@onready var mesh_instance_3d: MeshInstance3D = $MeshInstance3D

var world_size_from_mesh: Vector2

# Pre-baked pools: "fire"|"poison"|"drunk"|"default"|"hit"|"explosion"
# -> Array[ImageTexture] of rotated variants
var _baked: Dictionary = {}

# Pending blits, drained at explosions_per_frame in _process. A fixed ring: a bomb killing
# thousands queues positions without an Array per entry, and popping is O(1). When it is full
# the oldest blit is dropped.
const _QUEUE_CAPACITY := 4096
var _queue_pos := PackedVector3Array()
var _queue_tex: Array[Texture2D] = []
var _queue_head := 0
var _queue_count := 0

# Tint colour (r,g,b) baked into the pixel data; alpha is midpoint of the
# original randf_range so variance is gone but perf is recovered.
const _DEATH_TINTS: Dictionary = {
  "fire":    Color(1.6, 0.3, 0.0, 0.3),
  "poison":  Color(0.0, 1.6, 0.0, 0.3),
  "drunk":   Color(0.0, 1.6, 1.6, 0.3),
  "default": Color(1.0, 0.0, 0.0, 0.3),
}


func _ready() -> void:
  var material: StandardMaterial3D = $MeshInstance3D.material_override
  albedo_texture = material.albedo_texture
  albedo_texture.setup(size.x, size.y, DrawableTexture2D.DRAWABLE_FORMAT_RGBA8_SRGB, color, false)
  var quad := mesh_instance_3d.mesh as QuadMesh
  world_size_from_mesh = quad.size
  _queue_pos.resize(_QUEUE_CAPACITY)
  _queue_tex.resize(_QUEUE_CAPACITY)

  Global.projectile_impact.connect(_on_projectile_hit_ground, CONNECT_DEFERRED)
  if hogs_mesh_instances:
    hogs_mesh_instances.connect("HogsDied", _on_hogs_died)

  _prebake_all_textures()


# ---------------------------------------------------------------------------
# Pre-baking — runs once at startup, no SubViewports, no GPU round-trips.
# ---------------------------------------------------------------------------

func _prebake_all_textures() -> void:
  if projectile_texture:
    var src := _get_rgba8_image(projectile_texture)
    if src:
      for key in _DEATH_TINTS:
        _baked[key] = _bake_rotations(src, _DEATH_TINTS[key],randf_range(0.2, 0.3))
      # Neutral tint for projectile ground hits (original scale was 0.1)
      _baked["hit"] = _bake_rotations(src, Color(0.6, 0.6, 0.6, 0.40), 0.2)

  if explosion_texture:
    var src := _get_rgba8_image(explosion_texture)
    if src:
      _baked["explosion"] = _bake_rotations(
        src, Color(1.0, 0.0, 0.0, 0.80), randf_range(0.9, 1.3))


func _get_rgba8_image(tex: Texture2D) -> Image:
  var img := tex.get_image()
  if img == null:
    return null
  img.convert(Image.FORMAT_RGBA8)
  return img


func _bake_rotations(src: Image, tint: Color, image_scale: float) -> Array[ImageTexture]:
  var result: Array[ImageTexture] = []
  result.resize(num_baked_rotations)
  for i in range(num_baked_rotations):
    var angle := (float(i) / num_baked_rotations) * TAU
    result[i] = ImageTexture.create_from_image(_rotate_and_tint(src, angle, tint, image_scale))
  return result


# CPU nearest-neighbour rotate + tint. For the tiny sizes used here
# (scale ≤ 0.1 → output ≤ ~30 px) this is orders of magnitude cheaper than
# a SubViewport round-trip and runs once at startup.
func _rotate_and_tint(src: Image, angle: float, tint: Color, image_scale: float) -> Image:
  var w := src.get_width()
  var h := src.get_height()
  var diag := ceili(sqrt(float(w * w + h * h)))
  var out_sz := maxi(ceili(diag * image_scale), 1)

  var result := Image.create(out_sz, out_sz, true, Image.FORMAT_RGBA8)
  var cx := out_sz * 0.5
  var cy := out_sz * 0.5
  var src_cx := w * 0.5
  var src_cy := h * 0.5
  var cos_a := cos(-angle)
  var sin_a := sin(-angle)
  var inv_sc := 1.0 / image_scale

  for y in range(out_sz):
    for x in range(out_sz):
      var ox := (x - cx) * inv_sc
      var oy := (y - cy) * inv_sc
      var rx := ox * cos_a - oy * sin_a + src_cx
      var ry := ox * sin_a + oy * cos_a + src_cy
      if rx >= 0.0 and rx < w - 1 and ry >= 0.0 and ry < h - 1:
        var px := src.get_pixel(int(rx), int(ry))
        px.r = minf(px.r * tint.r, 1.0)
        px.g = minf(px.g * tint.g, 1.0)
        px.b = minf(px.b * tint.b, 1.0)
        px.a = minf(px.a * tint.a, 1.0)
        result.set_pixel(x, y, px)

  return result


# ---------------------------------------------------------------------------
# Runtime — signal handlers push to queue; _process drains it at a safe rate.
# ---------------------------------------------------------------------------

func _process(_delta: float) -> void:
  var count := 0
  while _queue_count > 0 and count < explosions_per_frame:
    _blit_texture(_queue_pos[_queue_head], _queue_tex[_queue_head])
    _queue_tex[_queue_head] = null
    _queue_head = (_queue_head + 1) % _QUEUE_CAPACITY
    _queue_count -= 1
    count += 1


func _enqueue_blit(pos: Vector3, tex: Texture2D) -> void:
  if _queue_count == _QUEUE_CAPACITY:
    _queue_head = (_queue_head + 1) % _QUEUE_CAPACITY
    _queue_count -= 1
  var tail := (_queue_head + _queue_count) % _QUEUE_CAPACITY
  _queue_pos[tail] = pos
  _queue_tex[tail] = tex
  _queue_count += 1


func _enqueue_from_pool(pos: Vector3, pool: Array) -> void:
  if not pool.is_empty():
    _enqueue_blit(pos, pool[randi() % pool.size()])


# Every hog that died this tick, in one call; the decal is coloured by its contagion at death.
func _on_hogs_died(_indices: PackedInt32Array, positions: PackedVector3Array, state_bits: PackedInt32Array) -> void:
  var fire: Array = _baked.get("fire", [])
  var poison: Array = _baked.get("poison", [])
  var drunk: Array = _baked.get("drunk", [])
  var plain: Array = _baked.get("default", [])
  for k in positions.size():
    var bits := state_bits[k]
    var pool := plain
    if bits & Global.HOG_STATE_ON_FIRE:
      pool = fire
    elif bits & Global.HOG_STATE_POISONED:
      pool = poison
    elif bits & Global.HOG_STATE_DRUNK:
      pool = drunk
    _enqueue_from_pool(positions[k], pool)


func _on_projectile_hit_ground(pos: Vector3, _hit_type: ProjectileBase.HitType) -> void:
  _enqueue_from_pool(pos, _baked.get("hit", []))


func draw_explosion(world_pos_3d: Vector3) -> void:
  _enqueue_from_pool(world_pos_3d, _baked.get("explosion", []))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

func _blit_texture(world_pos_3d: Vector3, texture: Texture2D) -> void:
  var center := _world_to_plane(world_pos_3d)
  var texture_size := texture.get_size()
  var dest_pos := center - texture_size / 2.0
  albedo_texture.blit_rect(Rect2i(dest_pos, texture_size), texture)


func _world_to_plane(world_pos: Vector3) -> Vector2:
  var origin := mesh_instance_3d.global_position
  var offset_x := world_pos.x - origin.x
  var offset_z := world_pos.z - origin.z
  var half_world := world_size_from_mesh / 2.0
  var u := ((offset_x + half_world.x) / world_size_from_mesh.x) * size.x
  var v := ((half_world.y + offset_z) / world_size_from_mesh.y) * size.y
  u = clampf(u, 0.0, size.x)
  v = clampf(v, 0.0, size.y)
  return Vector2(u, v)
