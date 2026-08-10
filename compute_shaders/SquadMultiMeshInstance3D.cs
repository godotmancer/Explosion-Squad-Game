namespace ExplosionSquadGame.compute_shaders;

using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
using Godot;

[GlobalClass]
public sealed partial class SquadMultiMeshInstance3D : MultiMeshInstance3D
{
  [Export]
  public bool ShowHogs { get; set; } = true;

  [Export]
  public int NumBodies { get; set; } = 5000;

  [Export]
  public float BodyRadius { get; set; } = 0.25f;

  [Export]
  public float YOffset { get; set; } = -0.3f;

  [Export]
  public float Gravity { get; set; } = 9.8f;

  [Export]
  public float HogGravityScale { get; set; } = 2.5f;

  [Export]
  public float ArriveRadius { get; set; } = 10.0f;

  [Export]
  public float RotationSpeed { get; set; } = 40.0f;

  [Export]
  public Camera3D Camera { get; set; }

  [Export]
  public MeshInstance3D TargetMarker { get; set; }

  [Export]
  public Node ObstaclesRoot { get; set; }

  [Export]
  public float ObstacleMargin { get; set; } = 0.1f;

  [ExportGroup("Health")]
  [Export]
  public float HogHealth { get; set; } = 100.0f;

  [Export]
  public PackedScene DeathFxScene { get; set; }

  [Export]
  public int MaxDeathFxPerFrame { get; set; } = 10;

  [ExportGroup("Bomb")]
  [Export]
  public float BombForce { get; set; } = 200.0f;

  [Export]
  public float BombRadius { get; set; } = 15.0f;

  [Export]
  public float BombDuration { get; set; } = 0.5f;

  [Export]
  public float BombDamage { get; set; } = 80.0f;

  [Export]
  public float BombFearDuration { get; set; } = 3.0f;

  /// <summary>Velocity impulse applied to hogs near a dying hog. 0 = disabled.</summary>
  [ExportGroup("Death Fear")]
  [Export]
  public float DeathFearForce { get; set; } = 12.0f;

  /// <summary>Radius within which neighbours react to a dying hog.</summary>
  [Export]
  public float DeathFearRadius { get; set; } = 5.0f;

  /// <summary>How long the death-fear impulse lingers (seconds).</summary>
  [Export]
  public float DeathFearDuration { get; set; } = 0.25f;

  [ExportGroup("Mechanics")]
  [Export]
  public bombs.BombSpawner BombSpawner { get; set; }

  [Export]
  public Node3D DrawableGround { get; set; }

  [Export]
  public Node3D MouseGlobalPositionNode { get; set; }

  [ExportGroup("State Labels")]
  [Export]
  public Node HogLabels { get; set; }

  [Export]
  public int MaxVisibleLabels { get; set; } = 50;

  /// <summary>
  /// Samples the spatial-hash overflow counter once a second and logs any new drops.
  /// A non-zero reading means bodies were invisible to their neighbours that frame, which
  /// shows up as hogs walking through each other in dense piles rather than as an error.
  /// Off by default: the sample costs a small buffer readback, which stalls the GPU.
  /// </summary>
  [ExportGroup("Debug")]
  [Export]
  public bool DebugHashOverflow { get; set; }

  // Hog behaviour states — matches state logic in hoglabels.gd
  public enum HogBehaviourState : byte
  {
    Idle,
    Walking,
    Sprinting,
    Damaged,
    Fleeing,
    InFear,
    Airborne,
  }

  // Effect applied when a hog enters a trigger zone.
  // Zones are CollisionShape3D nodes with metadata keys "damage", "multiply", or "add".
  // They are pass-through (excluded from the GPU obstacle buffer) and detected via
  // CPU-side shape tests against the per-frame transform-buffer readback.
  public enum TriggerEffect
  {
    Damage,
    Multiply,
    Add,
  }

  private sealed class TriggerZone
  {
    public CollisionShape3D Shape;

    // Effect to apply on each enter event.
    public TriggerEffect Effect;

    // damage   → flat damage dealt to the hog on each entry (can re-trigger on re-entry)
    // multiply → integer multiplier; (Value-1) clones spawned per entering hog (permanent immunity per zone)
    // add      → integer count; that many hogs spawned at the zone centre per entry (permanent immunity per zone)
    public float Value;

    // Hog indices that were inside this zone last frame (enter/exit detection).
    public HashSet<int> Occupants = [];
  }

  [Signal]
  public delegate void HogStateChangedEventHandler(int index, int newState, Vector3 worldPos);

