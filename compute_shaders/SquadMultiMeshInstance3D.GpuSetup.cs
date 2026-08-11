namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Runtime.InteropServices;
using Godot;

public sealed partial class SquadMultiMeshInstance3D
{
  private void SetupMultiMesh() => Multimesh.InstanceCount = NumBodies;

  private void SetupCompute()
  {
    _rd = RenderingServer.CreateLocalRenderingDevice();

    // --- Pre-allocate staging buffers (reused every frame, zero GC pressure) ---
    _physicsPushBytes = new byte[PHYSICS_PUSH_SIZE];
    _bombStaging = new float[MAX_BOMBS * BOMB_STRIDE];
    _bombBytes = new byte[MAX_BOMBS * BOMB_STRIDE * sizeof(float)];

    // Initial obstacle capacity — grown if needed, never shrunk
    _obstacleCapacity = 64 * OBSTACLE_STRIDE; // room for 64 obstacles
    _obstacleStaging = new float[_obstacleCapacity];
    _obstacleBytes = new byte[_obstacleCapacity * sizeof(float)];

    // --- Physics shader ---
    var physicsFile = GD.Load<RDShaderFile>("res://compute_shaders/physics_compute.glsl");
    var physicsSpirv = physicsFile.GetSpirV();
    _physicsShader = _rd.ShaderCreateFromSpirV(physicsSpirv);

    // Initialize bodies (staging array is only needed until the GPU buffer is created)
    _bodyCapacity = NumBodies;
    var bodiesData = new GpuBody[_bodyCapacity];

    _hogStates = new byte[_bodyCapacity];

    for (var i = 0; i < NumBodies; i++)
    {
      var position = new Vector2(
        _rndGen.RandfRange(-30.0f, 30.0f),
        _rndGen.RandfRange(-60.0f, 60.0f)
      );
      if (SpawnPoint != null)
      {
        position = new Vector2(SpawnPoint.Position.X, SpawnPoint.Position.Z);
      }
      bodiesData[i] = new GpuBody
      {
        Position = position,
        Velocity = Vector2.Zero,
        Height = YOffset,
        VerticalVelocity = 0.0f,
        Radius = BodyRadius,
        Mass = _rndGen.RandfRange(0.5f, 1.1f),
        FacingAngle = 0.0f,
        WanderAngle = 0.0f,
        Health = HogHealth,
        LastHitTime = 0.0f,
        BombOriginX = 0.0f,
        BombOriginY = 0.0f,
        DamagedTime = 0.0f,
        State = 0,
      };
    }

    var bodyBytes = MemoryMarshal.Cast<GpuBody, byte>(bodiesData.AsSpan()).ToArray();
    _physicsBuffer = _rd.StorageBufferCreate((uint)bodyBytes.Length, bodyBytes);

    // --- Obstacle buffer — created at full staging capacity so runtime growth is rare ---
    ExtractObstacles(0f); // first frame: no velocity data yet
    if (_numObstacles > 0)
    {
      Buffer.BlockCopy(
        _obstacleStaging,
        0,
        _obstacleBytes,
        0,
        _numObstacles * OBSTACLE_STRIDE * sizeof(float)
      );
    }

    _obstacleBufferSize = (uint)_obstacleBytes.Length;
    _obstacleBuffer = _rd.StorageBufferCreate(_obstacleBufferSize, _obstacleBytes);

    // --- Bomb buffer (pre-allocated to MAX_BOMBS) ---
    _bombBufferSize = MAX_BOMBS * BOMB_STRIDE * sizeof(float);
    _bombBuffer = _rd.StorageBufferCreate(_bombBufferSize);

    // --- Spatial hash buffers (fixed size, independent of NumBodies) ---
    _hashPushBytes = new byte[HASH_BUILD_PUSH_SIZE];
    // counts: one uint per bucket, plus one trailing uint used as the overflow counter
    // (HASH_OVERFLOW_SLOT in spatial_hash_build.glsl) — all cleared to 0 on creation
    _hashCountsBuffer = _rd.StorageBufferCreate(
      HASH_COUNTS_BUFFER_SIZE,
      new byte[HASH_COUNTS_BUFFER_SIZE]
    );
    // entries: HASH_MAX_PER_CELL body indices per bucket
    _hashEntriesBuffer = _rd.StorageBufferCreate(
      HASH_TABLE_SIZE * HASH_MAX_PER_CELL * sizeof(uint)
    );

    // --- Spatial hash build shader ---
    var hashFile = GD.Load<RDShaderFile>("res://compute_shaders/spatial_hash_build.glsl");
    var hashSpirv = hashFile.GetSpirV();
    _hashShader = _rd.ShaderCreateFromSpirV(hashSpirv);
    _hashPipeline = _rd.ComputePipelineCreate(_hashShader);
    VerifyPipeline(_hashPipeline, "spatial_hash_build.glsl");
    RebuildHashUniformSet();

    // --- MultiMesh instance buffer — written by physics_compute's tail, so it must exist
    // before the physics uniform set is built (it is binding 5). ---
    _transformFloats = new float[NumBodies * INSTANCE_STRIDE];
    var transformSize = (uint)(_transformFloats.Length * sizeof(float));
    _transformBuffer = _rd.StorageBufferCreate(transformSize);

    _physicsPipeline = _rd.ComputePipelineCreate(_physicsShader);
    VerifyPipeline(_physicsPipeline, "physics_compute.glsl");
    RebuildPhysicsUniformSet(); // bindings 0-5: bodies, obstacles, bombs, hash counts, hash entries, instances

    // --- Projectile shader + buffer ---
    var projFile = GD.Load<RDShaderFile>("res://compute_shaders/projectile_compute.glsl");
    var projSpirv = projFile.GetSpirV();
    _projShader = _rd.ShaderCreateFromSpirV(projSpirv);
    _projPipeline = _rd.ComputePipelineCreate(_projShader);
    VerifyPipeline(_projPipeline, "projectile_compute.glsl");

    _projBuffer = _rd.StorageBufferCreate(MAX_PROJECTILES * PROJ_STRIDE * sizeof(float));

    _projPushBytes = new byte[PROJ_PUSH_SIZE];
    _projLifetimes = new float[MAX_PROJECTILES];
    _projHitCallbacks = new Action<Vector3>[MAX_PROJECTILES];
    _projPendingUpload = new bool[MAX_PROJECTILES];
    _projAllStagingFloats = new float[MAX_PROJECTILES * PROJ_STRIDE];
    _projSlotUploadBytes = new byte[PROJ_STRIDE * sizeof(float)];
    for (var i = 0; i < MAX_PROJECTILES; i++)
    {
      _projFreeSlots.Enqueue(i);
    }

    RebuildProjectileUniformSet();
  }

