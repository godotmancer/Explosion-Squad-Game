namespace ExplosionSquadGame.compute_shaders;

using System;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  private double _timeSinceLastLabelUpdate;

  private void UpdateLabels(ReadOnlySpan<float> gpuFloats, bool forceRecalculate)
  {
    if (HogLabels == null || !_showStateLabels)
    {
      return;
    }

    if (forceRecalculate)
    {
      var camPos = Camera.GlobalPosition;
      var viewportRect = GetViewport().GetVisibleRect();

      _labelCandidates.Clear();
      for (var i = 0; i < NumBodies; i++)
      {
        var o = i * INSTANCE_STRIDE;
        var stateBits = BitConverter.SingleToUInt32Bits(gpuFloats[o + INST_STATE]);
        if ((stateBits & STATE_DEAD) != 0)
        {
          continue;
        }

        var worldPos = new Vector3(
          gpuFloats[o + INST_ORIGIN_X],
          gpuFloats[o + INST_ORIGIN_Y],
          gpuFloats[o + INST_ORIGIN_Z]
        );

        if (!IsLabelOnScreen(worldPos, viewportRect))
        {
          continue;
        }

        _labelCandidates.Add(
          (i, camPos.DistanceSquaredTo(worldPos), worldPos, ClassifyState(stateBits))
        );
      }

      _labelCandidates.Sort(static (a, b) => a.distSq.CompareTo(b.distSq));

      _nextLabeledSet.Clear();
      var limit = Math.Min(_labelCandidates.Count, MaxVisibleLabels);
      for (var k = 0; k < limit; k++)
      {
        var (i, _, worldPos, state) = _labelCandidates[k];
        _ = _nextLabeledSet.Add(i);
        UpsertLabel(i, state, worldPos, forceAssign: !_labeledSet.Contains(i));
      }

      foreach (var i in _labeledSet)
      {
        if (!_nextLabeledSet.Contains(i))
        {
          _ = HogLabels.Call("release_label", i);
        }
      }

      (_labeledSet, _nextLabeledSet) = (_nextLabeledSet, _labeledSet);
    }
    else
    {
      foreach (var i in _labeledSet)
      {
        var o = i * INSTANCE_STRIDE;
        var stateBits = BitConverter.SingleToUInt32Bits(gpuFloats[o + INST_STATE]);
        if ((stateBits & STATE_DEAD) != 0)
        {
          continue;
        }

        var worldPos = new Vector3(
          gpuFloats[o + INST_ORIGIN_X],
          gpuFloats[o + INST_ORIGIN_Y],
          gpuFloats[o + INST_ORIGIN_Z]
        );
        UpsertLabel(i, ClassifyState(stateBits), worldPos, forceAssign: false);
      }
    }
  }

  /// <summary>
  /// Re-assigns the label when newly shown or its state changed; otherwise just
  /// moves it to the hog's current position.
  /// </summary>
  private void UpsertLabel(int index, HogBehaviourState state, Vector3 worldPos, bool forceAssign)
  {
    if (forceAssign || (HogBehaviourState)_hogStates[index] != state)
    {
      _hogStates[index] = (byte)state;
      _ = HogLabels.Call("assign_label", index, (int)state, worldPos);
    }
    else
    {
      _ = HogLabels.Call("update_label_position", index, worldPos, true);
    }
  }

  private static HogBehaviourState ClassifyState(uint stateBits) =>
    (stateBits & STATE_DAMAGED) != 0 ? HogBehaviourState.Damaged
    : (stateBits & STATE_IN_FEAR) != 0 ? HogBehaviourState.InFear
    : (stateBits & STATE_FLEEING) != 0 ? HogBehaviourState.Fleeing
    : (stateBits & STATE_AIRBORNE) != 0 ? HogBehaviourState.Airborne
    : (stateBits & STATE_SPRINTING) != 0 ? HogBehaviourState.Sprinting
    : (stateBits & STATE_WALKING) != 0 ? HogBehaviourState.Walking
    : HogBehaviourState.Idle;

  private bool IsLabelOnScreen(Vector3 worldPos, Rect2 viewportRect)
  {
    if (Camera.IsPositionBehind(worldPos))
    {
      return false;
    }

    var screenPos = Camera.UnprojectPosition(worldPos);
    return viewportRect.HasPoint(screenPos);
  }
}