  private readonly List<BombState> _activeBombs = [];
  private readonly HashSet<int> _deadHogs = [];
  private readonly Queue<Vector3> _deathFxQueue = new();
  private readonly Queue<Node3D> _deathFxPool = new();
  private int _deathFxTotalCreated;
  private const int MAX_POOLED_DEATH_FX = 30;

  public const int BOMB_STRIDE = 8; // floats per bomb
  public const int MAX_BOMBS = 32; // pre-allocated capacity

  public struct BombState
  {
    public Vector2 Pos;
    public float Timer;
    public bool DamageApplied;
    public float Force;
    public float Radius;
    public float Duration;
    public float Damage;
  }

  /// <summary>All ability fields for a single projectile. Zero-valued fields are ignored.</summary>
  public struct ProjectileAbility
  {
    public float Radius; // collision sphere radius
    public float Lifetime; // seconds before auto-expire
    public float Damage; // flat hit damage (or health_fraction if SourceBodyIndex >= 0)
    public float DamagePerSecond; // contagion DPS while timer active
    public float Force; // knockback magnitude
    public Vector3 ForceDir; // knockback direction (unit vector)
    public bool HasTeleport;
    public Vector2 TeleportXZ; // world XZ destination
    public float TeleportY; // world Y spawn height (0 = near ground)
    public uint ContagionType; // CONTAGION_FIRE | CONTAGION_POISON | CONTAGION_ALCOHOL
    public float ContagionDuration; // seconds
    public int SourceBodyIndex; // -1 = not a hog; else index of throwing hog
  }

  // Spatial hash — sizes must match constants in spatial_hash_build.glsl / physics_compute.glsl
  // HASH_TABLE_SIZE must be a power of two: the shaders mask with (size - 1).
  // Fixed, not scaled to NumBodies: the build shader's parity scheme means no pass ever
  // iterates the table, so an oversized table costs allocation only (128 KB counts +
  // 8 MB entries) and never per-frame time. See the sizing note in spatial_hash_build.glsl.
  public const int HASH_TABLE_SIZE = 32768;
  public const int HASH_MAX_PER_CELL = 64;

  // The counts buffer carries one uint per bucket plus a trailing overflow counter at
  // index HASH_TABLE_SIZE (HASH_OVERFLOW_SLOT in spatial_hash_build.glsl).
  public const int HASH_OVERFLOW_SLOT = HASH_TABLE_SIZE;
  public const uint HASH_COUNTS_BUFFER_SIZE = (HASH_TABLE_SIZE + 1) * sizeof(uint);

  // HASH_CELL_SIZE is declared in the shaders only; no C# behaviour depends on the value.

  private RenderingDevice _rd;
  private Rid _physicsBuffer;
  private Rid _obstacleBuffer;
  private Rid _bombBuffer;
  private Rid _transformBuffer;
  private Rid _physicsShader;
  private Rid _physicsPipeline;
  private Rid _physicsUniformSet;

  // Spatial hash build pipeline — runs two sub-passes per frame before physics.
  private Rid _hashShader;
  private Rid _hashPipeline;
  private Rid _hashUniformSet;
  private Rid _hashCountsBuffer; // uint[HASH_TABLE_SIZE]
  private Rid _hashEntriesBuffer; // uint[HASH_TABLE_SIZE * HASH_MAX_PER_CELL]
  private byte[] _hashPushBytes;

  // Push constant layout for spatial_hash_build.glsl (4 × float/uint = 16 bytes)
  private const int HASH_PUSH_PARITY = 0; // uint  frame_parity (0 or 1)
  private const int HASH_PUSH_NUM_BODIES = 1; // int   num_bodies
  private const int HASH_PUSH_Y_OFFSET = 2; // float y_offset

  // slot 3 is padding
  private const int HASH_BUILD_PUSH_SIZE = 4 * sizeof(float);

  private uint _hashFrameParity; // toggles 0 ↔ 1 each physics frame
  private int _projReadbackCounter; // throttle: only read projectile buffer every N frames

  // Projectile GPU infrastructure
  private Rid _projShader;
  private Rid _projPipeline;
  private Rid _projUniformSet;
  private Rid _projBuffer;

