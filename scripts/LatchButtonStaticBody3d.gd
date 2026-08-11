extends StaticBody3D

@export var mesh_instance : MeshInstance3D
@export var gate_open_close_timer : GateOpenCloseTimer

var mesh_material : StandardMaterial3D

func _ready() -> void:
  mesh_material = mesh_instance.material_override as StandardMaterial3D


func _on_input_event(_camera: Node, event: InputEvent, _event_position: Vector3, _normal: Vector3, _shape_idx: int) -> void:
  if event is InputEventScreenTouch:
    var screen_touch = event as InputEventScreenTouch
    if screen_touch.pressed:
      if gate_open_close_timer.latch:
        gate_open_close_timer.latch = false
        mesh_material.albedo_color = Color.GREEN
      else:
        gate_open_close_timer.latch = true
        mesh_material.albedo_color = Color.RED
