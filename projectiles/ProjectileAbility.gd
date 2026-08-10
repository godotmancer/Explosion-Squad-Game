class_name ProjectileAbility
extends Resource

## Mirrors SquadMultiMeshInstance3D.ProjectileAbility (C# struct).
## Can be authored in the editor and saved as a .tres file.
## Pass to Projectile.launch() for visual playback, or call to_dict() to
## feed into ProjectilesSpawner for GPU-side collision/damage.

enum {
  PROJECTILE_CONTAGION_FIRE = 256,
  PROJECTILE_CONTAGION_POISON = 512,
  PROJECTILE_CONTAGION_ALCOHOL = 1024,
}

@export_group("Impact")
@export var radius: float = 0.4
@export var lifetime: float = 5.0
@export var damage: float = 30.0

@export_group("Knockback")
@export var force: float = 80.0
## Leave zero to use the impact direction automatically.
@export var force_dir: Vector3 = Vector3.ZERO

@export_group("Contagion")
@export var damage_per_second: float = 0.0
## Bitmask — Fire = 256, Poison = 512, Alcohol = 1024.
@export_flags(
  "Fire:%d" % PROJECTILE_CONTAGION_FIRE,
  "Poison:%d" % PROJECTILE_CONTAGION_POISON,
  "Alcohol:%d" % PROJECTILE_CONTAGION_ALCOHOL
  ) var contagion_type: int = 0
@export var contagion_duration: float = 3.0

@export_group("Teleport")
@export var has_teleport: bool = false
## World-space teleport destination. X/Z = horizontal position, Y = spawn height (0 = near ground).
@export var teleport_pos: Vector3 = Vector3.ZERO
## Post-teleport launch velocity as direction × magnitude (like SpawnHog initialVelocity).
## When non-zero, overrides force/force_dir for the teleport exit direction.
@export var teleport_force_dir: Vector3 = Vector3.ZERO

@export_group("Hog Projectile")
## Set to the body index of the hog being thrown. -1 = not a hog.
@export var source_body_index: int = -1
## Fraction of source body health dealt as damage (only when source_body_index >= 0).
@export var health_fraction: float = 1.0


## Returns a Dictionary compatible with ProjectilesSpawner.spawn_projectile_toward().
func to_dict() -> Dictionary:
  return {
    "radius":         radius,
    "lifetime":       lifetime,
    "damage":         damage,
    "dps":            damage_per_second,
    "force":          force,
    "force_dir":      force_dir,
    "has_teleport":        has_teleport,
    "teleport_pos":        teleport_pos,
    "teleport_force_dir":  teleport_force_dir,
    "contagion":      contagion_type,
    "contagion_dur":  contagion_duration,
    "source_body":    source_body_index,
    "health_fraction": health_fraction,
  }
