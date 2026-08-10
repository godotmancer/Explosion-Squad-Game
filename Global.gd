@tool
extends Node

signal notification_wrapped
signal projectile_impact(pos: Vector3, hit_type: ProjectileBase.HitType)
signal projectile_launched(from: Vector3, to: Vector3)
signal score_hit(ui_marker: Marker2D)

enum {
  ## Bitwise state flags — must match STATE_* constants in physics_compute.glsl
  HOG_STATE_IDLE = 1,
  HOG_STATE_WALKING = 2,
  HOG_STATE_SPRINTING = 4,
  HOG_STATE_DAMAGED = 8,
  HOG_STATE_FLEEING = 16,
  HOG_STATE_IN_FEAR = 32,
  HOG_STATE_AIRBORNE = 64,
  HOG_STATE_DEAD = 128,

  ## Contagion state bits (must match physics_compute.glsl)
  HOG_STATE_ON_FIRE = 256,
  HOG_STATE_POISONED = 512,
  HOG_STATE_DRUNK = 1024,
}

var mouse_dragging := false
var total_projectiles := 0

func is_in_state(hog_state: int, state: int) -> bool:
  return (hog_state & state) != 0

func emit_notification_wrapped() -> void:
  notification_wrapped.emit()

func emit_projectile_impact(pos: Vector3, hit_type: ProjectileBase.HitType) -> void:
  projectile_impact.emit(pos, hit_type)

func emit_projectile_launched(from: Vector3, to: Vector3) -> void:
  projectile_launched.emit(from, to)

func emit_score_hit(ui_marker: Marker2D) -> void:
  score_hit.emit(ui_marker)
