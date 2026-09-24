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

@export_group("Flight")
## Muzzle speed for a direct shot (m/s). A lobbed shot solves its own speed.
@export var speed: float = 80.0
## Multiplies world gravity for this projectile — the GPU copy and the drawn one alike.
## 0 flies dead straight; 1 drops like a hog would.
@export var gravity_scale: float = 0.0
## 0 fires straight at the target. Above 0, the shot is lobbed at this elevation (degrees
## above horizontal) with whatever speed lands it on the target — a mortar. Needs
## gravity_scale > 0; without gravity it falls back to a direct shot.
@export_range(0.0, 89.0) var launch_angle_deg: float = 0.0
## Random aim error: each shot leaves within a cone this many degrees wide either side.
@export_range(0.0, 30.0) var spread_deg: float = 0.0
## Random muzzle speed error, as a fraction (0.05 = ±5%). On a lobbed shot it scatters the
## range.
@export_range(0.0, 0.5) var speed_variance: float = 0.0
## Seconds between shots while the trigger is held. 0 fires every physics frame.
@export var fire_interval: float = 0.0

@export_group("Knockback")
@export var force: float = 80.0
## Leave zero to push along the projectile's direction of travel at impact.
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

@export_group("Explosion")
## Above 0, the projectile bursts where it lands — on a hog or the ground — with the same
## shockwave, damage falloff and panic as a dropped bomb, over this radius.
@export var explosion_radius: float = 0.0
@export var explosion_force: float = 0.0
@export var explosion_damage: float = 0.0

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
    "gravity_scale":  gravity_scale,
    "has_teleport":        has_teleport,
    "teleport_pos":        teleport_pos,
    "teleport_force_dir":  teleport_force_dir,
    "contagion":      contagion_type,
    "contagion_dur":  contagion_duration,
    "source_body":    source_body_index,
    "health_fraction": health_fraction,
  }
