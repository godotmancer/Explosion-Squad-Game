namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using Godot;

/// <summary>
/// Deferred GPU command queue.
///
/// Every mutation of a GPU buffer is recorded here by the caller and applied later from a
/// single place — <see cref="FlushGpuCommands"/>, which runs immediately before the frame's
/// compute list is recorded. Nothing outside this file calls a RenderingDevice mutator.
///
/// Why this exists: the global RenderingDevice may only be touched on the rendering thread,
/// but today these mutations happen on the main thread at arbitrary moments —
/// <c>SpawnHogs</c> runs from <c>_Process</c> and from inside the trigger-zone loop,
/// <c>DamageHogViaBuffer</c> runs mid-loop. Funnelling them into one drain point is the
/// prerequisite for moving off the local device onto the global one.
///
/// This stage is behaviour-preserving. The GPU only ever observes these buffers at dispatch
/// time and the drain runs before the dispatch, so the state the shaders see is unchanged.
/// Two details make that true in the presence of buffer growth:
///
///   * Commands are applied strictly FIFO.
///   * A command names its target buffer by <see cref="GpuTarget"/>, not by
///     <see cref="Rid"/>, and the Rid is resolved at drain time. So a write queued *before*
///     a growth command lands in the old buffer and is then copied forward by the growth,
///     while a write queued *after* it lands directly in the new buffer. Either way the
///     write survives.
/// </summary>
public sealed partial class SquadMultiMeshInstance3D
{
  /// <summary>
  /// Buffers a queued command can target. Named rather than held as an <see cref="Rid"/>
  /// because growth can replace the Rid partway through a drain.
  /// </summary>
  private enum GpuTarget : byte
  {
    Physics,
    Obstacles,
    Bombs,
    Projectiles,
  }

  private enum GpuCommandKind : byte
  {
    Write,
    GrowPhysics,
    GrowObstacles,
  }

  private struct GpuCommand
  {
    public GpuCommandKind Kind;
    public GpuTarget Target;

    // Write: byte offset within the target buffer, and the payload's slice of _gpuPayload.
    public uint Offset;
    public int PayloadOffset;
    public int PayloadSize;

    // GrowPhysics: new capacity in bodies. GrowObstacles: new size in bytes.
    public int NewCapacity;

    // GrowPhysics: how many bytes of the old buffer are still live and must be copied
    // forward. Captured at enqueue time, when the pre-spawn body count is known.
    public int PreservedBytes;
  }

  private readonly List<GpuCommand> _gpuCommands = [];

  // Payload pool. Call sites reuse their own staging arrays (_bombBytes,
  // _projSlotUploadBytes, ...) and overwrite them before the drain runs, so payload bytes
  // have to be copied out at enqueue time rather than referenced.
  private byte[] _gpuPayload = new byte[8192];
  private int _gpuPayloadUsed;

  // BufferUpdate reads only the first sizeBytes of the array handed to it — the existing
  // bomb upload already relies on that — so one grow-only scratch array serves every size.
  private byte[] _gpuScratch = new byte[8192];

  private Rid ResolveGpuTarget(GpuTarget target) =>
    target switch
    {
      GpuTarget.Physics => _physicsBuffer,
      GpuTarget.Obstacles => _obstacleBuffer,
      GpuTarget.Bombs => _bombBuffer,
      GpuTarget.Projectiles => _projBuffer,
      _ => default,
    };

  /// <summary>Queues a byte-range write into one of the GPU buffers.</summary>
  private void EnqueueGpuWrite(GpuTarget target, uint offset, ReadOnlySpan<byte> payload)
  {
    if (payload.IsEmpty)
    {
      return;
    }

    var needed = _gpuPayloadUsed + payload.Length;
    if (needed > _gpuPayload.Length)
    {
      Array.Resize(ref _gpuPayload, Math.Max(needed, _gpuPayload.Length * 2));
    }

    payload.CopyTo(_gpuPayload.AsSpan(_gpuPayloadUsed));

    _gpuCommands.Add(
      new GpuCommand
      {
        Kind = GpuCommandKind.Write,
        Target = target,
        Offset = offset,
        PayloadOffset = _gpuPayloadUsed,
        PayloadSize = payload.Length,
      }
    );

    _gpuPayloadUsed = needed;
  }

