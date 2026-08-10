namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  private void WriteProjectilePush(float deltaTime, float time)
  {
    var floats = MemoryMarshal.Cast<byte, float>(_projPushBytes.AsSpan());
    var ints = MemoryMarshal.Cast<byte, int>(_projPushBytes.AsSpan());
    var uints = MemoryMarshal.Cast<byte, uint>(_projPushBytes.AsSpan());
    floats[PROJ_PUSH_DELTA_TIME] = deltaTime;
    ints[PROJ_PUSH_NUM_PROJ] = MAX_PROJECTILES;
    ints[PROJ_PUSH_NUM_BODIES] = NumBodies;
    floats[PROJ_PUSH_GRAVITY] = Gravity;
    floats[PROJ_PUSH_Y_OFFSET] = YOffset;
    uints[PROJ_PUSH_FRAME_PARITY] = _hashFrameParity;
    floats[PROJ_PUSH_TIME] = time;
    floats[7] = 0f; // pad
  }

  private void UpdateProjectileLifetimes(float fdelta)
  {
    if (_projLifetimes == null)
    {
      return;
    }

    // Reclaim slots the GPU killed early (ground hit or body collision) so the pool
    // never exhausts under sustained fire. Also fires per-slot hit callbacks.
    // Throttled to every 2 frames — BufferGetData stalls on the GPU readback.
    _projReadbackCounter = (_projReadbackCounter + 1) % 2;
    if (_projReadbackCounter == 0 && AnyProjectileActiveOnGpu())
    {
      ReclaimGpuKilledProjectiles();
    }

    // C#-side lifetime countdown — reclaims slots whose grace period ran out.
    for (var i = 0; i < MAX_PROJECTILES; i++)
    {
      if (_projLifetimes[i] <= 0f)
      {
        continue;
      }

      _projLifetimes[i] -= fdelta;
      if (_projLifetimes[i] > 0f)
      {
        continue;
      }

      _projHitCallbacks[i] = null;
      // Safety net: clear the alive flag on the GPU. Normally the GPU has already
      // killed the slot itself (its lifetime runs ~PROJ_LIFETIME_GRACE shorter),
      // but this guarantees a reclaimed slot can never keep colliding.
      var off = (uint)((i * PROJ_STRIDE * sizeof(float)) + (PROJ_FLAGS * sizeof(float)));
      _ = _rd.BufferUpdate(_projBuffer, off, sizeof(float), _zeroFlagBytes);
      _projFreeSlots.Enqueue(i);
    }
  }

  /// <summary>True if any slot is tracked by C# and already uploaded to the GPU.</summary>
  private bool AnyProjectileActiveOnGpu()
  {
    for (var i = 0; i < MAX_PROJECTILES; i++)
    {
      if (_projLifetimes[i] > 0f && !_projPendingUpload[i])
      {
        return true;
      }
    }

    return false;
  }

  /// <summary>
  /// Reads the projectile buffer back and reclaims every slot whose GPU particle
  /// died early (ground or body hit), firing its registered hit callback.
  /// Without this, ground-killed projectiles would hold their slots for the full
  /// lifetime, exhausting the pool under sustained spawning.
  /// </summary>
  private void ReclaimGpuKilledProjectiles()
  {
    var raw = _rd.BufferGetData(_projBuffer);
    if (raw == null || raw.Length != MAX_PROJECTILES * PROJ_STRIDE * sizeof(float))
    {
      return;
    }

    var floats = MemoryMarshal.Cast<byte, float>(raw.AsSpan());
    for (var i = 0; i < MAX_PROJECTILES; i++)
    {
      // Skip untracked or not-yet-uploaded slots. Slots already inside the grace
      // window are left for the lifetime countdown to reclaim naturally.
      if (_projLifetimes[i] <= PROJ_LIFETIME_GRACE || _projPendingUpload[i])
      {
        continue;
      }

      var flagBits = BitConverter.SingleToUInt32Bits(floats[(i * PROJ_STRIDE) + PROJ_FLAGS]);
      if ((flagBits & PROJ_FLAG_ALIVE) != 0u)
      {
        continue; // still flying
      }

      var hitPos = new Vector3(
        floats[(i * PROJ_STRIDE) + PROJ_POS_X],
        floats[(i * PROJ_STRIDE) + PROJ_POS_Y],
        floats[(i * PROJ_STRIDE) + PROJ_POS_Z]
      );

      // Fire callback if registered (ProjectileBase.kill() guards against double-calls)
      var cb = _projHitCallbacks[i];
      _projHitCallbacks[i] = null;
      cb?.Invoke(hitPos);

      // Reclaim immediately — zero the lifetime AND enqueue, since the countdown
      // loop skips slots already at <= 0. The GPU cleared the alive flag itself,
      // so no buffer write is needed here.
      _projLifetimes[i] = 0f;
      _projFreeSlots.Enqueue(i);
    }
  }

  /// <summary>
  /// Registers a callback that fires once if the GPU projectile at <paramref name="slot"/>
  /// is killed by a body collision before its natural lifetime expires.
  /// The callback receives the world-space hit position.
  /// </summary>
  public void RegisterProjectileHitCallback(int slot, Action<Vector3> callback)
  {
    if (slot is >= 0 and < MAX_PROJECTILES)
    {
      _projHitCallbacks[slot] = callback;
    }
  }

  private void UploadPendingProjectiles()
  {
    while (_pendingProjSpawns.TryDequeue(out var slot))
    {
      Buffer.BlockCopy(
        _projAllStagingFloats,
        slot * PROJ_STRIDE * sizeof(float),
        _projSlotUploadBytes,
        0,
        _projSlotUploadBytes.Length
      );
      var off = (uint)(slot * PROJ_STRIDE * sizeof(float));
      _ = _rd.BufferUpdate(
        _projBuffer,
        off,
        (uint)_projSlotUploadBytes.Length,
        _projSlotUploadBytes
      );
      _projPendingUpload[slot] = false;
    }
  }

  /// <summary>
  /// Spawns a GPU-driven projectile. Returns the slot index (≥ 0) on success,
  /// or -1 if the pool is exhausted. Pass the slot to
  /// <see cref="RegisterProjectileHitCallback"/> to receive a collision notification.
  /// </summary>
  public int SpawnProjectile(Vector3 position, Vector3 velocity, ProjectileAbility ability)
  {
    if (!_projFreeSlots.TryDequeue(out var slot))
    {
      return -1;
    }

    // C# lifetime with extra grace period so the slot outlives the GPU particle
    _projLifetimes[slot] = ability.Lifetime + PROJ_LIFETIME_GRACE;
    _projPendingUpload[slot] = true;

    var b = slot * PROJ_STRIDE;
    _projAllStagingFloats[b + PROJ_POS_X] = position.X;
    _projAllStagingFloats[b + PROJ_POS_Y] = position.Y;
    _projAllStagingFloats[b + PROJ_POS_Z] = position.Z;
    _projAllStagingFloats[b + PROJ_RADIUS] = ability.Radius > 0f ? ability.Radius : 0.4f;
    _projAllStagingFloats[b + PROJ_VEL_X] = velocity.X;
    _projAllStagingFloats[b + PROJ_VEL_Y] = velocity.Y;
    _projAllStagingFloats[b + PROJ_VEL_Z] = velocity.Z;
    _projAllStagingFloats[b + PROJ_DAMAGE] = ability.Damage;
    _projAllStagingFloats[b + PROJ_DPS] = ability.DamagePerSecond;
    _projAllStagingFloats[b + PROJ_FORCE] = ability.Force;
    _projAllStagingFloats[b + PROJ_FORCE_DIR_X] = ability.ForceDir.X;
    _projAllStagingFloats[b + PROJ_FORCE_DIR_Y] = ability.ForceDir.Y;
    _projAllStagingFloats[b + PROJ_FORCE_DIR_Z] = ability.ForceDir.Z;
    _projAllStagingFloats[b + PROJ_LIFETIME] = ability.Lifetime;
    _projAllStagingFloats[b + PROJ_TELEPORT_X] = ability.TeleportXZ.X;
    _projAllStagingFloats[b + PROJ_TELEPORT_Z] = ability.TeleportXZ.Y;
    _projAllStagingFloats[b + PROJ_TELEPORT_Y] = ability.TeleportY;
    _projAllStagingFloats[b + PROJ_CONTAGION] = BitConverter.UInt32BitsToSingle(
      ability.ContagionType
    );
    _projAllStagingFloats[b + PROJ_CONTAGION_DUR] = ability.ContagionDuration;

    var flags = PROJ_FLAG_ALIVE;
    if (ability.HasTeleport)
    {
      flags |= PROJ_FLAG_HAS_TELE;
    }

    if (ability.SourceBodyIndex >= 0)
    {
      flags |= PROJ_FLAG_IS_HOG;
    }

    _projAllStagingFloats[b + PROJ_FLAGS] = BitConverter.UInt32BitsToSingle(flags);
    _projAllStagingFloats[b + PROJ_SOURCE] =
      ability.SourceBodyIndex >= 0 ? ability.SourceBodyIndex : -1f;

    _pendingProjSpawns.Enqueue(slot);
    return slot;
  }
}
