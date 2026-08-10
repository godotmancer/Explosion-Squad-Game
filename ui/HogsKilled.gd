extends Label

@export var score_hit_color: Color = Color(5.0, 0.0, 0.0, 1.0)
@export var hogs_mesh_instances : SquadMultiMeshInstance3D

@onready var marker_2d: Marker2D = $Marker2D

var dead_hogs := 0
var tween : Tween

func _ready() -> void:
  hogs_mesh_instances.connect("HogDied", _on_hog_died)
  Global.score_hit.connect(_score_hit)

func _on_hog_died(_index: int, _pos: Vector3, _stateBits: int) -> void:
  dead_hogs += 1

func _score_hit(marker: Marker2D) -> void:
  if marker == marker_2d:
    modulate = Color.WHITE
    if tween:
      tween.kill()
    tween = create_tween()
    tween.tween_property(self, "modulate", score_hit_color, 0.15)
    tween.tween_property(self, "modulate", Color.WHITE, 0.05)


func _physics_process(_delta: float) -> void:
  #if Engine.get_frames_drawn() % 2 == 0:
  text = "%d killed" % [
    dead_hogs
  ]
