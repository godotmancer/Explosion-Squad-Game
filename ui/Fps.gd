extends Label

@export var hogs_mesh_instances : SquadMultiMeshInstance3D

func _physics_process(_delta: float) -> void:
  #if Engine.get_frames_drawn() % 2 == 0:
  text = "%d fps\n%d projectiles\n%d total projectiles" % [
    Engine.get_frames_per_second(),
    get_tree().get_nodes_in_group("projectile").size(),
    Global.total_projectiles
  ]
