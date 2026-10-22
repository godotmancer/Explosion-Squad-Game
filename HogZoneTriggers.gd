extends Node

@export var hogs_mesh_instances: SquadMultiMeshInstance3D

func _ready() -> void:
  hogs_mesh_instances.connect("HogZoneTriggered", _on_hog_zone_triggered)

# Handler — connect with CONNECT_DEFERRED if doing heavy visual work
func _on_hog_zone_triggered(
  hog_index: int,
  position: Vector3,
  zone: CollisionShape3D,
  effect: int
  ) -> void:
  var zone_gate_trigger := zone.get_parent().get_node_or_null("GateTrigger") as GateTrigger
  if zone_gate_trigger:
    # With the crowd hidden the gate still counts down and closes, without its flash and
    # announcement.
    zone_gate_trigger.trigger(hog_index, position, zone, effect, hogs_mesh_instances.ShowHogs)