  // Projectile slot management (C#-side lifetime tracking)
  private float[] _projLifetimes; // remaining lifetime per slot (C# countdown)
  private Action<Vector3>[] _projHitCallbacks; // optional per-slot collision callback
  private bool[] _projPendingUpload; // true while slot data hasn't been uploaded to GPU yet
  private readonly Queue<int> _projFreeSlots = new();
  private readonly Queue<int> _pendingProjSpawns = new(); // queued slot indices awaiting upload
  private float[] _projAllStagingFloats; // [MAX_PROJECTILES * PROJ_STRIDE] — written in SpawnProjectile, read in UploadPendingProjectiles
  private byte[] _projSlotUploadBytes; // [PROJ_STRIDE * sizeof(float)] — reused per-slot upload, never reallocated
  private static readonly byte[] _zeroFlagBytes = new byte[sizeof(float)]; // cleared alive flag, written to GPU on slot reclaim
  private byte[] _projPushBytes;
  private const float PROJ_LIFETIME_GRACE = 0.1f; // extra seconds before reclaiming a slot

  private float[] _transformFloats;
  private float _time;
  private Vector2 _targetPos = Vector2.Zero;
  private bool _moveMarkerWithMouse;
  private Action<Vector3> _dropBombAction;
  private bool _showStateLabels;

  public const int BODY_STRIDE = 28; // floats per body (used only for GPU size calculations)

  // ⚠ KEEP IN SYNC — 28 floats, identical field order in all four copies:
  //   compute_shaders/physics_compute.glsl
  //   compute_shaders/spatial_hash_build.glsl
  //   compute_shaders/projectile_compute.glsl
  //   compute_shaders/SquadMultiMeshInstance3D.cs  (this struct, BODY_STRIDE above)
  // Adding/reordering/resizing a field in one without the others silently
  // corrupts the buffer stride.
  [StructLayout(LayoutKind.Sequential, Pack = 4)]
  public struct GpuBody
  {
    public Vector2 Position;
    public Vector2 Velocity;
    public float Height;
    public float VerticalVelocity;
    public float Radius;
    public float Mass;
    public float FacingAngle;
    public float WanderAngle;
    public float Health;
    public float LastHitTime;
    public float BombOriginX;
    public float BombOriginY;
    public float DamagedTime;
    public uint State;
    public uint DamageAccum;
    // Absolute time (x256) at which the contagion lapses, not a remaining duration.
    // Raised by atomicMax in projectile_compute / physics_compute and never decremented.
    public uint ContagionExpiryU;
    public uint DpsRateU;
    public uint BodyFlags;
    public float TeleportX;
    public float TeleportZ;
    public int ImpulseX;
    public int ImpulseZ;
    public int ImpulseY;
    public float TeleportY;
    public float SpeedEma; // written by physics_compute.glsl only, unused here
    public float Pad3;
  }

  public const int INSTANCE_STRIDE = 20; // 12 transform + 4 color + 4 custom

  // Bitwise state flags — must match STATE_* constants in physics_compute.glsl
  public const uint STATE_IDLE = 1u;
  public const uint STATE_WALKING = 2u;
  public const uint STATE_SPRINTING = 4u;
  public const uint STATE_DAMAGED = 8u;
  public const uint STATE_FLEEING = 16u;
  public const uint STATE_IN_FEAR = 32u;
  public const uint STATE_AIRBORNE = 64u;
  public const uint STATE_DEAD = 128u;

  // Contagion state bits (must match physics_compute.glsl)
  public const uint STATE_ON_FIRE = 256u;
  public const uint STATE_POISONED = 512u;
  public const uint STATE_DRUNK = 1024u;

  // Body flag bits (must match physics_compute.glsl)
  public const uint BODY_FLAG_TELEPORT = 1u;
  public const uint BODY_FLAG_HIT_FRAME = 2u;

  public const int OBSTACLE_STRIDE = 12; // floats per obstacle (center, half_ext, axis, vel, type, margin, angular_vel, pad)

  // Instance (transform) buffer  (INSTANCE_STRIDE = 20 — Godot MultiMesh row-major layout)
  // Rows 0-2 are Transform3D written as:  [basis_col | origin_component]
  public const int INST_BASIS_XX = 0;
  public const int INST_BASIS_XY = 1;
  public const int INST_BASIS_XZ = 2;
  public const int INST_ORIGIN_X = 3;
  public const int INST_BASIS_YX = 4;
  public const int INST_SCALE_Y = 5; // basis.y.y — acts as y-scale; 0 = flattened/dead
  public const int INST_BASIS_YZ = 6;
  public const int INST_ORIGIN_Y = 7;
  public const int INST_BASIS_ZX = 8;
  public const int INST_BASIS_ZY = 9;
  public const int INST_BASIS_ZZ = 10;
  public const int INST_ORIGIN_Z = 11;
  public const int INST_COLOR_R = 12;
  public const int INST_COLOR_G = 13;
  public const int INST_COLOR_B = 14;

  public const int INST_COLOR_A = 15;

