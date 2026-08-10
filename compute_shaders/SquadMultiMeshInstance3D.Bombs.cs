namespace ExplosionSquadGame.compute_shaders;

using System;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  private void DrainDeathFxQueue()
  {
    var spawned = 0;
    while (_deathFxQueue.Count > 0 && spawned < MaxDeathFxPerFrame)
    {
      var pos = _deathFxQueue.Dequeue();
      Node3D fx;
      if (_deathFxPool.TryDequeue(out var pooledFx))
      {
        fx = pooledFx;
      }
      else if (_deathFxTotalCreated < MAX_POOLED_DEATH_FX)
      {
        fx = DeathFxScene.Instantiate<Node3D>();
        fx.Set("is_pooled", true);
        fx.Connect("fx_finished", Callable.From<Node3D>(OnDeathFxFinished));
        GetTree().CurrentScene.AddChild(fx);
        _deathFxTotalCreated++;
      }
      else
      {
        continue;
      }

      fx.GlobalPosition = pos;
      fx.Call("play_fx");
      spawned++;
    }
  }

  private void OnDeathFxFinished(Node3D fx) => _deathFxPool.Enqueue(fx);

  private void OnHogDied(int index, float worldX, float worldZ, uint stateBits)
  {
    var position = new Vector3(worldX, YOffset, worldZ);

    if (DeathFxScene != null)
    {
      _deathFxQueue.Enqueue(position);
    }

    // Nudge nearby hogs away from the death position.
    // Damage = 0 so the GLSL skips the red flash and flee-origin writes —
    // this is a pure velocity push, not a full bomb effect.
    // Skip if bomb buffer is already full to avoid evicting real bombs.
    if (DeathFearForce > 0f && _activeBombs.Count < MAX_BOMBS)
    {
      _activeBombs.Add(
        new BombState
        {
          Pos = new Vector2(worldX, worldZ),
          Timer = DeathFearDuration,
          Duration = DeathFearDuration,
          Force = DeathFearForce,
          Radius = DeathFearRadius,
          Damage = 0f,
          DamageApplied = true, // nothing to apply
        }
      );
    }

    EmitSignal(SignalName.HogDied, index, position, stateBits);
  }

  private void DropBomb(Vector3 hit)
  {
    _activeBombs.Add(
      new BombState
      {
        Pos = new Vector2(hit.X, hit.Z),
        Timer = BombDuration,
        DamageApplied = false,
        Force = BombForce,
        Radius = BombRadius,
        Duration = BombDuration,
        Damage = BombDamage,
      }
    );
    _ = (DrawableGround?.CallDeferred("draw_explosion", hit));
  }

  private bool UpdateBombBuffer(float fdelta)
  {
    // Remove expired bombs
    for (var i = _activeBombs.Count - 1; i >= 0; i--)
    {
      if (_activeBombs[i].Timer <= 0)
      {
        _activeBombs.RemoveAt(i);
      }
    }

    // Clamp to max capacity
    while (_activeBombs.Count > MAX_BOMBS)
    {
      _activeBombs.RemoveAt(0);
    }

    // The shader only reads the first num_bombs entries (push constant), so
    // nothing needs uploading when no bombs are active — stale GPU data is inert.
    if (_activeBombs.Count == 0)
    {
      return false;
    }

    // Build GPU data into pre-allocated staging buffer (zero alloc)
    for (var i = 0; i < _activeBombs.Count; i++)
    {
      var bomb = _activeBombs[i];
      var bombT = bomb.Timer / bomb.Duration;
      var damage = 0f;
      if (!bomb.DamageApplied)
      {
        damage = bomb.Damage;
        bomb.DamageApplied = true;
      }

      var idx = i * BOMB_STRIDE;
      _bombStaging[idx + BOMB_POS_X] = bomb.Pos.X;
      _bombStaging[idx + BOMB_POS_Z] = bomb.Pos.Y;
      _bombStaging[idx + BOMB_FORCE] = bomb.Force * bombT;
      _bombStaging[idx + BOMB_RADIUS] = bomb.Radius;
      _bombStaging[idx + BOMB_DAMAGE] = damage;
      _bombStaging[idx + 5] = 0f; // explicit padding (_pad1.._pad3 in the GLSL struct)
      _bombStaging[idx + 6] = 0f;
      _bombStaging[idx + 7] = 0f;

      bomb.Timer -= fdelta;
      _activeBombs[i] = bomb;
    }

    // Upload only the active slice (zero alloc)
    var byteCount = (uint)(_activeBombs.Count * BOMB_STRIDE * sizeof(float));
    Buffer.BlockCopy(_bombStaging, 0, _bombBytes, 0, (int)byteCount);
    _ = _rd.BufferUpdate(_bombBuffer, 0, byteCount, _bombBytes);
    return false; // buffer never grows
  }
}
