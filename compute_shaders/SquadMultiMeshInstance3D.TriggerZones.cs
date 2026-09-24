namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Called after the GPU sync and the death loop each physics frame.
  /// Tests every alive hog against each trigger zone using transform-buffer
  /// positions we already have in <paramref name="gpuFloats"/>, in one pass over the hogs.
  ///
  /// Effects fire only on the enter transition (first frame inside), found by comparing the
  /// hog's zones this pass with <see cref="_zoneMasks"/> from the last.
  /// Multiply and Add additionally use <see cref="_triggeredPairs"/> as a
  /// one-shot skip: clones spawned inside a thick zone are marked so the enter
  /// event they are born into is swallowed (the mark is consumed by that enter).
  /// This prevents exponential growth when newly-spawned bodies are still inside
  /// the zone on the next frame, while a genuine exit + re-entry triggers again.
  /// Damage re-triggers on every re-entry (no marks needed).
  /// </summary>
  private void ProcessTriggerZones(ReadOnlySpan<float> gpuFloats)
  {
    // Snapshot the list at entry. _triggerZones can be nulled mid-frame by
    // InvalidateObstacleCache (e.g. if an obstacle visibility change fires during
    // signal emission), so we capture a local reference and bail if it's gone.
    var zones = _triggerZones;
    if (zones == null)
    {
      return;
    }

    if (!ReferenceEquals(zones, _zoneMasksZones))
    {
      Array.Clear(_zoneMasks);
      _zoneMasksZones = zones;
      if (zones.Count > MAX_TRIGGER_ZONES)
      {
        GD.PushWarning(
          $"{zones.Count} trigger zones; only the first {MAX_TRIGGER_ZONES} are tested."
        );
      }
    }

    // Resolve each zone's footprint once. A zone that is disabled or hidden this pass is left
    // out of activeMask, and its bits carry over unchanged: it neither fires nor forgets who
    // was inside, so re-enabling it does not re-trigger hogs that never left.
    var zoneCount = Math.Min(zones.Count, MAX_TRIGGER_ZONES);
    var activeMask = 0UL;
    for (var zoneIdx = 0; zoneIdx < zoneCount; zoneIdx++)
    {
      var shape = zones[zoneIdx].Shape;
      if (
        !IsInstanceValid(shape)
        || shape.Shape == null
        || shape.Disabled
        || !shape.IsVisibleInTree()
      )
      {
        continue;
      }

      _triggerBounds[zoneIdx] = GetTriggerBounds(shape);
      activeMask |= 1UL << zoneIdx;
    }

    // The bodies in this readback — not NumBodies, which counts hogs spawned since the GPU tick
    // it came from (they have no row in it yet), and which SpawnHogs below grows further.
    var bodyCount = gpuFloats.Length / INSTANCE_STRIDE;
    _pendingTriggerSpawns.Clear();

    if (activeMask != 0)
    {
      // Locals rather than fields: the call in the loop would otherwise make the JIT reload
      // both arrays, and bounds-check them, on every hog.
      var maskArray = _zoneMasks;
      var masks = maskArray.AsSpan(0, bodyCount);
      ReadOnlySpan<TriggerBounds> bounds = _triggerBounds.AsSpan(0, zoneCount);
      for (var i = 0; i < masks.Length; i++)
      {
        var src = i * INSTANCE_STRIDE;
        var stateBits = BitConverter.SingleToUInt32Bits(gpuFloats[src + INST_STATE]);
        if ((stateBits & STATE_DEAD) != 0)
        {
          continue;
        }

        var hogXZ = new Vector2(gpuFloats[src + INST_ORIGIN_X], gpuFloats[src + INST_ORIGIN_Z]);
        var prev = masks[i];
        var inside = prev & ~activeMask;
        var pending = activeMask;
        while (pending != 0)
        {
          var zoneIdx = System.Numerics.BitOperations.TrailingZeroCount(pending);
          pending &= pending - 1;
          ref readonly var b = ref bounds[zoneIdx];
          if (hogXZ.X < b.MinX || hogXZ.X > b.MaxX || hogXZ.Y < b.MinZ || hogXZ.Y > b.MaxZ)
          {
            continue;
          }

          if (
            b.IsCircle
              ? IsInsideCircle(hogXZ, b.Center, b.HalfExt.X)
              : IsInsideOBB(hogXZ, b.Center, b.HalfExt, b.Axis)
          )
          {
            inside |= 1UL << zoneIdx;
          }
        }

        masks[i] = inside;
        var entered = inside & ~prev;
        if (entered == 0)
        {
          continue;
        }

        do
        {
          var zoneIdx = System.Numerics.BitOperations.TrailingZeroCount(entered);
          entered &= entered - 1;
          OnZoneEntered(i, zoneIdx, zones[zoneIdx], hogXZ);
        } while (entered != 0);

        // A HogZoneTriggered handler that spawned hogs could have grown _zoneMasks into a new
        // array (the resize copies what was written so far); keep writing to the live one.
        if (!ReferenceEquals(maskArray, _zoneMasks))
        {
          maskArray = _zoneMasks;
          masks = maskArray.AsSpan(0, bodyCount);
        }
      }
    }

    FlushZoneDamage();

    // Spawn deferred hogs and immediately mark their indices as immune to
    // the originating zone so they cannot re-trigger it next frame.
    foreach (var (zoneIdx, pos, count) in _pendingTriggerSpawns)
    {
      var firstNew = NumBodies;
      var baseDir = pos.DirectionTo(TargetMarker.GlobalPosition);
      for (var mi = 0; mi < count; mi++)
      {
        var forceDir = baseDir.Rotated(
          Vector3.Up,
          _rndGen.RandfRange(-Mathf.Pi / 4f, Mathf.Pi / 4f)
        );
        SpawnHogs(
          1,
          pos,
          new Vector3(
            forceDir.X * _rndGen.RandfRange(5f, 15f),
            _rndGen.RandfRange(5f, 10f),
            forceDir.Z * _rndGen.RandfRange(5f, 15f)
          )
        );
      }
      for (var ni = firstNew; ni < NumBodies; ni++)
      {
        _triggeredPairs.Add(TriggerKey(ni, zoneIdx));
      }
    }
  }

  /// <summary>Applies <paramref name="zone"/>'s effect to hog <paramref name="i"/>, which has
  /// just entered it.</summary>
  private void OnZoneEntered(int i, int zoneIdx, TriggerZone zone, Vector2 hogXZ)
  {
    var hogPos = new Vector3(hogXZ.X, YOffset, hogXZ.Y);
    var emitSignal = false;

    switch (zone.Effect)
    {
      case TriggerEffect.Damage:
        // Damage re-fires on every re-entry; no permanent immunity needed.
        QueueZoneDamage(i, zone.Value);
        emitSignal = true;
        break;

      case TriggerEffect.Multiply:
        // One-shot skip mark (consumed here): swallows the enter event a
        // clone is born into; a later genuine re-entry triggers normally.
        if (_triggeredPairs.Remove(TriggerKey(i, zoneIdx)))
        {
          break;
        }

        var cloneCount = Math.Max(0, (int)zone.Value - 1);
        if (cloneCount > 0)
        {
          _pendingTriggerSpawns.Add((zoneIdx, hogPos, cloneCount));
        }

        emitSignal = true;
        break;

      case TriggerEffect.Add:
        // One-shot skip mark (consumed here): swallows the enter event a
        // spawned hog is born into; a later re-entry triggers normally.
        if (_triggeredPairs.Remove(TriggerKey(i, zoneIdx)))
        {
          break;
        }

        var addCount = (int)zone.Value;
        if (addCount > 0)
        {
          _pendingTriggerSpawns.Add(
            (zoneIdx, zone.Shape.GlobalPosition with { Y = YOffset }, addCount)
          );
        }
        emitSignal = true;
        break;
      default:
        break;
    }

    if (ShowHogs && emitSignal)
    {
      EmitSignal(SignalName.HogZoneTriggered, i, hogPos, zone.Shape, (int)zone.Effect);
    }
  }

  // Byte layout of GpuBody, resolved once (Marshal reflection is not free per call).
  private static readonly int GpuBodySize = Marshal.SizeOf<GpuBody>();
  private static readonly int DamageAccumOffset = Marshal
    .OffsetOf<GpuBody>(nameof(GpuBody.DamageAccum))
    .ToInt32();

  // Reused 4-byte scratch for encoding the damage value (zero per-call allocation).
  private readonly byte[] _damageEncodeBytes = new byte[sizeof(uint)];

  /// <summary>
  /// Adds zone damage for a hog to this pass's running total. Nothing is written until
  /// <see cref="FlushZoneDamage"/>, so a hog entering several damage zones in one frame takes
  /// all of them.
  /// </summary>
  private void QueueZoneDamage(int index, float damage) =>
    CollectionsMarshal.GetValueRefOrAddDefault(_pendingZoneDamage, index, out _) += damage;

  /// <summary>Writes each queued hog's summed zone damage, once per hog.</summary>
  private void FlushZoneDamage()
  {
    foreach (var (index, damage) in _pendingZoneDamage)
    {
      DamageHogViaBuffer(index, damage);
    }

    _pendingZoneDamage.Clear();
  }

  /// <summary>
  /// Applies flat damage to a hog by writing to its <c>damage_accum</c> field
  /// in the physics buffer. The GPU physics shader reads and clears this accumulator
  /// each frame (DAMAGE_SCALE = 256), applying the result to health.
  /// The write is queued and takes effect on the next physics frame. It REPLACES the
  /// word rather than adding to it — fine because physics zeroes it every frame and this
  /// lands before the projectile pass adds its hits — so call it at most once per hog per
  /// frame; zone damage goes through <see cref="QueueZoneDamage"/> for exactly that reason.
  /// </summary>
  private void DamageHogViaBuffer(int index, float damage)
  {
    var damageAccumOff = (uint)((index * GpuBodySize) + DamageAccumOffset);
    // damage_accum is a uint encoded as damage × 256 (matching DAMAGE_SCALE in the shader).
    var encoded = (uint)(damage * 256.0f);
    _ = BitConverter.TryWriteBytes(_damageEncodeBytes, encoded);
    EnqueueGpuWrite(GpuTarget.Physics, damageAccumOff, _damageEncodeBytes);
  }

  private static long TriggerKey(int hogIndex, int zoneIndex) =>
    ((long)zoneIndex << 32) | (uint)hogIndex;

  private static TriggerBounds GetTriggerBounds(CollisionShape3D cs)
  {
    var xform = cs.GlobalTransform;
    var center = new Vector2(xform.Origin.X, xform.Origin.Z);
    var yRot = xform.Basis.GetEuler().Y;
    var axis = new Vector2(Mathf.Cos(yRot), -Mathf.Sin(yRot));

    var (halfExt, isCircle) = cs.Shape switch
    {
      SphereShape3D s => (new Vector2(s.Radius, s.Radius), true),
      CylinderShape3D c => (new Vector2(c.Radius, c.Radius), true),
      BoxShape3D b => (new Vector2(b.Size.X * 0.5f, b.Size.Z * 0.5f), false),
      _ => (Vector2.Zero, false),
    };

    // World-aligned box around the shape: the radius for a circle, the rotated half extents
    // (projected onto X and Z) for an OBB.
    var reach = isCircle
      ? halfExt
      : new Vector2(
        (Mathf.Abs(axis.X) * halfExt.X) + (Mathf.Abs(axis.Y) * halfExt.Y),
        (Mathf.Abs(axis.Y) * halfExt.X) + (Mathf.Abs(axis.X) * halfExt.Y)
      );

    return new TriggerBounds
    {
      Center = center,
      HalfExt = halfExt,
      Axis = axis,
      IsCircle = isCircle,
      MinX = center.X - reach.X,
      MaxX = center.X + reach.X,
      MinZ = center.Y - reach.Y,
      MaxZ = center.Y + reach.Y,
    };
  }

  private static bool IsInsideCircle(Vector2 point, Vector2 center, float radius) =>
    point.DistanceSquaredTo(center) <= radius * radius;

  private static bool IsInsideOBB(Vector2 point, Vector2 center, Vector2 halfExt, Vector2 axis)
  {
    var d = point - center;
    var localX = d.Dot(axis);
    var localZ = d.Dot(new Vector2(-axis.Y, axis.X)); // perpendicular to axis in XZ plane
    return Mathf.Abs(localX) <= halfExt.X && Mathf.Abs(localZ) <= halfExt.Y;
  }

  private static void ScanForTriggers(Node node, List<TriggerZone> results)
  {
    if (node is CollisionShape3D { Shape: not null } cs)
    {
      if (cs.HasMeta("damage"))
      {
        results.Add(
          new TriggerZone
          {
            Shape = cs,
            Effect = TriggerEffect.Damage,
            Value = cs.GetMeta("damage").AsSingle(),
          }
        );
      }
      else if (cs.HasMeta("multiply"))
      {
        results.Add(
          new TriggerZone
          {
            Shape = cs,
            Effect = TriggerEffect.Multiply,
            Value = cs.GetMeta("multiply").AsSingle(),
          }
        );
      }
      else if (cs.HasMeta("add"))
      {
        results.Add(
          new TriggerZone
          {
            Shape = cs,
            Effect = TriggerEffect.Add,
            Value = cs.GetMeta("add").AsSingle(),
          }
        );
      }
    }

    foreach (var child in node.GetChildren())
    {
      ScanForTriggers(child, results);
    }
  }
}
