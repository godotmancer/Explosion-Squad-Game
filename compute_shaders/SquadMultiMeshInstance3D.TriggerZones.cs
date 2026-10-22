namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using System.Runtime.CompilerServices;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Readies the trigger zones for this tick's <see cref="ReadbackPass"/>, which tests every
  /// live hog against them through <see cref="TestTriggerZones"/>; <see cref="EndTriggerZonePass"/>
  /// then applies and reports what it found. Returns the zones to test, one bit each.
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
  private ulong BeginTriggerZonePass()
  {
    _pendingTriggerSpawns.Clear();

    // Snapshot the list at entry. _triggerZones can be nulled by InvalidateObstacleCache (an
    // obstacle visibility change); the pass keeps working on the list it started with.
    var zones = _triggerZones;
    if (zones is not { Count: > 0 })
    {
      return 0;
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

    return activeMask;
  }

  /// <summary>
  /// Tests live hog <paramref name="i"/>, at <paramref name="hogXZ"/>, against the
  /// <paramref name="activeMask"/> zones, updates its occupancy <paramref name="mask"/>, and
  /// applies an effect for every zone it has just entered.
  /// </summary>
  [MethodImpl(MethodImplOptions.AggressiveInlining)]
  private void TestTriggerZones(int i, Vector2 hogXZ, ulong activeMask, ref ulong mask)
  {
    ReadOnlySpan<TriggerBounds> bounds = _triggerBounds;
    var prev = mask;
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

    mask = inside;
    var entered = inside & ~prev;
    while (entered != 0)
    {
      var zoneIdx = System.Numerics.BitOperations.TrailingZeroCount(entered);
      entered &= entered - 1;
      OnZoneEntered(i, zoneIdx, _zoneMasksZones[zoneIdx], hogXZ);
    }
  }

  /// <summary>
  /// Applies what the pass found: writes the summed zone damage, spawns the Multiply/Add hogs
  /// (marked immune to the zone that made them, so they cannot re-trigger it next frame), and
  /// emits one <c>ZoneTriggered</c> per zone that hogs entered.
  /// </summary>
  private void EndTriggerZonePass()
  {
    FlushZoneDamage();

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
        // One hog per call, each with its own velocity. The body writes land back to back,
        // so the GPU queue merges them into one upload.
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

    var zones = _zoneMasksZones;
    if (zones == null)
    {
      return;
    }

    var zoneCount = Math.Min(zones.Count, MAX_TRIGGER_ZONES);
    for (var zoneIdx = 0; zoneIdx < zoneCount; zoneIdx++)
    {
      var count = _zoneTriggerCounts[zoneIdx];
      if (count == 0)
      {
        continue;
      }

      _zoneTriggerCounts[zoneIdx] = 0;
      var zone = zones[zoneIdx];
      EmitSignal(
        SignalName.ZoneTriggered,
        zone.Shape,
        (int)zone.Effect,
        count,
        _zoneTriggerPositions[zoneIdx]
      );
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

    // Counted, not emitted: EndTriggerZonePass reports each zone once per tick. Not gated on
    // ShowHogs: handlers keep gameplay state (a gate counts its triggers down and closes).
    if (emitSignal)
    {
      _zoneTriggerCounts[zoneIdx]++;
      _zoneTriggerPositions[zoneIdx] = hogPos;
    }
  }

  // Byte layout of GpuBody, resolved once (Marshal reflection is not free per call).
  private static readonly int GpuBodySize = Marshal.SizeOf<GpuBody>();
  private static readonly int DamageAccumOffset = Marshal
    .OffsetOf<GpuBody>(nameof(GpuBody.DamageAccum))
    .ToInt32();

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
    _ = BitConverter.TryWriteBytes(
      ReserveGpuWrite(GpuTarget.Physics, damageAccumOff, sizeof(uint)),
      encoded
    );
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
