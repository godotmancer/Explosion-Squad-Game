extends Label

@export var score_hit_color: Color = Color(5.0, 5.0, 0.0, 1.0)
@export var hogs_mesh_instances : SquadMultiMeshInstance3D

@onready var marker_2d: Marker2D = $Marker2D

var tween : Tween


func _ready() -> void:
  Global.score_hit.connect(_score_hit)


func _score_hit(marker: Marker2D) -> void:
  if marker == marker_2d:
    modulate = Color.WHITE
    if tween:
      tween.kill()
    tween = create_tween()
    tween.tween_property(self, "modulate", score_hit_color, 0.15)
    tween.tween_property(self, "modulate", Color.WHITE, 0.05)


func _physics_process(_delta: float) -> void:
  text = "%d hogs" % [
    hogs_mesh_instances.multimesh.visible_instance_count
  ]
