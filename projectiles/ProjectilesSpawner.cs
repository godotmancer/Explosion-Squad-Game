namespace ExplosionSquadGame.projectiles;

using ExplosionSquadGame.compute_shaders;
using Godot;

/// <summary>
/// GDScript-callable facade for spawning GPU projectiles.
/// Wire this node to a <see cref="SquadMultiMeshInstance3D"/> in the editor.
/// </summary>
[GlobalClass]
public partial class ProjectilesSpawner : Node
{
  [Export]
  public SquadMultiMeshInstance3D Squad { get; set; }

  [Export]
  public Camera3D Camera { get; set; }

  // ---- Defaults exposed for quick editor tweaking ----
  [ExportGroup("Projectile Defaults")]
  [Export]
  public float DefaultRadius { get; set; } = 0.4f;

  [Export]
  public float DefaultLifetime { get; set; } = 5.0f;

  [Export]
  public float DefaultDamage { get; set; } = 30.0f;

  [Export]
  public float DefaultForce { get; set; } = 80.0f;

  [Export]
  public float DirectionLength { get; set; } = 30.0f;

  // -------------------------------------------------------------------------
  // GDScript-callable: spawn a projectile aimed from `from` toward `target`.
  //
  // ability_dict keys (all optional, falling back to defaults):
  //   radius          float
  //   lifetime        float
  //   damage          float  — flat damage on hit
  //   dps             float  — damage-per-second while contagion active
  //   force           float  — knockback magnitude
  //   force_dir       Vector3 — knockback direction (normalised); if zero, uses impact normal
  //   has_teleport         bool
  //   teleport_pos         Vector3 — world-space destination (X/Z position, Y = spawn height)
  //   teleport_force_dir   Vector3 — post-teleport launch velocity (direction × magnitude);
  //                                  overrides force/force_dir when has_teleport and non-zero
  //   contagion       int    — bitmask: 256=fire, 512=poison, 1024=alcohol
  //   contagion_dur   float
  //   source_body     int    — body index of the hog being thrown (-1 = none)
  //   health_fraction float  — if source_body ≥ 0: fraction of source health to deal as damage
  // -------------------------------------------------------------------------
  /// <summary>Returns the GPU slot index (≥ 0) or -1 on failure.</summary>
  public int SpawnProjectileToward(Vector3 from, Vector3 target, Variant abilityVar = default)
  {
    if (Squad == null)
    {
      return -1;
    }

    var dir = (target - from).Normalized();
    return SpawnProjectileWithVelocity(from, dir * DirectionLength, abilityVar);
  }

  /// <summary>Returns the GPU slot index (≥ 0) or -1 on failure.</summary>
  public int SpawnProjectileWithVelocity(
    Vector3 position,
    Vector3 velocity,
    Variant abilityVar = default
  )
  {
    if (Squad == null)
    {
      return -1;
    }

    var ability = ParseAbility(abilityVar, velocity.Normalized());
    return Squad.SpawnProjectile(position, velocity, ability);
  }

  /// <summary>
  /// Registers a GDScript Callable that is invoked once if the GPU projectile
  /// at <paramref name="slot"/> is killed by a body collision before its natural
  /// lifetime expires. The callable receives the world-space hit position (Vector3).
  /// </summary>
  public void RegisterProjectileHitCallback(int slot, Callable hitCallback)
  {
    if (Squad == null || slot < 0)
    {
      return;
    }

    Squad.RegisterProjectileHitCallback(
      slot,
      pos =>
      {
        var target = hitCallback.Target;
        if (target != null && !IsInstanceValid(target))
        {
          return;
        }

        hitCallback.Call(pos);
      }
    );
  }