  // INSTANCE_CUSTOM written by physics_compute.glsl (instance tail)
  public const int INST_CUSTOM_R = 16;
  public const int INST_HEALTH = 17; // INSTANCE_CUSTOM.g = health
  public const int INST_STATE = 18; // INSTANCE_CUSTOM.b = bitwise state flags (reinterpret as uint)
  public const int INST_CUSTOM_A = 19;

  // Bomb buffer  (BOMB_STRIDE = 8 — struct Bomb in physics_compute.glsl)
  public const int BOMB_POS_X = 0; // vec2  pos  (.x = world X)
  public const int BOMB_POS_Z = 1; //            (.y = world Z)
  public const int BOMB_FORCE = 2; // float force
  public const int BOMB_RADIUS = 3; // float radius
  public const int BOMB_DAMAGE = 4; // float damage

  // [5..7] explicit padding in the GLSL struct

  // Obstacle buffer  (OBSTACLE_STRIDE = 12 — struct Obstacle in physics_compute.glsl)
  public const int OBS_CENTER_X = 0; // vec2 center
  public const int OBS_CENTER_Z = 1;
  public const int OBS_HALF_EXT_X = 2; // vec2 half_extents
  public const int OBS_HALF_EXT_Z = 3;
  public const int OBS_LOCAL_X_X = 4; // vec2 local_x_axis  (orientation unit vector)
  public const int OBS_LOCAL_X_Z = 5;
  public const int OBS_VEL_X = 6; // vec2 velocity
  public const int OBS_VEL_Z = 7;
  public const int OBS_TYPE = 8; // float type  (see OBS_TYPE_* below)
  public const int OBS_MARGIN = 9; // float margin
  public const int OBS_ANGULAR_VEL = 10; // float angular_vel
  public const int OBS_PAD = 11; // float pad (alignment)

  // Obstacle type values — must match OBSTACLE_CIRCLE / OBSTACLE_OBB in physics_compute.glsl
  public const float OBS_TYPE_CIRCLE = 0f;
  public const float OBS_TYPE_OBB = 1f;

  // -------------------------------------------------------------------------
  // Projectile buffer layout  (PROJ_STRIDE = 24 — struct Projectile in projectile_compute.glsl)
  // -------------------------------------------------------------------------
  public const int PROJ_STRIDE = 24;
  public const int MAX_PROJECTILES = 1024; // pre-allocated slots
  public const int PROJ_POS_X = 0;
  public const int PROJ_POS_Y = 1;
  public const int PROJ_POS_Z = 2;
  public const int PROJ_RADIUS = 3;
  public const int PROJ_VEL_X = 4;
  public const int PROJ_VEL_Y = 5;
  public const int PROJ_VEL_Z = 6;
  public const int PROJ_DAMAGE = 7;
  public const int PROJ_DPS = 8;
  public const int PROJ_FORCE = 9;
  public const int PROJ_FORCE_DIR_X = 10;
  public const int PROJ_FORCE_DIR_Y = 11;
  public const int PROJ_FORCE_DIR_Z = 12;
  public const int PROJ_LIFETIME = 13;
  public const int PROJ_TELEPORT_X = 14;
  public const int PROJ_TELEPORT_Z = 15;
  public const int PROJ_CONTAGION = 16; // uint (reinterpreted)
  public const int PROJ_CONTAGION_DUR = 17;
  public const int PROJ_FLAGS = 18; // uint (reinterpreted)
  public const int PROJ_SOURCE = 19; // float body index, -1 = none
  public const int PROJ_TELEPORT_Y = 20; // float spawn height for teleport (world Y)

  // Projectile flag bits (must match projectile_compute.glsl)
  public const uint PROJ_FLAG_ALIVE = 1u;
  public const uint PROJ_FLAG_HAS_TELE = 2u;
  public const uint PROJ_FLAG_IS_HOG = 4u;

  // Contagion type bits (match STATE_ON_FIRE / POISONED / DRUNK)
  public const uint CONTAGION_FIRE = 256u;
  public const uint CONTAGION_POISON = 512u;
  public const uint CONTAGION_ALCOHOL = 1024u;

  // Projectile push-constant slots
  public const int PROJ_PUSH_DELTA_TIME = 0;
  public const int PROJ_PUSH_NUM_PROJ = 1;
  public const int PROJ_PUSH_NUM_BODIES = 2;
  public const int PROJ_PUSH_GRAVITY = 3;
  public const int PROJ_PUSH_Y_OFFSET = 4;
  public const int PROJ_PUSH_FRAME_PARITY = 5;
  public const int PROJ_PUSH_TIME = 6;
  public const int PROJ_PUSH_SIZE = 8 * sizeof(float); // 8 slots

