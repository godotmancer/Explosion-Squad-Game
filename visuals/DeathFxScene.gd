extends Node3D

signal fx_finished(node: Node3D)

var is_pooled: bool = false

@onready var particles: GPUParticles3D = $GPUParticles3D

func _ready() -> void:
  if not is_pooled:
    play_fx()

func play_fx() -> void:
  particles.restart()
  particles.emitting = true

  # Avoid buggy 'finished' signal propagation on re-pooled particles.
  await get_tree().create_timer(particles.lifetime + 0.1, false).timeout

  if is_pooled:
    fx_finished.emit(self)
  else:
    queue_free()