  // -------------------------------------------------------------------------
  // Convenience: shoot a projectile from a 2-D screen position (ray cast to
  // a target hog — requires the Camera export to be set).
  // -------------------------------------------------------------------------
  /// <summary>Returns the GPU slot index (≥ 0) or -1 on failure.</summary>
  public int SpawnProjectileFromScreen(Vector2 screenPos, Variant abilityVar = default)
  {
    if (Camera == null || Squad == null)
    {
      return -1;
    }

    var origin = Camera.ProjectRayOrigin(screenPos);
    var dir = Camera.ProjectRayNormal(screenPos);

    if (Mathf.Abs(dir.Y) < 0.001f)
    {
      return -1;
    }

    var t = (Squad.YOffset + 10f - origin.Y) / dir.Y;
    if (t < 0)
    {
      return -1;
    }

    var spawnPos = origin + (dir * t);
    var targetPos = origin + (dir * (t + DirectionLength));
    return SpawnProjectileToward(spawnPos, targetPos, abilityVar);
  }

  // -------------------------------------------------------------------------
  // Internal helpers
  // -------------------------------------------------------------------------
  private SquadMultiMeshInstance3D.ProjectileAbility ParseAbility(
    Variant abilityVar,
    Vector3 defaultForceDir
  )
  {
    var obj = abilityVar.As<GodotObject>();

    var radius = GetObj(obj, "radius", DefaultRadius);
    var lifetime = GetObj(obj, "lifetime", DefaultLifetime);
    var damage = GetObj(obj, "damage", DefaultDamage);
    var dps = GetObj(obj, "damage_per_second", 0f);
    var force = GetObj(obj, "force", DefaultForce);

    var forceDir = GetV3Obj(obj, "force_dir", defaultForceDir);
    if (forceDir.LengthSquared() < 0.0001f)
    {
      forceDir = defaultForceDir;
    }

    var hasTele = GetBoolObj(obj, "has_teleport", false);
    var telePos = GetV3Obj(obj, "teleport_pos", Vector3.Zero);
    var teleForceDir = GetV3Obj(obj, "teleport_force_dir", Vector3.Zero);

    // Dedicated teleport launch vector overrides knockback when has_teleport is set
    if (hasTele && teleForceDir.LengthSquared() > 0.0001f)
    {
      force = teleForceDir.Length();
      forceDir = teleForceDir.Normalized();
    }

    var contagion = (uint)GetObj(obj, "contagion_type", 0);
    var contDur = GetObj(obj, "contagion_duration", 3f);
    var srcBody = GetObj(obj, "source_body_index", -1);
    var hFrac = GetObj(obj, "health_fraction", 1f);

    return new SquadMultiMeshInstance3D.ProjectileAbility
    {
      Radius = radius,
      Lifetime = lifetime,
      Damage = srcBody >= 0 ? hFrac : damage,
      DamagePerSecond = dps,
      Force = force,
      ForceDir = forceDir.Normalized(),
      HasTeleport = hasTele,
      TeleportXZ = new Vector2(telePos.X, telePos.Z),
      TeleportY = telePos.Y,
      ContagionType = contagion,
      ContagionDuration = contDur,
      SourceBodyIndex = srcBody,
    };
  }

  private static T GetObj<[MustBeVariant] T>(GodotObject obj, string key, T fallback)
  {
    if (obj != null)
    {
      var v = obj.Get(key);
      if (v.VariantType != Variant.Type.Nil)
      {
        return v.As<T>();
      }
    }
    return fallback;
  }

  private static bool GetBoolObj(GodotObject obj, string key, bool fallback)
  {
    if (obj != null)
    {
      var v = obj.Get(key);
      if (v.VariantType != Variant.Type.Nil)
      {
        return v.As<bool>();
      }
    }
    return fallback;
  }

  private static Vector3 GetV3Obj(GodotObject obj, string key, Vector3 fallback)
  {
    if (obj != null)
    {
      var v = obj.Get(key);
      if (v.VariantType != Variant.Type.Nil)
      {
        return v.As<Vector3>();
      }
    }
    return fallback;
  }
}