  // Physics push-constant slots  (PHYSICS_PUSH_SIZE = 14 × sizeof(float))
  public const int PHYS_PUSH_DELTA_TIME = 0; // float delta_time
  public const int PHYS_PUSH_NUM_BODIES = 1; // int   num_bodies
  public const int PHYS_PUSH_TARGET_X = 2; // float target.x  (world X)
  public const int PHYS_PUSH_TARGET_Z = 3; // float target.y  (world Z)
  public const int PHYS_PUSH_ARRIVE_RADIUS = 4; // float arrive_radius
  public const int PHYS_PUSH_ROTATION_SPEED = 5; // float rotation_speed
  public const int PHYS_PUSH_TIME = 6; // float time
  public const int PHYS_PUSH_NUM_OBSTACLES = 7; // int   num_obstacles
  public const int PHYS_PUSH_NUM_BOMBS = 8; // int   num_bombs
  public const int PHYS_PUSH_BOMB_FEAR_DURATION = 9; // float bomb_fear_duration
  public const int PHYS_PUSH_GRAVITY = 10; // float gravity
  public const int PHYS_PUSH_Y_OFFSET = 11; // float y_offset
  public const int PHYS_PUSH_FRAME_PARITY = 12; // uint  frame_parity (0 or 1)
  public const int PHYS_PUSH_HOG_GRAVITY_SCALE = 13; // float hog_gravity_scale


  private int _numObstacles;
  private uint _obstacleBufferSize;
  private uint _bombBufferSize;
  private Node _global;
  private float _targetMarkerYOffset;
  private int _bodyCapacity;

  // Obstacle shape caches — avoid traversing the node tree every frame
  private List<CollisionShape3D> _staticShapes;
  private List<CollisionShape3D> _movableShapes;
  private float[] _staticObstacleData; // computed once, reused every frame

  // Nodes whose VisibilityChanged signal is connected for auto cache-invalidation.
  // Populated in EnsureObstacleCache(), cleared in InvalidateObstacleCache().
  private readonly List<Node3D> _visibilityTrackedNodes = [];

  // Trigger zones — pass-through shapes that affect hogs on contact.
  private List<TriggerZone> _triggerZones;

  // Deferred spawns: (zoneIdx, spawnPos, count). Processed after the zone loop so that
  // new body indices are known and can be added to _triggeredPairs in one pass.
  private readonly List<(int zoneIdx, Vector3 pos, int count)> _pendingTriggerSpawns = [];

  // One-shot per-(hog, zone) skip marks for Multiply and Add effects.
  // Clones spawned inside a zone are marked so the enter event they are born
  // into is swallowed; the mark is CONSUMED on that first enter, so a genuine
  // exit + re-entry triggers the zone again.
  // Encoded as ((long)zoneIdx << 32 | (uint)hogIdx) to avoid tuple boxing.
  // Dead hog entries linger harmlessly (indices are never recycled).
  private readonly HashSet<long> _triggeredPairs = [];

  // Scratch set reused for per-zone occupant tracking (zero per-frame allocation).
  private HashSet<int> _zoneOccupantsScratch = [];

  // Two pre-allocated dicts swapped each frame — no per-frame allocation for movable obstacles
  private Dictionary<CollisionShape3D, (Vector2 center, float yRot)> _prevObstacleState = [];
  private Dictionary<CollisionShape3D, (Vector2 center, float yRot)> _currentObstacleState = [];
  private RandomNumberGenerator _rndGen;

  // Per-body state tracking (allocated to _bodyCapacity, grown in SpawnHogs)
  private byte[] _hogStates; // current HogBehaviourState per body

  // Label management — distance-driven, updated every frame
  private HashSet<int> _labeledSet = []; // indices currently holding a pool slot
  private HashSet<int> _nextLabeledSet = []; // scratch set, swapped each frame (zero-alloc)
  private readonly List<(
    int index,
    float distSq,
    Vector3 worldPos,
    HogBehaviourState state
  )> _labelCandidates = [];

  // --- Pre-allocated staging buffers (zero per-frame heap allocations) ---
  public const int PHYSICS_PUSH_SIZE = 14 * sizeof(float); // 14 push constants

  private byte[] _physicsPushBytes;
  private float[] _bombStaging; // MAX_BOMBS * BOMB_STRIDE, reused every frame
  private byte[] _bombBytes; // byte view of bomb staging, reused every frame
  private float[] _obstacleStaging; // pre-allocated with capacity, grown if needed
  private byte[] _obstacleBytes; // byte view of obstacle staging, grown with it
  private int _obstacleCapacity; // current capacity in floats

