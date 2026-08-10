@icon("res://assets/ObstacleArea3D.svg")
extends Area3D
class_name ObstacleArea3D

# This class overrides the Area3D and disables any processing and monitoring
func _ready() -> void:
  set_process(false)
  set_physics_process(false)