  /// <summary>
  /// Reports a compute pipeline that failed to build, which happens when its shader did not
  /// compile — most often a stale or failed .glsl import.
  ///
  /// Worth failing loudly on, because Godot's only other signal is misleading: binding an
  /// invalid pipeline is a silent no-op, so the next
  /// <c>ComputeListSetPushConstant</c> is validated against whichever pipeline was bound
  /// before it. That surfaces as a per-frame "This compute pipeline requires (N) bytes of
  /// push constant data, supplied: (M)" naming byte counts from two unrelated shaders.
  /// </summary>
  private static void VerifyPipeline(Rid pipeline, string shaderFile)
  {
    if (!pipeline.IsValid)
    {
      GD.PushError(
        $"Compute pipeline for {shaderFile} failed to build — its shader did not compile. "
          + "Re-import it (godotx --path . --import) and check the import log. Until this is "
          + "fixed, expect misleading push-constant size errors from the following shader."
      );
    }
  }

  private double _timeSinceOverflowSample;
  private uint _lastHashOverflowCount;

  /// <summary>
  /// Reads the trailing 4-byte overflow counter out of the hash counts buffer and logs any
  /// increase since the last sample. Sampled at 1 Hz rather than per frame because
  /// BufferGetData forces a submit-and-wait on the local RenderingDevice.
  /// </summary>
  private void SampleHashOverflow(double delta)
  {
    _timeSinceOverflowSample += delta;
    if (_timeSinceOverflowSample < 1.0)
    {
      return;
    }

    _timeSinceOverflowSample = 0;

    var raw = _rd.BufferGetData(_hashCountsBuffer, HASH_OVERFLOW_SLOT * sizeof(uint), sizeof(uint));
    if (raw is not { Length: sizeof(uint) })
    {
      return;
    }

    // The shader only ever increments this, so the difference is the drops since the last
    // sample. Unsigned subtraction gives the right answer even across a 2^32 wrap.
    var total = BitConverter.ToUInt32(raw, 0);
    var dropped = total - _lastHashOverflowCount;
    _lastHashOverflowCount = total;

    if (dropped > 0)
    {
      GD.PushWarning(
        $"Spatial hash dropped {dropped} body insertions in the last second: a cell held "
          + $"more than HASH_MAX_PER_CELL ({HASH_MAX_PER_CELL}) bodies. Those bodies were "
          + "invisible to neighbour queries. Raise HASH_MAX_PER_CELL or shrink HASH_CELL_SIZE."
      );
    }
  }

  protected override void Dispose(bool disposing)
  {
    if (_rd != null)
    {
      // Free order: pipelines + uniform sets first, then the buffers and
      // shaders they reference.
      Rid[] rids =
      [
        _physicsPipeline,
        _hashPipeline,
        _projPipeline,
        _physicsUniformSet,
        _hashUniformSet,
        _projUniformSet,
        _physicsBuffer,
        _obstacleBuffer,
        _bombBuffer,
        _transformBuffer,
        _hashCountsBuffer,
        _hashEntriesBuffer,
        _projBuffer,
        _physicsShader,
        _hashShader,
        _projShader,
      ];

      foreach (var rid in rids)
      {
        if (rid.IsValid)
        {
          _rd.FreeRid(rid);
        }
      }

      _rd.Free();
      _rd = null;
    }

    base.Dispose(disposing);
  }

