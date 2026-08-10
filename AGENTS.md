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
12. [Performance Rules](#12-performance-rules)
13. [Making Changes — by Task Type](#13-making-changes--by-task-type)
14. [Common Gotchas](#14-common-gotchas)
15. [Verification Checklist](#15-verification-checklist)

---

## 1. One-Paragraph Mental Model

Explosion Squad game simulates 5 000 hogs entirely on the GPU. Every physics frame the CPU
dispatches four compute shaders (hash → projectile → physics → transform) in one
command list, calls `Submit()` + `Sync()`, and reads the resulting transform buffer
back to update the MultiMesh in one RenderingServer call. The CPU never writes
individual hog positions; it only reads them to detect deaths and trigger zones.
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
```

`dotnet build` must report **0 warnings, 0 errors** before any task is considered
done. The project uses the `godotx` CLI wrapper.

---

## 3. Repository Layout

```
Explosion-Squad-Game/
├── compute_shaders/          # C# GPU manager + 4 GLSL compute shaders
│   ├── HogsMultiMeshInstance3D.cs          # Orchestrator — types, fields, lifecycle
│   ├── HogsMultiMeshInstance3D.GpuSetup.cs # Setup, Dispose, push constants, RebuildXxx
│   ├── HogsMultiMeshInstance3D.Obstacles.cs# Obstacle cache, OBB/circle emit, UpdateObstacleBuffer
│   ├── HogsMultiMeshInstance3D.Projectiles.cs # Slot pool, SpawnProjectile, UploadPending
│   ├── HogsMultiMeshInstance3D.Bombs.cs    # Bomb buffer, death FX pool, OnHogDied
│   ├── HogsMultiMeshInstance3D.TriggerZones.cs # Zone detection, deferred spawns
│   ├── HogsMultiMeshInstance3D.Labels.cs   # Distance-sorted label assignment
│   ├── physics_compute.glsl                   # Boids, obstacles, bombs, contagion
│   ├── projectile_compute.glsl                # Projectile integration + sphere collision
│   ├── spatial_hash_build.glsl                # O(1) spatial hash construction
│   └── transform_compute.glsl                 # Writes MultiMesh transform buffer
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
├── ui/                       # GDScript UI nodes + TrajectoryOverlay.cs
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
 ├─ WriteHashBuildPush               │
 ├─ WriteProjectilePush              │
 ├─ WritePhysicsPush                 │
 ├─ WriteTransformPush               │
 │                                   │
 ├─ ComputeListBegin()               │
 │   ├─ Dispatch spatial_hash_build  ┤─ writes hash_counts[], hash_entries[]
 │   ├─ ComputeListAddBarrier        │
 │   ├─ Dispatch projectile_compute  ┤─ moves projectiles, sphere-sphere hit,
 │   │                               │  atomic damage_accum on bodies[]
 │   ├─ ComputeListAddBarrier        │
 │   ├─ Dispatch physics_compute     ┤─ boids, obstacle avoidance, bombs,
 │   │                               │  fear impulses, contagion spread
 │   ├─ ComputeListAddBarrier        │
 │   └─ Dispatch transform_compute   ┤─ writes instance_buffer[]
 ├─ ComputeListEnd()                 │
 ├─ Submit() + Sync()                │
 │                                   │
 ├─ BufferGetData(transformBuffer)   │  ← only CPU read per frame
 ├─ Compact alive instances          │
 ├─ ProcessTriggerZones              │  (CPU-side shape tests on transform data)
 └─ MultimeshSetBuffer               │  ← only RenderingServer write per frame
```

**Critical ordering constraint:** hash build → projectile → physics → transform.
The projectile shader atomically writes `damage_accum` into `bodies[]` which the
physics shader reads the same frame. The barrier between them is mandatory.

**Frame parity:** `_hashFrameParity` toggles 0 ↔ 1 each physics frame. The hash
build shader uses it to lazily invalidate stale buckets without a separate clear
pass. Both the hash build and physics push constants must receive the *same* parity
value within a single frame. It is flipped *after* `Sync()`.

---

## 6. The C# God-Class and Its Partials (to be refactored out)

`HogsMultiMeshInstance3D` is split into 7 `partial class` files. All live in
`compute_shaders/`. The class is `sealed`, so `partial` is the only safe split
mechanism — it preserves the public API and requires no scene-file changes.

| File | What lives there |
|------|-----------------|
| `HogsMultiMeshInstance3D.cs` | All `[Export]` properties, all inner types (`GpuBody`, `BombState`, `ProjectileAbility`, enums), all `[Signal]` declarations, all private field declarations, all buffer-layout constants, lifecycle (`_Ready` / `_Process` / `_PhysicsProcess` / `_UnhandledInput`), `SpawnHogs`, `UpdateTargetFromMouse` |
| `GpuSetup.cs` | `SetupCompute`, `SetupMultiMesh`, `Dispose`, `WriteXxxPush`, `RebuildXxxUniformSet` |
| `Obstacles.cs` | Obstacle cache, `ExtractObstacles`, `EmitObstacleDataArray/List`, `WriteObstacle`, `ComputeMinObb`, `FindCollisionShapes`, `UpdateObstacleBuffer` |
| `Projectiles.cs` | `SpawnProjectile`, `UploadPendingProjectiles`, `UpdateProjectileLifetimes`, `RegisterProjectileHitCallback`, `WriteProjectilePush` |
| `Bombs.cs` | `DrainDeathFxQueue`, `OnDeathFxFinished`, `OnHogDied`, `DropBomb`, `UpdateBombBuffer` |
| `TriggerZones.cs` | `ProcessTriggerZones`, `DamageHogViaBuffer`, `ScanForTriggers`, `GetTriggerBounds`, `IsInsideCircle/OBB`, `TriggerKey` |
| `Labels.cs` | `_timeSinceLastLabelUpdate` field, `UpdateLabels`, `ClassifyState`, `IsLabelOnScreen` |

**Rule:** all field *declarations* stay in the main `.cs` file (except
`_timeSinceLastLabelUpdate` which is label-specific state). Method implementations
go into whichever partial file owns that concern.

---

## 7. Buffer Layout Contracts

Every constant in `HogsMultiMeshInstance3D.cs` that starts with `PROJ_`, `PHYS_`,
`INST_`, `BOMB_`, `OBS_`, or `HASH_` is a direct index into a GPU buffer. Changing
any of these **requires a matching change in the corresponding `.glsl` file** or the
game will silently corrupt physics data.

### GpuBody (physics_compute.glsl `struct Body`)

`BODY_STRIDE = 28` floats. Declared as `[StructLayout(LayoutKind.Sequential, Pack = 4)]`.
The field order in `GpuBody` must exactly match the GLSL struct layout. Adding fields
requires updating both the C# struct AND the shader, and re-initializing buffer sizes.

### Projectile (projectile_compute.glsl `struct Projectile`)

`PROJ_STRIDE = 24` floats. Slot 18 (`PROJ_FLAGS`) is a `uint` reinterpreted as
`float` — use `BitConverter.UInt32BitsToSingle` / `SingleToUInt32Bits` to read/write.
Slot 16 (`PROJ_CONTAGION`) is the same encoding. Never write raw `uint` values to
a `float[]` buffer directly.

### Instance (transform_compute.glsl output)

`INSTANCE_STRIDE = 20` floats per instance. Slots 16–19 are `INSTANCE_CUSTOM` (R/G/B/A).
Slot 17 (`INST_HEALTH`) and slot 18 (`INST_STATE`) are written by `transform_compute.glsl`
and read back by the CPU compaction loop and trigger zone tests every frame.

### Push Constant Sizes

| Shader | Size | Constant |
|--------|------|----------|
| `spatial_hash_build.glsl` | 16 bytes (4 × float) | `HASH_BUILD_PUSH_SIZE` |
| `projectile_compute.glsl` | 32 bytes (8 × float) | `PROJ_PUSH_SIZE` |
| `physics_compute.glsl` | 56 bytes (14 × float) | `PHYSICS_PUSH_SIZE` |
| `transform_compute.glsl` | 16 bytes (4 × float) | `TRANSFORM_PUSH_SIZE` |
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
       │    └─ HogsMultiMeshInstance3D.SpawnProjectile(pos, vel, ability)
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
`ConvexPolygonShape3D` and `ConcavePolygonShape3D` → minimum OBB computed by
`ComputeMinObb` (rotating-calipers approximation).

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

HogsMultiMeshInstance3D C# signals:
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

All four uniform sets (`physics`, `transform`, `hash`, `projectile`) reference
`_physicsBuffer`, so a body buffer reallocation must rebuild all four.

---

## 12. Performance Rules

These are non-negotiable. Do not introduce patterns that violate them.

1. **No per-frame heap allocations in `_PhysicsProcess` or any callee.** Use
   pre-allocated staging buffers, span overlays, and `Buffer.BlockCopy`.

2. **No `get_nodes_in_group` or `get_children` in `_PhysicsProcess` or
   `_physics_process`.** Cache node references at `_ready` time.

3. **One GPU submit per physics frame.** All four dispatches must be in a single
   `ComputeListBegin → End → Submit → Sync` sequence.

4. **No additional `BufferGetData` calls beyond the existing transform readback and
   the throttled projectile flag readback.** Each `BufferGetData` forces a GPU sync
   stall.

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

1. Add the field to `GpuBody` in `HogsMultiMeshInstance3D.cs` (maintain
   `LayoutKind.Sequential, Pack = 4`).
2. Update `BODY_STRIDE` if total float count changes.
3. Add the matching field to the `struct Body` in `physics_compute.glsl` at the
   same offset.
4. Initialize the field in both `SetupCompute` (initial bodies) and
   `SpawnHogs` (runtime spawns).

### Add a new compute shader pass

1. Add `Rid _myShader`, `_myPipeline`, `_myUniformSet` fields in
   `HogsMultiMeshInstance3D.cs`.
2. Implement `SetupMyShader()` and `RebuildMyUniformSet()` in `GpuSetup.cs`.
3. Call them from `SetupCompute()` and wherever buffer RIDs change.
4. Add `FreeRid` calls in `Dispose()` (GpuSetup.cs).
5. Insert the new dispatch into `_PhysicsProcess()` with a `ComputeListAddBarrier`
   before any pass that reads its output.

### Add a new trigger zone effect

1. Add the effect to the `TriggerEffect` enum in `HogsMultiMeshInstance3D.cs`.
2. Add the metadata key to the `HasMeta` checks in `FindCollisionShapes`
   (Obstacles.cs) and `ConnectVisibilitySignals` (Obstacles.cs).
3. Add a case to `ScanForTriggers` (TriggerZones.cs).
4. Add a case to the `switch (zone.Effect)` in `ProcessTriggerZones` (TriggerZones.cs).

### Add a new GDScript visual component

1. Create the script under `components/` or `visuals/`.
2. Connect to `Global` signals rather than to specific nodes.
3. If it needs hog position data, connect to `HogDied` or
   `HogZoneTriggered` on the `HogsMultiMeshInstance3D` node — do not read
   the physics buffer directly from GDScript.

### Modify the obstacle buffer layout

1. Change `OBSTACLE_STRIDE` and all `OBS_*` constants in
   `HogsMultiMeshInstance3D.cs`.
2. Update the `struct Obstacle` in `physics_compute.glsl`.
3. Update `WriteObstacle`, `EmitObstacleDataArray`, and `EmitObstacleDataList`
   in `Obstacles.cs`.
4. Adjust `_obstacleCapacity` initial sizing if needed.

---

## 14. Common Gotchas

### Stale uniform sets after buffer reallocation

`SpawnHogs` frees and recreates `_physicsBuffer` and `_transformBuffer` when
capacity is exceeded. This invalidates all four uniform sets. If you add a new
uniform set, make sure `SpawnHogs` also resets and rebuilds it — look for the
block that sets `_physicsUniformSet = new Rid()` and add yours.

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
- [ ] If any `PROJ_*`, `PHYS_*`, `INST_*`, `BOMB_*`, `OBS_*`, or `HASH_*`
      constants changed → matching update in the corresponding `.glsl` file
- [ ] If `GpuBody` struct fields changed → `BODY_STRIDE` and GLSL `struct Body`
      updated to match
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
      hogs react to impacts, contagion spreads, death FX play