  /// <summary>
  /// Queues a body-buffer capacity increase. <paramref name="preservedBytes"/> is how much
  /// of the current buffer is live and must survive the move.
  /// </summary>
  private void EnqueueGrowPhysics(int newCapacity, int preservedBytes) =>
    _gpuCommands.Add(
      new GpuCommand
      {
        Kind = GpuCommandKind.GrowPhysics,
        NewCapacity = newCapacity,
        PreservedBytes = preservedBytes,
      }
    );

  /// <summary>
  /// Queues an obstacle-buffer resize. The obstacle data is rewritten in full every frame,
  /// so nothing needs preserving — the caller queues a write straight after this.
  /// </summary>
  private void EnqueueGrowObstacles(int newSizeBytes) =>
    _gpuCommands.Add(
      new GpuCommand { Kind = GpuCommandKind.GrowObstacles, NewCapacity = newSizeBytes }
    );

  /// <summary>
  /// Applies every queued command in order. The single point where GPU buffers are mutated.
  /// </summary>
  private void FlushGpuCommands()
  {
    if (_gpuCommands.Count == 0)
    {
      return;
    }

    for (var i = 0; i < _gpuCommands.Count; i++)
    {
      var cmd = _gpuCommands[i];
      switch (cmd.Kind)
      {
        case GpuCommandKind.Write:
          if (cmd.PayloadSize > _gpuScratch.Length)
          {
            Array.Resize(ref _gpuScratch, cmd.PayloadSize);
          }

          _gpuPayload
            .AsSpan(cmd.PayloadOffset, cmd.PayloadSize)
            .CopyTo(_gpuScratch.AsSpan());
          _ = _rd.BufferUpdate(
            ResolveGpuTarget(cmd.Target),
            cmd.Offset,
            (uint)cmd.PayloadSize,
            _gpuScratch
          );
          break;

        case GpuCommandKind.GrowPhysics:
          ApplyPhysicsGrowth(cmd);
          break;

        case GpuCommandKind.GrowObstacles:
          ApplyObstacleGrowth(cmd);
          break;

        default:
          break;
      }
    }

    _gpuCommands.Clear();
    _gpuPayloadUsed = 0;
  }

  private void FreeGpuRid(ref Rid rid)
  {
    if (rid.IsValid)
    {
      _rd.FreeRid(rid);
      rid = new Rid();
    }
  }

  private void ApplyPhysicsGrowth(in GpuCommand cmd)
  {
    var newCapacity = cmd.NewCapacity;

    // Uniform sets point at the buffers being replaced, so retire them first. The previous
    // code assigned `new Rid()` over these without freeing, leaking four sets per growth.
    FreeGpuRid(ref _physicsUniformSet);
    FreeGpuRid(ref _transformUniformSet);
    FreeGpuRid(ref _hashUniformSet);
    FreeGpuRid(ref _projUniformSet);

    var grown = _rd.StorageBufferCreate((uint)(newCapacity * BODY_STRIDE * sizeof(float)));

    // Move the live bodies GPU-side. This replaces a BufferGetData of the whole body
    // buffer plus a merge plus a full re-upload — at 20k bodies that was over 2 MB through
    // system memory, and a pipeline stall, on every capacity doubling.
    if (cmd.PreservedBytes > 0)
    {
      _ = _rd.BufferCopy(_physicsBuffer, grown, 0, 0, (uint)cmd.PreservedBytes);
    }

    // Slots past PreservedBytes are left uninitialized on purpose: every shader bounds its
    // work by the num_bodies push constant, and the newly spawned bodies are written by the
    // queued write that follows this command.
    FreeGpuRid(ref _physicsBuffer);
    _physicsBuffer = grown;

    FreeGpuRid(ref _transformBuffer);
    _transformFloats = new float[newCapacity * INSTANCE_STRIDE];
    _transformBuffer = _rd.StorageBufferCreate(
      (uint)(_transformFloats.Length * sizeof(float))
    );

    Multimesh.InstanceCount = newCapacity;

    RebuildPhysicsUniformSet();
    RebuildTransformUniformSet();
    RebuildHashUniformSet();
    RebuildProjectileUniformSet();
  }

  private void ApplyObstacleGrowth(in GpuCommand cmd)
  {
    FreeGpuRid(ref _physicsUniformSet);
    FreeGpuRid(ref _obstacleBuffer);

    _obstacleBufferSize = (uint)cmd.NewCapacity;
    _obstacleBuffer = _rd.StorageBufferCreate(_obstacleBufferSize);

    RebuildPhysicsUniformSet();
  }
}