  // --- Push constants (zero-alloc: writes directly to pre-allocated byte arrays) ---

  private void WritePhysicsPush(
    float deltaTime,
    int numBodies,
    float targetX,
    float targetY,
    float arriveRadius,
    float rotationSpeed,
    float time,
    int numObstacles,
    int numBombs,
    float bombFearDuration
  )
  {
    var floats = MemoryMarshal.Cast<byte, float>(_physicsPushBytes.AsSpan());
    var ints = MemoryMarshal.Cast<byte, int>(_physicsPushBytes.AsSpan());
    var uints = MemoryMarshal.Cast<byte, uint>(_physicsPushBytes.AsSpan());
    floats[PHYS_PUSH_DELTA_TIME] = deltaTime;
    ints[PHYS_PUSH_NUM_BODIES] = numBodies;
    floats[PHYS_PUSH_TARGET_X] = targetX;
    floats[PHYS_PUSH_TARGET_Z] = targetY;
    floats[PHYS_PUSH_ARRIVE_RADIUS] = arriveRadius;
    floats[PHYS_PUSH_ROTATION_SPEED] = rotationSpeed;
    floats[PHYS_PUSH_TIME] = time;
    ints[PHYS_PUSH_NUM_OBSTACLES] = numObstacles;
    ints[PHYS_PUSH_NUM_BOMBS] = numBombs;
    floats[PHYS_PUSH_BOMB_FEAR_DURATION] = bombFearDuration;
    floats[PHYS_PUSH_GRAVITY] = Gravity;
    floats[PHYS_PUSH_Y_OFFSET] = YOffset;
    uints[PHYS_PUSH_FRAME_PARITY] = _hashFrameParity;
    floats[PHYS_PUSH_HOG_GRAVITY_SCALE] = HogGravityScale;
  }

  private void WriteHashBuildPush(int numBodies, float yOffset)
  {
    var floats = MemoryMarshal.Cast<byte, float>(_hashPushBytes.AsSpan());
    var uints = MemoryMarshal.Cast<byte, uint>(_hashPushBytes.AsSpan());
    var ints = MemoryMarshal.Cast<byte, int>(_hashPushBytes.AsSpan());
    uints[HASH_PUSH_PARITY] = _hashFrameParity;
    ints[HASH_PUSH_NUM_BODIES] = numBodies;
    floats[HASH_PUSH_Y_OFFSET] = yOffset;
    floats[3] = 0f; // pad
  }

  private void RebuildPhysicsUniformSet()
  {
    if (_physicsUniformSet.IsValid)
    {
      _rd.FreeRid(_physicsUniformSet);
    }

    var pu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 0 };
    pu.AddId(_physicsBuffer);
    var ou = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 1 };
    ou.AddId(_obstacleBuffer);
    var bu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 2 };
    bu.AddId(_bombBuffer);
    var hcu = new RDUniform
    {
      UniformType = RenderingDevice.UniformType.StorageBuffer,
      Binding = 3,
    };
    hcu.AddId(_hashCountsBuffer);
    var heu = new RDUniform
    {
      UniformType = RenderingDevice.UniformType.StorageBuffer,
      Binding = 4,
    };
    heu.AddId(_hashEntriesBuffer);
    // Binding 5: MultiMesh instance data, written at the tail of physics_compute. This used to
    // be a separate transform_compute dispatch.
    var tu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 5 };
    tu.AddId(_transformBuffer);
    _physicsUniformSet = _rd.UniformSetCreate([pu, ou, bu, hcu, heu, tu], _physicsShader, 0);
  }

  private void RebuildHashUniformSet()
  {
    if (_hashUniformSet.IsValid)
    {
      _rd.FreeRid(_hashUniformSet);
    }

    // Bodies at binding 0 — must be updated when _physicsBuffer is recreated (SpawnHogs).
    var bu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 0 };
    bu.AddId(_physicsBuffer);
    var cu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 1 };
    cu.AddId(_hashCountsBuffer);
    var eu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 2 };
    eu.AddId(_hashEntriesBuffer);
    _hashUniformSet = _rd.UniformSetCreate([bu, cu, eu], _hashShader, 0);
  }

  private void RebuildProjectileUniformSet()
  {
    if (_projUniformSet.IsValid)
    {
      _rd.FreeRid(_projUniformSet);
    }

    var pu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 0 };
    pu.AddId(_physicsBuffer);
    var qu = new RDUniform { UniformType = RenderingDevice.UniformType.StorageBuffer, Binding = 1 };
    qu.AddId(_projBuffer);
    var hcu = new RDUniform
    {
      UniformType = RenderingDevice.UniformType.StorageBuffer,
      Binding = 2,
    };
    hcu.AddId(_hashCountsBuffer);
    var heu = new RDUniform
    {
      UniformType = RenderingDevice.UniformType.StorageBuffer,
      Binding = 3,
    };
    heu.AddId(_hashEntriesBuffer);
    _projUniformSet = _rd.UniformSetCreate([pu, qu, hcu, heu], _projShader, 0);
  }
}
