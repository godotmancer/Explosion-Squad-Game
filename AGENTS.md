# AGENTS.md — AI Agent Guide for Explosion Squad Game

This file explains *why* the code is shaped the way it is, *how* each system fits together, and *what
to watch out for* when making changes. Read both before touching anything.

---

## Table of Contents

1. [One-Paragraph Mental Model](#1-one-paragraph-mental-model)
2. [Build & Run](#2-build--run)
3. [Repository Layout](#3-repository-layout)
4. [Language Split — The Prime Directive](#4-language-split--the-prime-directive)
5. [GPU Physics Pipeline](#5-gpu-physics-pipeline)
6. [The C# God-Class and Its Partials](#6-the-c-god-class-and-its-partials)
7. [Buffer Layout Contracts](#7-buffer-layout-contracts)
8. [Projectile System — End to End](#8-projectile-system--end-to-end)
9. [Obstacle & Trigger Zone System](#9-obstacle--trigger-zone-system)
10. [Signal Architecture](#10-signal-architecture)
11. [Core Patterns & Conventions](#11-core-patterns--conventions)
12. [Performance Rules](#12-performance-rules) · [12.1 Measured reality](#121-measured-reality--read-this-before-optimizing-compute)
13. [Making Changes — by Task Type](#13-making-changes--by-task-type)
14. [Common Gotchas](#14-common-gotchas)
15. [Verification Checklist](#15-verification-checklist)

---

## 1. One-Paragraph Mental Model

Explosion Squad game simulates up to 20 000 hogs entirely on the GPU. Every physics frame the
CPU drains its deferred GPU command queue, dispatches three compute shaders
(hash → projectile → physics) in one command list, calls `Submit()` + `Sync()`, and reads the
resulting transform buffer back to update the MultiMesh in one RenderingServer call.
The CPU never writes individual hog positions; it only reads them to detect deaths and
trigger zones.
GDScript handles everything visible (projectile meshes, FX, labels, UI, camera);
C# handles everything that talks to the GPU. That single boundary — "GPU state lives
in C#, visual state lives in GDScript" — explains almost every architectural decision
in this codebase.

---

## 2. Build & Run

`godotx` is symlinked to the latest master branch of a source compiled Godot binary (currently Godot v4.8-dev).
If `godotx` is not found then use `godot` as the launcher.

```bash
# Compile C# assembly only (fast — use after every C# edit)
dotnet build --nologo

# Launch editor
godotx --path .

# Run main scene headless (no editor)
godotx --path . res://Main.tscn

# Re-import after editing any .glsl — MANDATORY, see gotcha in §14
godotx --path . --import

# Validate a compute shader without launching Godot (strip the Godot-only first line)
grep -v '^#\[compute\]' compute_shaders/physics_compute.glsl > /tmp/p.comp
glslangValidator --target-env vulkan1.1 -S comp /tmp/p.comp
```

`dotnet build` must report **0 warnings, 0 errors** before any task is considered
done. The project uses the `godotx` CLI wrapper.

Notes on the validator invocation: `--target-env vulkan1.1` is required or `push_constant`
is rejected. Use `grep -v` rather than `sed '1d'` to strip the `#[compute]` line — several
shaders open with a comment block, so the directive is not always on line 1. Delete the
`comp.spv` it drops in the cwd.

---

## 3. Repository Layout

```
Explosion-Squad-Game/
├── compute_shaders/          # C# GPU manager + 3 GLSL compute shaders
│   ├── SquadMultiMeshInstance3D.cs          # Orchestrator — types, fields, lifecycle
│   ├── SquadMultiMeshInstance3D.GpuSetup.cs # Setup, Dispose, push constants, RebuildXxx
│   ├── SquadMultiMeshInstance3D.GpuQueue.cs # Deferred GPU command queue + buffer growth
│   ├── SquadMultiMeshInstance3D.Obstacles.cs# Obstacle cache, OBB/circle emit, UpdateObstacleBuffer
│   ├── SquadMultiMeshInstance3D.Projectiles.cs # Slot pool, SpawnProjectile, UploadPending
│   ├── SquadMultiMeshInstance3D.Bombs.cs    # Bomb buffer, death FX pool, OnHogDied
│   ├── SquadMultiMeshInstance3D.TriggerZones.cs # Zone detection, deferred spawns
│   ├── SquadMultiMeshInstance3D.Labels.cs   # Distance-sorted label assignment
│   ├── physics_compute.glsl                   # Boids, obstacles, bombs, contagion, instance write
│   ├── projectile_compute.glsl                # Projectile integration + sphere collision
│   └── spatial_hash_build.glsl                # O(1) spatial hash construction
├── projectiles/              # GDScript visual projectiles + C# spawner facade
│   ├── ProjectilesSpawner.cs                  # GDScript-callable C# facade
│   ├── ProjectileBase.gd                      # Base visual projectile (Euler integration)
│   ├── ProjectileAbility.gd                   # Resource class for ability data
│   └── *.tres                                 # Bullet, Fire, Poison, Drunk, Teleport abilities
├── bombs/
│   └── BombSpawner.cs                         # Spawns bomb visual + invokes DropBomb callback
├── components/               # GDScript @tool components (Animator, LookAtTracker)
├── visuals/                  # GDScript FX (DrawableGround, HogLabels, Announce3D, DeathFx)
├── compositor_fx/            # Post-process Outline effect (GDScript + GLSL)
├── shaders/                  # Visual-only gdshaders (black hole, openvat, broken TV)
├── ui/                       # GDScript UI nodes (Fps, HogsKilled, TotalHogs) + TrajectoryOverlay.cs
├── assets/animal_hog_merged.tres  # Single-surface baked hog mesh used by the MultiMesh
├── Main.gd                   # Input dispatch, projectile spawn keys 1–5
├── Global.gd                 # @tool Autoload — state enums + cross-system signals
└── AGENTS.md                 # This file
```

---

## 4. Language Split — The Prime Directive

| Concern | Language | Why |
|---------|----------|-----|
| Compute shader dispatch (`RenderingDevice`) | **C#** | Godot's local RD is C#-only in practice |
| Buffer reads / writes / GPU sync | **C#** | Needs zero-alloc `MemoryMarshal` spans |
| MultiMesh transform upload | **C#** | `RenderingServer.MultimeshSetBuffer` is the hot path |
| Projectile physics (visual) | **GDScript** | Runs same Euler as shader — stays frame-exact |
| All UI, FX, camera, components | **GDScript** | Fast iteration, no recompile cycle |
| Resources (`*.tres`) | **GDScript** | `ProjectileAbility`, `WeaponData`-style data objects |

**Never** put GPU state management in GDScript. **Never** put visual/UI logic in C#.
When in doubt: if it talks to `RenderingDevice` or `RenderingServer`, it's C#.

---

## 5. GPU Physics Pipeline

One physics frame, in order:

```
CPU                                 GPU
 │                                   │
 ├─ WritePhysicsPush                 │
 ├─ WriteHashBuildPush               │
 ├─ WriteProjectilePush              │
 │                                   │
 ├─ FlushGpuCommands()               │  ← the ONE place GPU buffers are mutated
 │                                   │
 ├─ ComputeListBegin()               │
 │   ├─ Dispatch spatial_hash_build  ┤─ writes hash_counts[], hash_entries[]
 │   ├─ ComputeListAddBarrier        │
 │   ├─ Dispatch projectile_compute  ┤─ moves projectiles, sphere-sphere hit,
 │   │                               │  atomic damage_accum on bodies[]
 │   ├─ ComputeListAddBarrier        │
 │   └─ Dispatch physics_compute     ┤─ boids, obstacle avoidance, bombs, fear
 │                                   │  impulses, contagion spread, THEN writes
 │                                   │  instance_buffer[] from its own tail
 ├─ ComputeListEnd()                 │
 ├─ Submit() + Sync()                │
 │                                   │
 ├─ BufferGetData(transformBuffer)   │  ← only CPU read per frame (live prefix only)
 ├─ Compact alive instances          │
 ├─ ProcessTriggerZones              │  (CPU-side shape tests on transform data)
 └─ MultimeshSetBuffer               │  ← only RenderingServer write per frame
```

**Critical ordering constraint:** hash build → projectile → physics.
The projectile shader atomically writes `damage_accum` into `bodies[]` which the
physics shader reads the same frame. The barrier between them is mandatory.

**There is no fourth pass.** `transform_compute.glsl` was deleted; physics_compute writes
the instance buffer in its tail via binding 5, as five coalesced `vec4` stores, reusing the
`Body` it already has in registers. Dead bodies take an early-out path that still writes
their `INSTANCE_CUSTOM` row (so the CPU compaction loop can see `STATE_DEAD`) and skip
everything else. The C# field is still named `_transformBuffer` — the name outlived the
shader.

**Deferred GPU command queue (`GpuQueue.cs`).** Nothing outside that file calls a
`RenderingDevice` mutator. Callers record commands; `FlushGpuCommands()` applies them
immediately before the compute list is recorded. Two invariants make this behaviour-preserving
across buffer growth:

* Commands are applied strictly FIFO.
* A command names its target by `GpuTarget` enum, **not** by `Rid`, and the Rid is resolved at
  drain time. A write queued before a growth command lands in the old buffer and is copied
  forward by the growth; one queued after lands in the new buffer. Either way it survives.

This exists as the prerequisite for eventually moving off the local `RenderingDevice` onto the
global one (which may only be touched on the rendering thread). Do not reintroduce a direct
`_rd.BufferUpdate` call outside `GpuQueue.cs` — it would break that migration path and the
FIFO ordering guarantee.

**Frame parity:** `_hashFrameParity` toggles 0 ↔ 1 each physics frame. The hash
build shader uses it to lazily invalidate stale buckets without a separate clear
pass. Both the hash build and physics push constants must receive the *same* parity
value within a single frame. It is flipped *after* `Sync()`.

---

## 6. The C# God-Class and Its Partials (to be refactored out)

`SquadMultiMeshInstance3D` is split into 8 `partial class` files. All live in
`compute_shaders/`. The class is `sealed`, so `partial` is the only safe split
mechanism — it preserves the public API and requires no scene-file changes.

| File | What lives there |
|------|-----------------|
| `SquadMultiMeshInstance3D.cs` | All `[Export]` properties, all inner types (`GpuBody`, `BombState`, `ProjectileAbility`, enums), all `[Signal]` declarations, all private field declarations, all buffer-layout constants, lifecycle (`_Ready` / `_Process` / `_PhysicsProcess` / `_UnhandledInput`), `SpawnHogs`, `UpdateTargetFromMouse` |
| `GpuSetup.cs` | `SetupCompute`, `SetupMultiMesh`, `Dispose`, `WriteXxxPush`, `RebuildXxxUniformSet`, `VerifyPipeline`, `SampleHashOverflow` |
| `GpuQueue.cs` | `GpuTarget` / `GpuCommandKind` enums, `GpuCommand` struct, `_gpuCommands` / `_gpuPayload` / `_gpuScratch`, `EnqueueGpuWrite`, `EnqueueGrowPhysics`, `EnqueueGrowObstacles`, `FlushGpuCommands`, `ResolveGpuTarget`, `ApplyPhysicsGrowth`, `ApplyObstacleGrowth`, `FreeGpuRid`. **The only file allowed to call `RenderingDevice` mutators.** |
| `Obstacles.cs` | Obstacle cache, `ExtractObstacles`, `EmitObstacleDataArray/List`, `WriteObstacle`, `ComputeMinObb`, `DecomposeTrimeshFootprint`, `ObstacleSlotCount`, `FindCollisionShapes`, `UpdateObstacleBuffer` |
| `Projectiles.cs` | `SpawnProjectile`, `UploadPendingProjectiles`, `UpdateProjectileLifetimes`, `RegisterProjectileHitCallback`, `WriteProjectilePush` |
| `Bombs.cs` | `DrainDeathFxQueue`, `OnDeathFxFinished`, `OnHogDied`, `DropBomb`, `UpdateBombBuffer` |
| `TriggerZones.cs` | `ProcessTriggerZones`, `DamageHogViaBuffer`, `ScanForTriggers`, `GetTriggerBounds`, `IsInsideCircle/OBB`, `TriggerKey` |
| `Labels.cs` | `_timeSinceLastLabelUpdate` field, `UpdateLabels`, `ClassifyState`, `IsLabelOnScreen` |

**Rule:** all field *declarations* stay in the main `.cs` file, with two deliberate
exceptions: `_timeSinceLastLabelUpdate` (label-specific state) and everything in
`GpuQueue.cs` (whose types and buffers are private to the queue and must not be reachable
from elsewhere). Method implementations go into whichever partial file owns that concern.

---

## 7. Buffer Layout Contracts

Every constant in `SquadMultiMeshInstance3D.cs` that starts with `PROJ_`, `PHYS_`,
`INST_`, `BOMB_`, `OBS_`, or `HASH_` is a direct index into a GPU buffer. Changing
any of these **requires a matching change in the corresponding `.glsl` file** or the
game will silently corrupt physics data.

### GpuBody (physics_compute.glsl `struct Body`)

`BODY_STRIDE = 28` floats. Declared as `[StructLayout(LayoutKind.Sequential, Pack = 4)]`.
The field order in `GpuBody` must exactly match the GLSL struct layout. Adding fields
requires updating both the C# struct AND the shader, and re-initializing buffer sizes.

`struct Body` is duplicated in **four** places — there is no GLSL `#include`, so this is
manual. All four carry a `⚠ KEEP IN SYNC` header listing the others:

```
compute_shaders/physics_compute.glsl
compute_shaders/spatial_hash_build.glsl
compute_shaders/projectile_compute.glsl
compute_shaders/SquadMultiMeshInstance3D.cs   (struct GpuBody, BODY_STRIDE)
```

**Fields owned by atomics.** `state` (14), `damage_accum` (16), `contagion_expiry_u` (17) and
`dps_rate_u` (18) are written only through atomic ops, by more than one invocation.
`physics_compute` therefore does **not** write `bodies[id] = self` — that would clobber a
neighbour's concurrent atomic. It writes 17 explicit fields instead, deliberately omitting the
four atomic-owned ones plus `radius`, `mass`, `teleport_x/z/y` and `pad3`, which are never
modified on the GPU. If you add a body field, decide which category it is in and update that
write block accordingly.

### Contagion encoding

`contagion_expiry_u` is an **absolute expiry timestamp** (`time × CONT_TIME_SCALE`, 256), not
a countdown. It is only ever raised, via `atomicMax`. This is what makes it safe under
concurrent writes — a decrementing timer cannot be expressed with a single commutative atomic,
and the earlier countdown version had a bug where `max(local_decremented, stored)` restored the
pre-decrement value every frame, so contagion never expired at all.

Consequences to preserve:

- `cont_active` is `self.contagion_expiry_u > now_u`. Never test for zero.
- Contagion **type bits are sticky**. They are cleared only by the *first* infector — the
  invocation whose `atomicMax` observes `prev_expiry <= now_u` — which then clears the type
  mask and DPS before OR-ing its own in. Clearing them anywhere else races with a neighbour
  that has just set a bit and wipes it while the raised expiry survives.
- Spread hands the neighbour a *fraction* of the parent's remaining time
  (`CONTAGION_SPREAD_DECAY = 0.6`), capped per type (`FIRE_SPREAD_MAX_DUR`,
  `POISON_SPREAD_MAX_DUR`) and floored at `CONTAGION_MIN_SPREAD_DUR = 0.35`. That floor is
  what terminates the chain; without it, spread runs until every connected hog is infected.
- The colour tint fades over `CONTAGION_FADE_TIME = 1.5` s of remaining time, so the visual
  decays with the effect.
- **`.tres` durations are calibrated against this.** `contagion_duration` on the projectile
  resources was once 0.05 s, which only ever looked correct because contagion never expired.
  If you change the expiry model again, re-tune those values.

### Projectile (projectile_compute.glsl `struct Projectile`)

`PROJ_STRIDE = 24` floats. Slot 18 (`PROJ_FLAGS`) is a `uint` reinterpreted as
`float` — use `BitConverter.UInt32BitsToSingle` / `SingleToUInt32Bits` to read/write.
Slot 16 (`PROJ_CONTAGION`) is the same encoding. Never write raw `uint` values to
a `float[]` buffer directly.

### Instance (physics_compute.glsl tail output, binding 5)

`INSTANCE_STRIDE = 20` floats per instance = `INSTANCE_VEC4S = 5` vec4 rows, matching Godot's
row-major MultiMesh layout. Slots 16–19 are `INSTANCE_CUSTOM` (R/G/B/A). Slot 17
(`INST_HEALTH`) and slot 18 (`INST_STATE`) are read back by the CPU compaction loop and trigger
zone tests every frame.

The shader declares the buffer as `vec4 instances[]` and indexes rows, so the C# float indices
map as `INST_ROW_CUSTOM = 4` ↔ `INST_CUSTOM_R = 16`. Keep both sides in step: the C# constants
are float offsets, the GLSL constants are vec4 offsets.

### Spatial hash

| Constant | Value | Note |
|----------|-------|------|
| `HASH_TABLE_SIZE` | 32768 | **Must be a power of two** — shaders mask with `size - 1` |
| `HASH_MAX_PER_CELL` | 64 | Query loop runs `count` times, not this many |
| `HASH_CELL_SIZE` | 2.0 | GLSL-only |
| `HASH_OVERFLOW_SLOT` | `HASH_TABLE_SIZE` | One extra uint past the table; cannot collide with a real bucket |
| `HASH_COUNTS_BUFFER_SIZE` | `(HASH_TABLE_SIZE + 1) * 4` | The `+ 1` is the overflow slot |

Oversizing the table is free at runtime, not just cheap: the frame-parity scheme means nothing
ever iterates the table, so a bucket no body hashes to is never touched. The only cost is the
fixed allocation (128 KB counts + 8 MB entries). This is why it is a constant rather than
scaling with body count — a game starting with five hogs pays the VRAM and zero per-frame time.

Per-cell overflow is a graceful no-op (the body is invisible as a neighbour for one frame) but
is **counted**, not silent: `atomicAdd(hash_counts[HASH_OVERFLOW_SLOT], 1u)`. Set the
`DebugHashOverflow` export to have C# sample it at 1 Hz. Non-zero means raise
`HASH_MAX_PER_CELL` or shrink `HASH_CELL_SIZE`. The symptom otherwise — hogs walking through
each other in a dense pile — is very hard to attribute.

### Push Constant Sizes

| Shader | Size | Constant |
|--------|------|----------|
| `spatial_hash_build.glsl` | 16 bytes (4 × float) | `HASH_BUILD_PUSH_SIZE` |
| `projectile_compute.glsl` | 32 bytes (8 × float) | `PROJ_PUSH_SIZE` |
| `physics_compute.glsl` | 56 bytes (14 × float) | `PHYSICS_PUSH_SIZE` |
| `compositor_fx/Outline.glsl` | 72 bytes (mat4 64B + vec2 8B) | hardcoded in `Outline.gd` |

Push constant byte arrays are pre-allocated once and reused every frame.
`MemoryMarshal.Cast<byte, float/int/uint>` overlays them as typed spans — zero
allocation, zero copy.

---

## 8. Projectile System — End to End

### Spawn path

```
GDScript (Main.gd / ability resource)
  └─ ProjectileBase.launch(from, to)           # creates visual projectile node
       ├─ ProjectilesSpawner.SpawnProjectileWithVelocity(pos, vel, ability)
       │    └─ SquadMultiMeshInstance3D.SpawnProjectile(pos, vel, ability)
       │         ├─ Dequeue slot from _projFreeSlots
       │         ├─ Write floats into _projAllStagingFloats[slot * PROJ_STRIDE + ...]
       │         └─ Enqueue slot index into _pendingProjSpawns
       └─ ProjectilesSpawner.RegisterProjectileHitCallback(slot, _on_gpu_hit)
```

Staging floats are uploaded to GPU in `UploadPendingProjectiles()` called at the
*start* of the next `_PhysicsProcess`, before compute dispatch — so every spawned
projectile is live on the GPU within one physics frame.

### Kill path (GPU-initiated)

```
projectile_compute.glsl clears PROJ_FLAG_ALIVE in flags slot
  → UpdateProjectileLifetimes() detects flag cleared (readback every 2 frames)
       ├─ Fires _projHitCallbacks[slot](hitPos)
       │    └─ ProjectileBase._on_gpu_hit(pos) → kill(pos, HitType.HOG)
       └─ Clears alive flag in GPU buffer, enqueues slot back to _projFreeSlots
```

### Kill path (lifetime expiry)

```
C# _projLifetimes[slot] ticks to zero
  → Writes _zeroFlagBytes to GPU PROJ_FLAGS offset
  → Enqueues slot back to _projFreeSlots
```

### Ability Dictionary (GDScript → C# bridge)

`ProjectilesSpawner.ParseAbility()` reads a `GodotObject` (resource or dict) using
`GetObj<T>` / `GetBoolObj` / `GetV3Obj`. All three helpers check
`v.VariantType != Variant.Type.Nil` before casting — do not use raw `.As<T>()` on
potentially-nil Godot properties.

---

## 9. Obstacle & Trigger Zone System

### Two kinds of shapes under `ObstaclesRoot`

| Category | Node path | GPU buffer | Detected by |
|----------|-----------|------------|-------------|
| Solid obstacles | `ObstaclesRoot/Static/*` or `ObstaclesRoot/Movable/*`, **no** trigger metadata | Yes — pushed to obstacle buffer every frame | GPU physics shader |
| Trigger zones | Any `CollisionShape3D` with metadata key `damage`, `multiply`, or `add` | **No** — hogs pass through | CPU, `ProcessTriggerZones()` reads transform readback |

### Cache lifecycle

`_staticShapes`, `_movableShapes`, `_staticObstacleData`, and `_triggerZones` are
null until first use (`EnsureObstacleCache()`), then held until `InvalidateObstacleCache()`
is called. Visibility changes on any `Node3D` under `ObstaclesRoot` auto-fire
`InvalidateObstacleCache` via connected signals — **except** trigger zone shapes
(connecting them would race with `ProcessTriggerZones`).

### Movable obstacles

Velocity is computed each frame as `(currentPos - prevPos) / delta` using two
pre-allocated dictionaries that are *swapped* (not reallocated). Angular velocity
is derived the same way from Y-axis Euler angle delta, wrapped into `[-π, π]`.

### Supported shape types

`SphereShape3D` and `CylinderShape3D` → circle obstacle.
`BoxShape3D` → OBB.
`ConvexPolygonShape3D` → minimum OBB computed by `ComputeMinObb`
(rotating-calipers approximation).
`ConcavePolygonShape3D` → **multiple** OBBs, one per rectangle of the decomposed
X-Z footprint (`DecomposeTrimeshFootprint`). A single OBB would fill in the mesh's
holes, so hogs would skirt a hollow play pen instead of walking into it.

The decomposition projects every triangle onto X-Z (for a closed mesh this covers
exactly the footprint, while holes stay empty because the walls bounding them
project to zero-area lines), rasterises them onto a grid whose lines are the vertex
coordinates themselves, then greedily merges solid cells into maximal rectangles.
Exact for the rectilinear footprints CSG bakes produce — the `PlayPen` U-shape
resolves to 3 wall OBBs. Meshes with more than `FOOTPRINT_MAX_SLABS` distinct
coordinates on an axis fall back to a uniform grid (stair-stepped, warns); output is
capped at `FOOTPRINT_MAX_RECTS` per shape (warns).

Because a shape can emit more than one obstacle, buffer sizing goes through
`ObstacleSlotCount` — **keep it in sync with `EmitObstacleData`**. Results are cached
in `_concaveFootprints`, keyed on the shape resource: the rects are shape-local, so
they survive movement and `InvalidateObstacleCache`, and `GetFaces()` (which
allocates) stays off the per-frame path for movable trimeshes.

---

## 10. Signal Architecture

All cross-system signals are declared on the `Global` autoload (`Global.gd`).
Components connect to `Global`, never to each other directly.

```
Global.gd signals:
  projectile_impact(pos: Vector3, hit_type: HitType)   ← fired by ProjectileBase.kill()
  projectile_launched(from: Vector3, to: Vector3)      ← fired by ProjectileBase.launch()
  score_hit(ui_marker: Marker2D)                       ← fired by HogsKilled.gd
  notification_wrapped                                 ← fired when UI notification wraps

SquadMultiMeshInstance3D C# signals:
  HogDied(index, position, stateBits)               ← fired in OnHogDied()
  HogZoneTriggered(hogIndex, position, zone, effect)  ← fired in ProcessTriggerZones()
  HogStateChanged(index, newState, worldPos)        ← declared, unused (available for GDScript)
```

GDScript components connect to C# signals using Godot's `connect()` or `+=` syntax.
When connecting from GDScript to a C# signal with a deferred connection
(`CONNECT_DEFERRED`), use it for any handler that spawns nodes or modifies physics
state — avoids mid-frame mutations.

---

## 11. Core Patterns & Conventions

### Zero-allocation per-frame (C#)

The entire physics loop in `_PhysicsProcess` allocates nothing on the managed heap.
Key mechanisms:

- **Push constants:** `byte[]` pre-allocated in `SetupCompute`, overlaid with
  `MemoryMarshal.Cast<byte, float/int/uint>` spans.
- **Obstacle staging:** `float[] _obstacleStaging` + `byte[] _obstacleBytes` grown
  with headroom, never shrunk, copied with `Buffer.BlockCopy`.
- **Projectile staging:** `float[] _projAllStagingFloats` (size `MAX_PROJECTILES *
  PROJ_STRIDE`) written in `SpawnProjectile`, copied per-slot in
  `UploadPendingProjectiles` into `byte[] _projSlotUploadBytes`.
- **Movable obstacle state:** two `Dictionary<CollisionShape3D, (Vector2, float)>`
  swapped each frame via tuple assignment — no new dictionary allocated.
- **Label sets:** two `HashSet<int>` swapped after each full recalculation.
- **Death FX:** pooled `Queue<Node3D>` capped at `MAX_POOLED_DEATH_FX`.

If you introduce a new per-frame code path in `_PhysicsProcess` or any method it
calls transitively, verify it does not allocate.

### uint-as-float encoding

State bits, contagion flags, and projectile flags are `uint` values packed into
`float` slots in GPU buffers. Always use:

```csharp
// Write:
buffer[offset + PROJ_FLAGS] = BitConverter.UInt32BitsToSingle(flagsUint);
// Read:
var bits = BitConverter.SingleToUInt32Bits(floatValue);
```

Never cast directly: `(float)myUint` produces an integer-to-float conversion, not
a reinterpret, and will produce garbage.

### GDScript resource pattern

Ability data lives in `*.tres` files (`ProjectileAbility` subclass). For runtime
variants, `duplicate()` the resource before mutating it:

```gdscript
var new_ability := projectile_teleport_ability.duplicate()
new_ability.teleport_pos = teleport_marker.global_position
```

Mutating a shared resource directly changes it for every future spawn.

### Deferred GPU writes

`_rd.BufferUpdate()` inside `_PhysicsProcess` is deferred to the GPU command queue —
it does not take effect until `Submit()`. Calling it *after* `Sync()` in the same
frame means the next frame sees the update. This is the expected pattern for
`DamageHogViaBuffer` and projectile reclaim writes.

### Uniform set lifecycle

Uniform sets are invalidated whenever a referenced buffer is freed and recreated
(e.g., `SpawnHogs` reallocating `_physicsBuffer`). When any buffer RID changes:
1. Set the affected uniform set fields to `new Rid()`.
2. Call the corresponding `RebuildXxxUniformSet()` before the next dispatch.

There are **three** uniform sets — `_physicsUniformSet`, `_hashUniformSet`,
`_projUniformSet` — since the transform set went away with its shader. All three reference
`_physicsBuffer`, so a body buffer reallocation must rebuild all three.

`_physicsUniformSet` spans bindings 0–5: bodies, obstacles, bombs, hash counts, hash entries,
instances. Binding 5 (the instance buffer) means `_transformBuffer` must exist *before*
`RebuildPhysicsUniformSet()` is called — check the ordering in `SetupCompute` if you move
buffer creation around.

Free uniform sets **before** the buffers they reference, not after. `ApplyPhysicsGrowth` was
leaking four sets per growth event until this was fixed.

---

## 12. Performance Rules

These are non-negotiable. Do not introduce patterns that violate them.

1. **No per-frame heap allocations in `_PhysicsProcess` or any callee.** Use
   pre-allocated staging buffers, span overlays, and `Buffer.BlockCopy`.

2. **No `get_nodes_in_group` or `get_children` in `_PhysicsProcess` or
   `_physics_process`.** Cache node references at `_ready` time.

3. **One GPU submit per physics frame.** All three dispatches must be in a single
   `ComputeListBegin → End → Submit → Sync` sequence.

4. **No additional `BufferGetData` calls beyond the existing transform readback, the
   throttled projectile flag readback, and the 1 Hz hash-overflow sample (which only runs
   when `DebugHashOverflow` is set).** Each `BufferGetData` forces a GPU sync stall.

4a. **All GPU buffer mutations go through `EnqueueGpuWrite` / `EnqueueGrowXxx`.** Do not call
   `_rd.BufferUpdate`, `_rd.BufferCopy` or `_rd.BufferClear` outside `GpuQueue.cs`. See §5.

4b. **Read back only the live prefix.** The transform readback is
   `NumBodies * INSTANCE_STRIDE * sizeof(float)`, not the full `_bodyCapacity`. Every consumer
   indexes by body id and stops at `NumBodies`, so copying the slack was pure waste.
   `BODY_CAPACITY_GROWTH` is 1.25 with a `BODY_CAPACITY_MIN_STEP` of 256 — the old 2× doubling
   left up to half the buffer unused. Note the tension: growth is amortised O(1) at 2× and
   worse at 1.25×, which is acceptable here only because growth is rare and the per-frame
   readback saving is constant.

5. **Projectile flag readback is throttled to every 2 physics frames.** It only
   runs when at least one uploaded slot is active. Do not remove the `anyActive`
   guard.

6. **Dead hogs are never removed from the body buffer.** `STATE_DEAD` is the
   authoritative marker. The compaction loop skips dead bodies when building the
   MultiMesh buffer. Body indices are permanent for the lifetime of the scene.

7. **MaxVisibleLabels = 50.** Label update is throttled to 10 Hz. Do not make label
   updates per-frame or uncapped.

8. **`DrawableGround` pre-bakes rotated/tinted textures at startup.** Do not add
   per-frame texture operations there.

9. **The hog mesh must stay a single surface.** `assets/animal_hog_merged.tres` exists because
   the Kenney source `.obj` had 5 surfaces that all rendered with the same material — 5 draw
   calls per hog per pass, doubled by the shadow pass. Re-pointing the MultiMesh at a
   multi-surface mesh costs ~18% of the frame. Note that `Main.tscn`'s `ext_resource` for it
   deliberately carries **no `uid=`** attribute: a headless `ResourceSaver.save` does not mint
   one, and Godot resolves uid *before* path, so a stale uid would silently keep loading the
   old 5-surface `.obj`.

### 12.1 Measured reality — read this before optimizing compute

Measured at ~20 000 hogs on an Apple M4 Pro (Metal, Forward+):

| config | ms/frame |
|---|---|
| baseline | 41.4 |
| merged mesh (5 surfaces → 1) | 35.8 |
| shadows OFF | 15.5 |
| hogs hidden entirely (`ShowHogs = false`) | 11.7 |

**Shadow casting is ~26 ms (62% of the frame). All compute is ~11.5 ms (27%).** Three compute
optimizations landed after this measurement — capacity/readback, the transform merge, and the
obstacle broad-phase — and none moved frame time outside run-to-run noise (~±1 ms). Do not
expect a compute change to show up in FPS; justify it on correctness, clarity or headroom
instead.

Specifics worth not re-deriving:

- **Obstacles are free.** 3000 obstacles cost ~0.07 ms with *no* broad-phase at all. The array
  is small (3000 × 48 B = 144 KB), cache-resident, broadcast-read by every thread, and the work
  is pure ALU. The broad-phase rejects were kept as cheap future-proofing, not because they won
  anything. The real ceiling on obstacle count is gameplay: at 3000 obstacles crowd mean speed
  fell from 1.17 to 0.30.
- **Unified memory makes the round trip cheap.** Cutting the GPU→CPU→GPU transfer from 6.1 to
  3.6 MB/frame changed nothing measurable. On Apple Silicon these are memcpys, not bus traffic;
  on a discrete GPU the conclusion would differ.
- `ShowHogs = false` skips both `MultimeshSetBuffer` and drawing while keeping all compute, the
  Sync and the readback — that is how the compute floor is isolated. Use it rather than
  guessing.
- ~0.5% of hogs end up inside an obstacle at `PBD_ITERATIONS = 1` in a dense crowd. Pre-existing
  solver behaviour, verified identical with and without the broad-phase.

---

## 13. Making Changes — by Task Type

### Add a new projectile ability

1. Create `projectiles/MyAbility.tres` (class: `ProjectileAbility`).
2. Set the ability fields: `damage`, `radius`, `force`, `contagion_type`, etc.
3. Add a matching input action in Godot's Project Settings → Input Map.
4. In `Main.gd`, preload the resource and call `spawn_projectile(my_ability)` in
   `_physics_process`.
5. No C# changes needed unless the ability requires a new GPU field.

### Add a new GPU body field

1. Add the field to `GpuBody` in `SquadMultiMeshInstance3D.cs` (maintain
   `LayoutKind.Sequential, Pack = 4`).
2. Update `BODY_STRIDE` if total float count changes.
3. Add the matching field at the same offset to `struct Body` in **all three** shaders —
   `physics_compute.glsl`, `spatial_hash_build.glsl`, `projectile_compute.glsl`. Missing one
   silently corrupts the stride for that shader only, which is a miserable bug to find.
4. Initialize the field in both `SetupCompute` (initial bodies) and
   `SpawnHogs` (runtime spawns).
5. If physics writes the field, add it to the explicit field-write block at the end of
   `physics_compute.glsl`'s `main()` — unless it is atomic-owned, in which case deliberately
   leave it out. See §7.
6. `godotx --path . --import`.

### Add a new compute shader pass

1. Add `Rid _myShader`, `_myPipeline`, `_myUniformSet` fields in
   `SquadMultiMeshInstance3D.cs`.
2. Implement `SetupMyShader()` and `RebuildMyUniformSet()` in `GpuSetup.cs`.
3. Call them from `SetupCompute()` and wherever buffer RIDs change.
4. Add `FreeRid` calls in `Dispose()` (GpuSetup.cs).
5. Insert the new dispatch into `_PhysicsProcess()` with a `ComputeListAddBarrier`
   before any pass that reads its output.
6. Call `VerifyPipeline()` on it after creation, and `godotx --path . --import`.

Before adding a pass, consider whether it can instead be folded into the tail of an existing
one. That is what happened to `transform_compute`: a separate pass had to re-read the whole
`Body` from memory, whereas the tail already holds it in registers.

### Add a new trigger zone effect

1. Add the effect to the `TriggerEffect` enum in `SquadMultiMeshInstance3D.cs`.
2. Add the metadata key to the `HasMeta` checks in `FindCollisionShapes`
   (Obstacles.cs) and `ConnectVisibilitySignals` (Obstacles.cs).
3. Add a case to `ScanForTriggers` (TriggerZones.cs).
4. Add a case to the `switch (zone.Effect)` in `ProcessTriggerZones` (TriggerZones.cs).

### Add a new GDScript visual component

1. Create the script under `components/` or `visuals/`.
2. Connect to `Global` signals rather than to specific nodes.
3. If it needs hog position data, connect to `HogDied` or
   `HogZoneTriggered` on the `SquadMultiMeshInstance3D` node — do not read
   the physics buffer directly from GDScript.

### Modify the obstacle buffer layout

1. Change `OBSTACLE_STRIDE` and all `OBS_*` constants in
   `SquadMultiMeshInstance3D.cs`.
2. Update the `struct Obstacle` in `physics_compute.glsl`.
3. Update `WriteObstacle`, `EmitObstacleDataArray`, and `EmitObstacleDataList`
   in `Obstacles.cs`.
4. Adjust `_obstacleCapacity` initial sizing if needed.

---

## 14. Common Gotchas

### A stale `.glsl` import makes the pipeline invalid — and binding it is a SILENT no-op

This one produced a genuinely misleading error. After editing a shader without re-importing,
`_projPipeline` was invalid. `ComputeListBindComputePipeline` with an invalid pipeline does
nothing and reports nothing, so the *next* `ComputeListSetPushConstant` was validated against
whatever pipeline was still bound — the hash pipeline — yielding:

```
ERROR: This compute pipeline requires (16) bytes of push constant data, supplied: (32)
```

The push constant was correct. The pipeline was missing. Always run
`godotx --path . --import` after touching a `.glsl`, and note that `VerifyPipeline()` now
exists in `GpuSetup.cs` specifically so this fails loudly at setup instead of misattributing
itself at dispatch. Do not remove those calls.

### `EnsureObstacleCache()` only scans `ObstaclesRoot/Static` and `ObstaclesRoot/Movable`

Obstacles parented directly to `ObstaclesRoot` are silently ignored and never reach the GPU.
This invalidated three consecutive rounds of obstacle benchmarking — timings looked perfectly
flat because nothing was being simulated. **Verify obstacles are live behaviourally before
trusting any obstacle measurement**: crowd spread and mean speed must change. They did not
(46.08 vs 46.02) with the obstacles misparented, which is impossible if they were real.

### Do not A/B this simulation by comparing trajectories

The sim is chaotic and nondeterministic. Two runs of *identical* code varied more (spread 37.5
vs 38.7) than the change under test did. Validate against hard invariants instead — e.g.
"how many hogs end up inside an obstacle" — and be suspicious of any metric that comes back
byte-identical across configs. A lit-pixel-counting metric returned exactly 93600 on both sides
of a test because the bright ground plane saturated the brightness threshold; it was measuring
nothing.

### Stale uniform sets after buffer reallocation

Growth frees and recreates `_physicsBuffer` and `_transformBuffer` when capacity is exceeded.
This invalidates all three uniform sets. If you add a new uniform set, make sure the growth
path also resets and rebuilds it — look for the block that sets `_physicsUniformSet = new Rid()`
and add yours.

Growth itself now runs inside the command queue (`ApplyPhysicsGrowth` in `GpuQueue.cs`) and
preserves existing contents with a GPU-side `_rd.BufferCopy`, not a readback-and-merge on the
CPU. `SpawnHogs` enqueues `EnqueueGrowPhysics`; it does not resize anything directly.

### `currOccupants` in ProcessTriggerZones allocates

`ProcessTriggerZones` creates a `new HashSet<int>()` per zone per frame. This is a
known allocation site that was judged acceptable (trigger zones are few). If the
number of trigger zones grows large, convert to a pre-allocated swap pattern like
the label sets.

### Trigger zone shapes must not connect VisibilityChanged

`ConnectVisibilitySignals` explicitly skips shapes with `damage` / `multiply` / `add`
metadata. If a new trigger effect key is added, it must be added to the `isTriggerZone`
check there, or visibility toggles on trigger shapes will null `_triggerZones`
mid-iteration in `ProcessTriggerZones`.

### `MemoryMarshal.Cast` shares the same backing bytes

When you do:
```csharp
var floats = MemoryMarshal.Cast<byte, float>(buf.AsSpan());
var ints   = MemoryMarshal.Cast<byte, int>(buf.AsSpan());
```
`floats[0]` and `ints[0]` are the same 4 bytes. Writing `ints[1] = numBodies`
also changes `floats[1]`. This is intentional — push constants mix floats and ints
at different offsets. Always use the typed alias that matches the semantic type for
each slot.

### GDScript `Variant.As<T>()` on nil crashes

The `GetObj<T>`, `GetBoolObj`, `GetV3Obj` helpers in `ProjectilesSpawner.cs` each
check `v.VariantType != Variant.Type.Nil` before calling `.As<T>()`. A direct
`.As<T>()` on a nil Variant throws at runtime in Godot 4. Always use these helpers
when reading optional properties from GDScript objects.

### Death FX pool cap

`_deathFxTotalCreated` is capped at `MAX_POOLED_DEATH_FX = 30`. When the pool is
exhausted and the cap is reached, excess death FX are silently dropped (the
`continue` in `DrainDeathFxQueue`). This is intentional to prevent unbounded node
creation. Increase the cap or raise `MaxDeathFxPerFrame` if deaths feel visually
sparse at high kill rates.

### Frame parity must flip after Sync, not before

`_hashFrameParity ^= 1u` is called after `_rd.Sync()`. Moving it before `Submit`
would cause the hash build and physics shaders in the same frame to disagree on
which parity tag is "current", leading to physics seeing stale hash buckets.

### `Multimesh.VisibleInstanceCount` vs `Multimesh.InstanceCount`

`InstanceCount` is the total allocated slot count (grows with `SpawnHogs`).
`VisibleInstanceCount` is set each frame to `aliveCount` (dead bodies are
compacted out). Rendering respects `VisibleInstanceCount`. Do not confuse the two
when calculating buffer sizes or work group counts.

### Never write `bodies[id] = self` in physics_compute

Four fields are atomic-owned and written by other invocations concurrently (§7). A wholesale
struct store clobbers them. The shader writes 17 named fields instead. The same reasoning
applies to the state word: it is committed as

```glsl
atomicAnd(bodies[id].state, CONTAGION_MASK);          // keep contagion bits, clear the rest
uint final_state = atomicOr(bodies[id].state, st) | st;
```

not as a plain assignment, and *not* as `atomicAnd(state, keep_contagion)` computed from a local
snapshot — that variant was tried and was itself racy, wiping a bit a neighbour had just set
while the raised expiry survived, which presented as "contagion infects but instantly
disappears".

### Work group count uses NumBodies, not InstanceCount

```csharp
var workGroups = (uint)Mathf.CeilToInt((float)NumBodies / GPU_THREAD_GROUP_SIZE);
```
`NumBodies` tracks the *current* logical count (grows when hogs are spawned).
`_bodyCapacity` (and `Multimesh.InstanceCount`) can be larger due to capacity
doubling. The shaders' bounds checks use `num_bodies` from the push constant, so
dispatching more groups than needed is harmless but dispatching fewer would leave
newly-spawned hogs unprocessed.

---

## 15. Verification Checklist

Before marking any task complete:

- [ ] `dotnet build --nologo` → **0 warnings, 0 errors**
- [ ] If any `.glsl` changed → `glslangValidator --target-env vulkan1.1 -S comp` passes,
      **and** `godotx --path . --import` has been run (§14 — skipping this produces a
      misattributed push-constant error), and no stray `comp.spv` is left in the repo
- [ ] If any `PROJ_*`, `PHYS_*`, `INST_*`, `BOMB_*`, `OBS_*`, or `HASH_*`
      constants changed → matching update in the corresponding `.glsl` file
- [ ] If `GpuBody` struct fields changed → `BODY_STRIDE` updated **and all three** GLSL
      `struct Body` copies updated to match (§7)
- [ ] If a GPU buffer write was added → it goes through `EnqueueGpuWrite`, not a direct
      `_rd.BufferUpdate` (§5)
- [ ] If contagion logic changed → contagion bits stay sticky, expiry is only ever raised via
      `atomicMax`, and the chain still terminates (§7)
- [ ] If a new buffer RID field was added → `Dispose()` frees it; `SpawnHogs`
      rebuilds its uniform set
- [ ] If a new per-frame code path was added in C# → no heap allocations
      (verify with Rider's Heap Allocations Viewer or manual audit)
- [ ] If a new trigger effect key was added → `FindCollisionShapes`,
      `ConnectVisibilitySignals`, `ScanForTriggers`, and `ProcessTriggerZones`
      all handle it
- [ ] If a GDScript resource was mutated at runtime → used `duplicate()` first
- [ ] If a new GDScript node reads hog state → connected through `Global`
      signals, not by reading GPU buffers directly
- [ ] Manual smoke test: launch scene, fire all five projectile types, verify
      hogs react to impacts, contagion spreads **and then dissipates** (both the effect and
      the colour tint), death FX play
- [ ] If a perf claim is being made → measured with `ShowHogs` toggled to isolate compute,
      averaged over ~140 frames discarding the first 60, and compared against the ~±1 ms
      run-to-run noise floor (§12.1). Do not report a compute win that is inside noise.
- [ ] If obstacle behaviour was touched → test obstacles are parented under
      `Obstacles/Static` or `Obstacles/Movable`, and confirmed live behaviourally (§14)