  // Must match local_size_x in both compute shaders
  private const int GPU_THREAD_GROUP_SIZE = 64;

  // Body-buffer capacity growth. Deliberately tighter than the usual doubling because the
  // MultiMesh upload is sized by CAPACITY, not by live hog count: Multimesh.InstanceCount
  // tracks capacity (tying it to NumBodies instead would reallocate on every spawn), and
  // MultimeshSetBuffer must be handed InstanceCount * INSTANCE_STRIDE floats. So every unused
  // slot costs upload bandwidth every frame for the rest of the session. Doubling left up to
  // 50% of the buffer as dead weight — measured 40000 capacity carrying ~20000 live hogs,
  // i.e. 3.2 MB uploaded per frame to draw 1.6 MB of hogs. Growth events cost a few ms each
  // and are one-off, so trading more of them for a permanently tighter buffer is the right
  // way round. The absolute floor stops small capacities from growing by a rounding error.
  private const float BODY_CAPACITY_GROWTH = 1.25f;
  private const int BODY_CAPACITY_MIN_STEP = 256;

  [Signal]
  public delegate void HogDiedEventHandler(int index, Vector3 position, uint stateBits);

  /// <summary>
  /// Emitted each time a hog's enter event fires for a trigger zone.
  /// <list type="bullet">
  ///   <item><paramref name="hogIndex"/> — body slot index of the hog</item>
  ///   <item><paramref name="position"/> — world position of the hog at the moment of entry</item>
  ///   <item><paramref name="zone"/> — the CollisionShape3D node that carries the trigger metadata</item>
  ///   <item><paramref name="effect"/> — <see cref="TriggerEffect"/> cast to int (0=Damage, 1=Multiply, 2=Add)</item>
  /// </list>
  /// Not emitted for Multiply/Add when the hog is permanently immune (<c>_triggeredPairs</c>).
  /// Connect with <c>CONNECT_DEFERRED</c> if you need to run heavy visual work at idle time.
  /// </summary>
  [Signal]
  public delegate void HogZoneTriggeredEventHandler(
    int hogIndex,
    Vector3 position,
    CollisionShape3D zone,
    int effect
  );

  public override void _Ready()
  {
    _targetPos = new Vector2(TargetMarker.GlobalPosition.X, TargetMarker.GlobalPosition.Z);
    SetupMultiMesh();
    SetupCompute();
    _global = GetNode<Node>("/root/Global");
    _targetMarkerYOffset = TargetMarker.GlobalPosition.Y;
    _dropBombAction = DropBomb;
  }

  public override void _UnhandledInput(InputEvent @event)
  {
    if (@event.IsActionPressed("ui_accept"))
    {
      SpawnDropBomb(MouseGlobalPositionNode.GlobalPosition);
    }
    if (@event.IsActionPressed("show_hogs"))
    {
      ShowHogs = !ShowHogs;
      if (!ShowHogs)
      {
        Multimesh.VisibleInstanceCount = 0;
      }
    }

    if (@event.IsActionPressed("toggle_labels"))
    {
      _showStateLabels = !_showStateLabels;
      if (!_showStateLabels)
      {
        _labeledSet.Clear();
        _nextLabeledSet.Clear();
        _labelCandidates.Clear();
        _ = HogLabels.Call("release_all_labels");
      }
    }

    if ((bool)_global.Get("mouse_dragging"))
    {
      return;
    }

    if (_moveMarkerWithMouse && @event is InputEventMouseMotion)
    {
      UpdateTargetFromMouse();
    }

    if (@event is InputEventMouseButton { Pressed: true, ButtonIndex: MouseButton.Right })
    {
      _moveMarkerWithMouse = !_moveMarkerWithMouse;
      if (_moveMarkerWithMouse)
      {
        UpdateTargetFromMouse();
        TargetMarker.TranslateObjectLocal(new Vector3(0, 2.5f, 0));
      }
      else
      {
        TargetMarker.TranslateObjectLocal(new Vector3(0, -2.5f, 0));
      }
    }

    if (@event is InputEventMouseButton { DoubleClick: true, ButtonIndex: MouseButton.Left })
    {
      SpawnDropBomb(MouseGlobalPositionNode.GlobalPosition);
    }
  }

  private void SpawnDropBomb(Vector3 dropPoint) =>
    BombSpawner.SpawnBomb(dropPoint, Callable.From(_dropBombAction));

