extends Node

@export var hogs_mesh_instances: SquadMultiMeshInstance3D

func _ready() -> void:
  hogs_mesh_instances.connect("ZoneTriggered", _on_zone_triggered)

# Once per zone per tick, with how many hogs entered it. Connect with CONNECT_DEFERRED if
# doing heavy visual work.
func _on_zone_triggered(
  zone: CollisionShape3D,
  effect: int,
  count: int,
  position: Vector3
  ) -> void:
  var zone_gate_trigger := zone.get_parent().get_node_or_null("GateTrigger") as GateTrigger
  if zone_gate_trigger:
    # With the crowd hidden the gate still counts down and closes, without its flash and
    # announcement.
    zone_gate_trigger.trigger(count, position, zone, effect, hogs_mesh_instances.ShowHogs)
