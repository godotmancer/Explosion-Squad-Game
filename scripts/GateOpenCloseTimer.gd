extends Timer
class_name GateOpenCloseTimer

@export var gate_animation : GateAnimation
@export var time_to_open : float = 15.0
@export var time_to_close : float = 5.0
@export var start_open : bool = false
@export var latch : bool = false :
  set(value):
    latch = value
    _process_gate_timer()


var open_gate : bool = true

func _ready() -> void:
  connect("timeout", _on_timer_timeout)
  gate_animation.connect("fully_opened", _process_gate_timer)
  gate_animation.connect("fully_closed", _process_gate_timer)
  if start_open:
    gate_animation.open_gate(true)
  _process_gate_timer()

func _process_gate_timer() -> void:
  if latch:
    stop()
    return

  if gate_animation.is_fully_closed():
    wait_time = time_to_open
    open_gate = true
    start()
  elif gate_animation.is_fully_open():
    wait_time = time_to_close
    open_gate = false
    start()

func _on_timer_timeout() -> void:
  if open_gate:
    gate_animation.open_gate()
  else:
    gate_animation.close_gate()