  public override void _Process(double delta)
  {
    if (Input.IsActionPressed("spawn_hogs"))
    {
      var spawnTarget = MouseGlobalPositionNode.GlobalPosition;
      var forceDir = spawnTarget.DirectionTo(TargetMarker.GlobalPosition).Normalized();
      SpawnHogs(
        10,
        spawnTarget,
        new Vector3(
          forceDir.X * _rndGen.RandfRange(5f, 15f),
          _rndGen.RandfRange(10f, 20f),
          forceDir.Z * _rndGen.RandfRange(5f, 15f)
        )
      );
    }
  }

  public override void _PhysicsProcess(double delta)
  {
    var fdelta = (float)delta;
    _time += fdelta;

    // Stage GPU buffer contents. These only queue work now; nothing touches the
    // RenderingDevice until FlushGpuCommands below, which also handles any buffer growth
    // and the uniform-set rebuilds that growth implies.
    UpdateObstacleBuffer(fdelta);
    UpdateBombBuffer(fdelta);

    // Tick projectile lifetimes and upload newly-spawned projectiles
    UpdateProjectileLifetimes(fdelta);
    UploadPendingProjectiles();

    // --- Physics + Transform pass (zero-alloc push constants) ---
    WritePhysicsPush(
      fdelta,
      NumBodies,
      _targetPos.X,
      _targetPos.Y,
      ArriveRadius,
      RotationSpeed,
      _time,
      _numObstacles,
      _activeBombs.Count,
      BombFearDuration
    );
    var workGroups = (uint)Mathf.CeilToInt((float)NumBodies / GPU_THREAD_GROUP_SIZE);

    // -------------------------------------------------------------------------
    // Spatial hash build + physics — chained in one command list.
    //
    // The build shader uses a 1-bit frame parity tag (bit 31 of hash_counts[])
    // to lazily reset stale buckets, eliminating the need for a separate clear
    // pass.  This keeps the total sync-point count at 2 (same as before spatial
    // hashing was added): one after hash+physics, one after transform.
    //
    // ComputeListAddBarrier ensures the hash writes are visible to the physics
    // dispatch.  The parity check in the physics shader is an additional safety
    // net: if the barrier is imperfect (known Metal edge case for storage-buffer
    // writes), physics silently treats those stale buckets as empty rather than
    // reading garbage body indices.
    // -------------------------------------------------------------------------
    WriteHashBuildPush(NumBodies, YOffset);
    WriteProjectilePush(fdelta, _time);

    // Apply every queued buffer mutation. This is the ONE place GPU buffers are written,
    // and it must stay immediately before the dispatch: commands queued anywhere earlier
    // (including from _Process and from last frame's trigger-zone pass) land here, in FIFO
    // order, so the shaders below see exactly the state they saw before the queue existed.
    FlushGpuCommands();

    // All GPU passes in a single command list — one Submit+Sync per frame.
    var cl = _rd.ComputeListBegin();

    // --- Hash build ---
    _rd.ComputeListBindComputePipeline(cl, _hashPipeline);
    _rd.ComputeListBindUniformSet(cl, _hashUniformSet, 0);
    _rd.ComputeListSetPushConstant(cl, _hashPushBytes, HASH_BUILD_PUSH_SIZE);
    _rd.ComputeListDispatch(cl, workGroups, 1, 1);
    _rd.ComputeListAddBarrier(cl); // hash writes → projectile + physics reads

    // --- Projectile (runs before physics so effects are visible to physics this frame) ---
    var projGroups = (uint)Mathf.CeilToInt((float)MAX_PROJECTILES / GPU_THREAD_GROUP_SIZE);
    _rd.ComputeListBindComputePipeline(cl, _projPipeline);
    _rd.ComputeListBindUniformSet(cl, _projUniformSet, 0);
    _rd.ComputeListSetPushConstant(cl, _projPushBytes, PROJ_PUSH_SIZE);
    _rd.ComputeListDispatch(cl, projGroups, 1, 1);
    _rd.ComputeListAddBarrier(cl); // projectile atomics → physics reads

    // --- Physics ---
    _rd.ComputeListBindComputePipeline(cl, _physicsPipeline);
    _rd.ComputeListBindUniformSet(cl, _physicsUniformSet, 0);
    _rd.ComputeListSetPushConstant(cl, _physicsPushBytes, PHYSICS_PUSH_SIZE);
    _rd.ComputeListDispatch(cl, workGroups, 1, 1);
    _rd.ComputeListAddBarrier(cl); // physics writes bodies[] → transform reads bodies[]


    _rd.ComputeListEnd();
    _rd.Submit();
    _rd.Sync();

    // Toggle parity after GPU work is complete.
    _hashFrameParity ^= 1u;

    if (DebugHashOverflow)
    {
      SampleHashOverflow(delta);
    }

    // --- Readback: BufferGetData allocates the returned array (Godot API limitation),
    // but everything downstream reads it in place via Span<float> — no further copies.
    //
    // Only the live prefix is transferred. The buffer is sized to _bodyCapacity, but every
    // consumer below (the compaction loop, UpdateLabels, ProcessTriggerZones) indexes by body
    // id and stops at NumBodies, so the slack slots were being copied and allocated for
    // nothing. ---
    var readbackBytes = (uint)(NumBodies * INSTANCE_STRIDE * sizeof(float));
    var outputBytes = _rd.BufferGetData(_transformBuffer, 0, readbackBytes);
    var gpuFloats = MemoryMarshal.Cast<byte, float>(outputBytes.AsSpan());

    if (_showStateLabels)
    {
      _timeSinceLastLabelUpdate += delta;
      var forceRecalculate = _timeSinceLastLabelUpdate >= 0.1;
      if (forceRecalculate)
      {
        _timeSinceLastLabelUpdate = 0;
      }
      UpdateLabels(gpuFloats, forceRecalculate);
    }

    if (_deathFxQueue.Count > 0)
    {
      DrainDeathFxQueue();
    }

    // Compact directly from GPU readback into _transformFloats — only alive
    // instances are copied, skipping the previous full-buffer BlockCopy.
    // STATE_DEAD is the authoritative source for death; this loop runs every frame
    // regardless of whether labels are shown, so OnHogDied always fires.
    var aliveCount = 0;
    var dst = _transformFloats.AsSpan();
    for (var i = 0; i < NumBodies; i++)
    {
      var src = i * INSTANCE_STRIDE;
      var stateBits = BitConverter.SingleToUInt32Bits(gpuFloats[src + INST_STATE]);
      if ((stateBits & STATE_DEAD) != 0)
      {
        if (_deadHogs.Add(i))
        {
          OnHogDied(i, gpuFloats[src + INST_ORIGIN_X], gpuFloats[src + INST_ORIGIN_Z], stateBits);
          _ = HogLabels?.Call("release_label", i);
        }
        continue;
      }

      gpuFloats
        .Slice(src, INSTANCE_STRIDE)
        .CopyTo(dst.Slice(aliveCount * INSTANCE_STRIDE, INSTANCE_STRIDE));
      aliveCount++;
    }

    if (_triggerZones is { Count: > 0 })
    {
      ProcessTriggerZones(gpuFloats);
    }

    if (ShowHogs)
    {
      Multimesh.VisibleInstanceCount = aliveCount;
      RenderingServer.MultimeshSetBuffer(Multimesh.GetRid(), _transformFloats);
    }
  }

