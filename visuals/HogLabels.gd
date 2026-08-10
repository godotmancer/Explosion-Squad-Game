## HogLabels — Label3D pool for per-hog state overlays.
##
## Attach this node as a child of the scene root (not under the MultiMeshInstance3D).
## Assign the SquadMultiMeshInstance3D node to [member physics_manager] in the editor.
##
## State is computed GPU-side in physics_compute.glsl as bitwise flags (STATE_* constants),
## read back by C#, and mapped to [enum HogBehaviourState] before calling into GDScript.
##
## C# calls three methods each physics frame:
##   assign_label(index, state, world_pos)   — acquire or update a label for the given body
##   release_label(index)                    — return label to pool (called on death)
##   update_label_position(index, world_pos) — move an active label (called for active labels only)
extends Node3D
class_name HogLabels

# ---- State enum (must match SquadMultiMeshInstance3D.HogBehaviourState and STATE_* in physics_compute.glsl) ----
enum HogBehaviourState { IDLE, WALKING, SPRINTING, DAMAGED, FLEEING, IN_FEAR, AIRBORNE }

const STATE_TEXT := {
  HogBehaviourState.IDLE:     "IDLE",
  HogBehaviourState.WALKING:  "WALKING",
  HogBehaviourState.SPRINTING:"SPRINT",
  HogBehaviourState.DAMAGED:  "HIT",
  HogBehaviourState.FLEEING:  "FLEE!",
  HogBehaviourState.IN_FEAR:  "FEAR",
  HogBehaviourState.AIRBORNE: "AIR",
}

const STATE_COLOR := {
  HogBehaviourState.IDLE:     Color(0.2,  0.902, 0.204, 1.0),
  HogBehaviourState.WALKING:  Color(0.614, 0.717, 1.0, 1.0),
  HogBehaviourState.SPRINTING:Color(1.045, 0.815, 0.844, 1.0),
  HogBehaviourState.DAMAGED:  Color(1.0,  0.15,  0.1),
  HogBehaviourState.FLEEING:  Color(1.0,  0.65,  0.0),
  HogBehaviourState.IN_FEAR:  Color(0.8,  0.3,   1.0),
  HogBehaviourState.AIRBORNE: Color(2.524, 1.972, 2.156, 1.0),
}

# ---- Visual configuration ----
@export var label_offset := Vector3(0.0, 0.8, 0.0) # height above mesh pivot

# ---- Pool configuration ----
## Maximum labels available simultaneously. Increase if many hogs are
## in notable states at once and labels start silently dropping.
@export var pool_size: int = 256

## A saved Label3D scene used as the visual template for every pooled label.
## Configure font, size, billboard mode, outline, etc. inside that scene.
@export var label_template: PackedScene

@export var physics_manager: SquadMultiMeshInstance3D  ## Assign SquadMultiMeshInstance3D in the editor

# ---- Internal state ----
var _pool:   Array[Label3D] = []         # inactive labels waiting for assignment
var _active: Dictionary     = {}         # body_index (int) -> Label3D


func _ready() -> void:
  _build_pool()


# Pre-allocate all labels once so there are no per-frame allocations.
func _build_pool() -> void:
  if label_template == null:
    push_error("HogLabels: label_template is not set. Assign a Label3D PackedScene in the inspector.")
    return
  _pool.resize(pool_size)
  for i in pool_size:
    var lbl: Label3D = label_template.instantiate()
    lbl.visible = false
    add_child(lbl)
    _pool[i] = lbl


# Called by C# whenever a body's state changes. All states show a label.
func assign_label(index: int, state: int, world_pos: Vector3) -> void:
  # Re-use existing label if this body already has one (state changed while active)
  var lbl: Label3D = _active.get(index)

  if lbl == null:
    if _pool.is_empty():
      return  # Pool exhausted — raise pool_size if this happens often
    lbl = _pool.pop_back()
    _active[index] = lbl

  lbl.text            = STATE_TEXT.get(state, "???")
  lbl.modulate        = STATE_COLOR.get(state, Color.WHITE)
  lbl.global_position = world_pos + label_offset
  lbl.visible         = true


# Called by C# when a body dies (state machine labels are updated via assign_label, not released).
func release_label(index: int) -> void:
  var lbl: Label3D = _active.get(index)
  if lbl == null:
    return
  lbl.visible = false
  _active.erase(index)
  _pool.push_back(lbl)

# Called speciically when we want to hide all labels
func release_all_labels() -> void:
  for index in _active.keys():
    var lbl: Label3D = _active[index]
    lbl.visible = false
    _pool.push_back(lbl)
  _active.clear()


# Called by C# every frame for every body that has an active label.
# Runs O(active labels) only, not O(all bodies).
# is_in_frustum toggles visibility without releasing the pool slot.
func update_label_position(index: int, world_pos: Vector3, is_in_frustum: bool = true) -> void:
  var lbl: Label3D = _active.get(index)
  if lbl != null:
    lbl.visible = is_in_frustum
    if is_in_frustum:
      lbl.global_position = world_pos + label_offset
