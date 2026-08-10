namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Called after the GPU sync + compaction loop each physics frame.
  /// Tests every alive hog against each trigger zone using transform-buffer
  /// positions we already have in <paramref name="gpuFloats"/>.
  ///
  /// Effects fire only on the enter transition (first frame inside).
  /// Multiply and Add additionally use <see cref="_triggeredPairs"/> as a
  /// one-shot skip: clones spawned inside a thick zone are marked so the enter
  /// event they are born into is swallowed (the mark is consumed by that enter).
  /// This prevents exponential growth when newly-spawned bodies are still inside
  /// the zone on the next frame, while a genuine exit + re-entry triggers again.
  /// Damage re-triggers on every re-entry (no marks needed).
  /// </summary>
  private void ProcessTriggerZones(ReadOnlySpan<float> gpuFloats)
  {
    // Snapshot both lists at entry. _triggerZones can be nulled mid-frame by
    // InvalidateObstacleCache (e.g. if an obstacle visibility change fires during
    // signal emission), so we capture a local reference and bail if it's gone.
    var zones = _triggerZones;
    if (zones == null)
    {
      return;
    }

    // Snapshot NumBodies: SpawnHogs below grows it, but we only test the
    // bodies that existed at the start of this frame.
    var bodyCount = NumBodies;
    _pendingTriggerSpawns.Clear();

    for (var zoneIdx = 0; zoneIdx < zones.Count; zoneIdx++)
    {
      var zone = zones[zoneIdx];
      if (
        !IsInstanceValid(zone.Shape)
        || zone.Shape.Shape == null
        || zone.Shape.Disabled
        || !zone.Shape.IsVisibleInTree()
      )
      {
        continue;
      }

      var (center, halfExt, axis, isCircle) = GetTriggerBounds(zone.Shape);

      // Reuse the scratch set for this frame's occupants; the zone's previous
      // set becomes next zone's scratch after the swap below (zero alloc).
      var prevOccupants = zone.Occupants;
      var currOccupants = _zoneOccupantsScratch;
      currOccupants.Clear();

      for (var i = 0; i < bodyCount; i++)
      {
        var src = i * INSTANCE_STRIDE;
        var stateBits = BitConverter.SingleToUInt32Bits(gpuFloats[src + INST_STATE]);
        if ((stateBits & STATE_DEAD) != 0)
        {
          continue;
        }

        var hogXZ = new Vector2(gpuFloats[src + INST_ORIGIN_X], gpuFloats[src + INST_ORIGIN_Z]);
        var inside = isCircle
          ? IsInsideCircle(hogXZ, center, halfExt.X)
          : IsInsideOBB(hogXZ, center, halfExt, axis);

        if (!inside)
        {
          continue;
        }

        currOccupants.Add(i);

        if (prevOccupants.Contains(i))
        {
          continue; // already inside last frame — don't re-trigger
        }

        // --- Enter event ---
        var hogPos = new Vector3(
          gpuFloats[src + INST_ORIGIN_X],
          YOffset,
          gpuFloats[src + INST_ORIGIN_Z]
        );

        switch (zone.Effect)
        {
          case TriggerEffect.Damage:
            // Damage re-fires on every re-entry; no permanent immunity needed.
            DamageHogViaBuffer(i, zone.Value);
            EmitSignal(SignalName.HogZoneTriggered, i, hogPos, zone.Shape, (int)zone.Effect);
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

            EmitSignal(SignalName.HogZoneTriggered, i, hogPos, zone.Shape, (int)zone.Effect);
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

            EmitSignal(SignalName.HogZoneTriggered, i, hogPos, zone.Shape, (int)zone.Effect);
            break;
          default:
            break;
        }
      }

      zone.Occupants = currOccupants;
      _zoneOccupantsScratch = prevOccupants;
    }

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

  // Byte layout of GpuBody, resolved once (Marshal reflection is not free per call).
  private static readonly int GpuBodySize = Marshal.SizeOf<GpuBody>();
  private static readonly int DamageAccumOffset = Marshal
    .OffsetOf<GpuBody>(nameof(GpuBody.DamageAccum))
    .ToInt32();

  // Reused 4-byte scratch for encoding the damage value (zero per-call allocation).
  private readonly byte[] _damageEncodeBytes = new byte[sizeof(uint)];

  /// <summary>
  /// Applies flat damage to a hog by writing to its <c>damage_accum</c> field
  /// in the physics buffer. The GPU physics shader reads and clears this accumulator
  /// each frame (DAMAGE_SCALE = 256), applying the result to health.
  /// The write is queued and takes effect on the next physics frame.
  /// </summary>
  private void DamageHogViaBuffer(int index, float damage)
  {
    var damageAccumOff = (uint)((index * GpuBodySize) + DamageAccumOffset);
    // damage_accum is a uint encoded as damage × 256 (matching DAMAGE_SCALE in the shader).
    var encoded = (uint)(damage * 256.0f);
    _ = BitConverter.TryWriteBytes(_damageEncodeBytes, encoded);
    _ = _rd.BufferUpdate(_physicsBuffer, damageAccumOff, sizeof(uint), _damageEncodeBytes);
  }

  private static long TriggerKey(int hogIndex, int zoneIndex) =>
    ((long)zoneIndex << 32) | (uint)hogIndex;

  private static (Vector2 center, Vector2 halfExt, Vector2 axis, bool isCircle) GetTriggerBounds(
    CollisionShape3D cs
  )
  {
    var xform = cs.GlobalTransform;
    var center = new Vector2(xform.Origin.X, xform.Origin.Z);
    var yRot = xform.Basis.GetEuler().Y;
    var axis = new Vector2(Mathf.Cos(yRot), -Mathf.Sin(yRot));

    return cs.Shape switch
    {
      SphereShape3D s => (center, new Vector2(s.Radius, s.Radius), axis, true),
      CylinderShape3D c => (center, new Vector2(c.Radius, c.Radius), axis, true),
      BoxShape3D b => (center, new Vector2(b.Size.X * 0.5f, b.Size.Z * 0.5f), axis, false),
      _ => (center, Vector2.Zero, axis, false),
    };
  }

  private static bool IsInsideCircle(Vector2 point, Vector2 center, float radius) =>
    point.DistanceTo(center) <= radius;

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