  private void UpdateTargetFromMouse()
  {
    var hit = MouseGlobalPositionNode.GlobalPosition;
    _targetPos = new Vector2(hit.X, hit.Z);

    if (TargetMarker == null)
    {
      return;
    }
    TargetMarker.GlobalPosition = new Vector3(hit.X, TargetMarker.GlobalPosition.Y, hit.Z);
  }

  public void SpawnHogs(int count, Vector3 position, Vector3 initialVelocity = default)
  {
    var newCount = NumBodies + count;
    var newSquadsData = new GpuBody[count];

    var heightVal = initialVelocity.Y > 0.1f ? Math.Max(position.Y, YOffset + 0.02f) : position.Y;

    for (var i = 0; i < count; i++)
    {
      newSquadsData[i] = new GpuBody
      {
        Position = new Vector2(position.X, position.Z),
        Velocity = new Vector2(initialVelocity.X, initialVelocity.Z),
        Height = heightVal,
        VerticalVelocity = initialVelocity.Y,
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

    var newBytes = MemoryMarshal.Cast<GpuBody, byte>(newSquadsData.AsSpan());
    var writeOffset = (uint)(NumBodies * BODY_STRIDE * sizeof(float));

    // Capacity growth is queued ahead of the body write so the write resolves to the grown
    // buffer. _bodyCapacity is bumped here on the spot, so a second SpawnHogs later in the
    // same frame sees the new capacity and does not queue a redundant growth.
    if (newCount > _bodyCapacity)
    {
      var newCapacity = Math.Max(
        newCount,
        Math.Max(
          _bodyCapacity + BODY_CAPACITY_MIN_STEP,
          (int)(_bodyCapacity * BODY_CAPACITY_GROWTH)
        )
      );
      EnqueueGrowPhysics(newCapacity, (int)writeOffset);
      _bodyCapacity = newCapacity;
      Array.Resize(ref _hogStates, newCapacity);
    }

    EnqueueGpuWrite(GpuTarget.Physics, writeOffset, newBytes);
    NumBodies = newCount;
  }
}
