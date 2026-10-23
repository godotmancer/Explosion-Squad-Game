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

Explosion Squad game simulates up to ~125 000 hogs entirely on the GPU. Every physics frame the
CPU first syncs the dispatch it submitted last frame and reads its transform buffer back, then
drains its deferred GPU command queue, dispatches three compute shaders (hash → projectile →
physics) in one command list and calls `Submit()` — without waiting. The GPU runs one tick behind
the CPU. Once per rendered frame, `_Process` uploads the hogs of the latest readback that the
camera can see to the MultiMesh, in one RenderingServer call.
The CPU never writes individual hog positions; it only reads them to detect deaths and
trigger zones, and to draw them.
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

`ExplosionSquadGame.csproj` sets `<Optimize>true</Optimize>` for every configuration. The editor
runs the Debug configuration, for which the Godot SDK otherwise disables JIT optimisation, and the
per-hog C# loops ran ~2× slower that way. Breakpoints still work; stepping is less exact.

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
│   ├── SquadMultiMeshInstance3D.Bombs.cs    # Bomb buffer, death FX pool, OnHogDied, HogsDied
│   ├── SquadMultiMeshInstance3D.TriggerZones.cs # Zone detection, deferred spawns
│   ├── SquadMultiMeshInstance3D.Labels.cs   # Distance-sorted label assignment
│   ├── SquadMultiMeshInstance3D.Drawing.cs  # Frustum culling + the MultiMesh upload
│   ├── physics_compute.glsl                   # Boids, obstacles, bombs, contagion, instance write
│   ├── projectile_compute.glsl                # Projectile integration + sphere collision
│   └── spatial_hash_build.glsl                # O(1) spatial hash construction
├── projectiles/              # GDScript visual projectiles + C# spawner facade
│   ├── ProjectilesSpawner.cs                  # GDScript-callable C# facade
│   ├── ProjectileBase.gd                      # Base visual projectile (Euler integration)
│   ├── ProjectileAbility.gd                   # Resource class for ability data
│   └── *.tres                                 # Bullet, Fire, Poison, Drunk, Teleport, Mortar abilities
├── bombs/
│   └── BombSpawner.cs                         # Spawns bomb visual + invokes DropBomb callback
├── components/               # GDScript @tool components (Animator, LookAtTracker,
│                             #   GateAnimation)
├── visuals/                  # GDScript FX (DrawableGround, HogLabels, Announce3D, DeathFx)
├── compositor_fx/            # Post-process Outline effect (GDScript + GLSL)
├── shaders/                  # Visual-only gdshaders (black hole, openvat, broken TV)
├── ui/                       # GDScript UI nodes (Fps, HogsKilled, TotalHogs) + TrajectoryOverlay.cs
├── assets/animal_hog_merged.tres  # Single-surface baked hog mesh used by the MultiMesh
├── Main.gd                   # Input dispatch, projectile keys 1–6 (paced by fire_interval), Shift lobs
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
 ├─ CompleteGpuTick()                │  ← LAST tick's dispatch, submitted unsynced
 │   ├─ Sync()                       │
 │   ├─ advance hash frame stamp     │
 │   ├─ BufferGetData(transformBuffer)  ← only CPU read per frame (the rows it dispatched)
 │   ├─ ReadbackPass                 │  ONE walk over the rows: new deaths (STATE_DEAD),
 │   │                               │  the live-hog list, trigger-zone shape tests
 │   ├─ HogsDied / ZoneTriggered     │  one signal per tick / per zone entered
 │   └─ keep the readback + live list for DrawHogs
 │                                   │
 ├─ UpdateProjectileLifetimes etc.   │  (may read GPU buffers: after the Sync above)
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
 │   │   (skipped if none is live)   │  atomic damage_accum on bodies[]
 │   ├─ ComputeListAddBarrier        │
 │   └─ Dispatch physics_compute     ┤─ boids, obstacle avoidance, bombs, fear
 │                                   │  impulses, contagion spread, THEN writes
 │                                   │  instance_buffer[] from its own tail
 ├─ ComputeListEnd()                 │
 └─ Submit()                         │  ← no Sync: runs while the frame is processed + drawn

_Process — once per rendered frame, after that frame's physics ticks
 └─ DrawHogs()                          live list → hogs in the camera's view
     ├─ resize MultiMesh if drawn > InstanceCount or < half of it
     ├─ MultimeshSetCustomAabb
     └─ MultimeshSetBuffer               ← the only MultiMesh upload
```

**The GPU runs one tick behind.** `_PhysicsProcess` submits its dispatch and returns; the next
`_PhysicsProcess` syncs it (`CompleteGpuTick`) before doing anything else. Syncing straight after
`Submit` left the CPU idle for the whole dispatch — 4–10 ms a tick at 100k hogs. Everything read
back (hog positions, deaths, trigger-zone enters, projectile hits) is therefore one tick older
than it used to be; writes still land before the next dispatch exactly as before, because the
trigger-zone pass and the flush both run between one dispatch's Sync and the next dispatch.
See the §14 gotcha for what this means for new code.

**Hogs are drawn from `_Process`, culled to the view.** Godot has no per-instance culling: it culls
a MultiMesh as one object by its AABB, then draws every visible instance in every pass that AABB
reaches — depth prepass, colour, each directional cascade, and the shadow map of every shadowed
light in range (six faces for an omni). With `Main.tscn`'s lights that was every live hog about 13
times a frame, on screen or not. `DrawHogs` (`Drawing.cs`) therefore uploads only the hogs within
`FrustumCullMargin` (2 m) plus the mesh's bounding radius of the camera's view, and sets a custom
AABB around them. It runs in `_Process`, after the frame's ticks: it culls against the camera
the frame is drawn from (culling in the tick would lag the camera by a frame while orbiting, and
by several in slow motion, when ticks are rarer than frames), and uploads once however many ticks
the frame ran. It uploads only when there is a new readback or the camera or squad node has moved.
The test is six plane checks per hog, with planes taken from the camera's projection matrix and
moved into the squad node's space; it was checked against `Camera3D.GetFrustum()` with zero
disagreements, perspective and orthographic.

The MultiMesh is sized to what `DrawHogs` draws, not to the body capacity: `MultimeshSetBuffer`
takes exactly `InstanceCount` rows, so every slot past the drawn ones was uploaded every frame
for nothing. It grows to 1.25× the drawn count once that no longer fits and shrinks once it
draws under half, never below `MULTIMESH_MIN_INSTANCES` (1024) nor above `_bodyCapacity` — a
crowd entirely in view uploads no more than the capacity-sized MultiMesh did. A resize clears the
MultiMesh; the upload in the same call refills it, so nothing flickers. `DrawHogs` walks only
`_liveHogs`, the readback's live rows listed by `ReadbackPass`, never a corpse.

**Critical ordering constraint:** hash build → projectile → physics.
The projectile shader atomically writes `damage_accum` into `bodies[]` which the
physics shader reads the same frame. The barrier between them is mandatory.

**There is no fourth pass.** `transform_compute.glsl` was deleted; physics_compute writes
the instance buffer in its tail via binding 5, as five coalesced `vec4` stores, reusing the
`Body` it already has in registers. Dead bodies take an early-out path that still writes
their `INSTANCE_CUSTOM` row (so the CPU readback pass can see `STATE_DEAD`) and skip
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

**Frame stamp:** `_hashFrameStamp` is the physics frame index masked to 16 bits
(`HASH_STAMP_MASK`). The hash build stores it in the high half of each bucket word and
lazily resets any bucket carrying a different stamp, so no clear pass is needed; the queries
treat a mismatched stamp as empty. All three push constants (hash build, projectile,
physics) must receive the *same* stamp within a single frame. It advances *after* `Sync()`,
and when it wraps to 0 C# queues `EnqueueGpuClear` over the bucket words, so a bucket left
untouched for exactly 65 536 frames cannot read as current.

It used to be a 1-bit parity, which cannot tell "written this frame" from "written two frames
ago": every cell a hog walked out of came back as valid on alternate frames, feeding stale
entries into neighbour queries. Do not narrow it again.

---

## 6. The C# God-Class and Its Partials (to be refactored out)

`SquadMultiMeshInstance3D` is split into 9 `partial class` files. All live in
`compute_shaders/`. The class is `sealed`, so `partial` is the only safe split
mechanism — it preserves the public API and requires no scene-file changes.

| File | What lives there |
|------|-----------------|
| `SquadMultiMeshInstance3D.cs` | All `[Export]` properties, all inner types (`GpuBody`, `BombState`, `ProjectileAbility`, enums), all `[Signal]` declarations, all private field declarations, all buffer-layout constants, lifecycle (`_Ready` / `_Process` / `_PhysicsProcess` + `CompleteGpuTick` / `_UnhandledInput`), `SpawnHogs`, `UpdateTargetFromMouse` |
| `GpuSetup.cs` | `SetupCompute`, `SetupMultiMesh`, `Dispose`, `WriteXxxPush`, `RebuildXxxUniformSet`, `VerifyPipeline`, `SampleHashOverflow` |
| `GpuQueue.cs` | `GpuTarget` / `GpuCommandKind` enums, `GpuCommand` struct, `_gpuCommands` / `_gpuPayload`, `ReserveGpuWrite`, `EnqueueGpuWrite`, `EnqueueGpuClear`, `EnqueueGrowPhysics`, `EnqueueGrowObstacles`, `FlushGpuCommands`, `ResolveGpuTarget`, `ApplyPhysicsGrowth`, `ApplyObstacleGrowth`, `FreeGpuRid`. **The only file allowed to call `RenderingDevice` mutators.** |
| `Obstacles.cs` | Obstacle cache, `ExtractObstacles`, `EmitObstacleDataArray/List`, `WriteObstacle`, `ComputeMinObb`, `DecomposeTrimeshFootprint`, `ObstacleSlotCount`, `FindCollisionShapes`, `UpdateObstacleBuffer` |
| `Projectiles.cs` | `SpawnProjectile`, `UploadPendingProjectiles`, `UpdateProjectileLifetimes`, `RegisterProjectileHitCallback`, `WriteProjectilePush` |
| `Bombs.cs` | `DrainDeathFxQueue`, `OnDeathFxFinished`, `OnHogDied`, `EmitHogsDied`, `DropBomb`, `Detonate`, `UpdateBombBuffer` |
| `TriggerZones.cs` | `BeginTriggerZonePass`, `TestTriggerZones`, `EndTriggerZonePass`, `OnZoneEntered`, `QueueZoneDamage`, `FlushZoneDamage`, `DamageHogViaBuffer`, `ScanForTriggers`, `GetTriggerBounds`, `IsInsideCircle/OBB`, `TriggerKey` |
| `Labels.cs` | `_timeSinceLastLabelUpdate` field, `UpdateLabels`, `ClassifyState`, `IsLabelOnScreen` |
| `Drawing.cs` | `DrawHogs` (frustum cull, custom AABB, `MultimeshSetBuffer`), `BuildCullPlanes`, `ToNodeSpace`, `IsOutside` |

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

`BODY_STRIDE = 30` floats. Declared as `[StructLayout(LayoutKind.Sequential, Pack = 4)]`.
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

**Fields owned by atomics.** During the physics dispatch, `contagion_expiry_u[3]` (floats
16–18) and `contagion_dps_u[3]` (19–21) are written through atomics by more than one invocation
(neighbours spreading contagion). `physics_compute` therefore does **not** write
`bodies[id] = self` — that would clobber a neighbour's concurrent atomic. It writes 16 explicit
fields instead, omitting those two arrays plus `radius`, `mass`, `teleport_x/z/y` and `pad29`,
which physics never modifies. `damage_accum`, `impulse_*` and `body_flags` are accumulated
atomically by `projectile_compute` in the *previous* dispatch, so physics consumes and zeroes
them with plain stores. If you add a body field, decide which category it is in and update that
write block accordingly.

There is no `state` field: the behaviour bits are rebuilt from scratch every frame and only
ever leave the GPU through the instance buffer (`INST_STATE`). The C# `GpuBody` spells the two
GLSL arrays out as `FireExpiryU`/`PoisonExpiryU`/`DrunkExpiryU` and `FireDpsU`/`PoisonDpsU`/
`DrunkDpsU`, in that order.

`pad29` only keeps the size a multiple of 8 bytes: the struct's `vec2` members give it 8-byte
alignment in std430, while C#'s `Pack = 4` would not pad, so an odd float count would make the
two strides disagree. A new float field can take its place; beyond that, grow `BODY_STRIDE`
two at a time.

### Contagion encoding

Each contagion type — `CONT_FIRE`, `CONT_POISON`, `CONT_DRUNK`, indices 0–2 — has its own
entry in `contagion_expiry_u[]` and `contagion_dps_u[]`, so each runs on its own clock and deals
its own damage. They used to share one expiry and one DPS, so a drunk hog (50 s) that caught
fire burned — and spread fire — for the whole drunk window.

The expiry is an **absolute timestamp** (`time × CONT_TIME_SCALE`, 256), not a countdown. It
is only ever raised, via `atomicMax`. This is what makes it safe under concurrent writes — a
decrementing timer cannot be expressed with a single commutative atomic, and an earlier
countdown version had a bug where `max(local_decremented, stored)` restored the pre-decrement
value every frame, so contagion never expired at all.

All infection goes through `infect()`, duplicated in physics_compute (spread) and
projectile_compute (hits) — keep the two identical. Consequences to preserve:

- A type is live while `contagion_expiry_u[t] > now_u`. Never test for zero.
- Live types sum their DPS. Within a type the DPS is the strongest infection's (`atomicMax`),
  except that the *first* infector — the invocation whose `atomicMax` on the expiry observes
  `prev_expiry <= now_u` — replaces it with `atomicExchange`, because the value left there
  belongs to an outbreak that has lapsed. A same-type infector racing the exchange can lose its
  DPS to the winner's for that outbreak; accepted, since infections of one type normally carry
  the same DPS.
- The `STATE_ON_FIRE / POISONED / DRUNK` bits are **derived** every frame from the live types
  (`STATE_ON_FIRE << t`), never stored or set by another invocation. So they clear on the frame
  their type lapses, and `HogsDied`'s `stateBits` (which `DrawableGround.gd` colours the death
  decal by) are exact. A type a neighbour hands a hog mid-dispatch shows up a frame later.
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
a `float[]` buffer directly. Slot 21 (`PROJ_GRAVITY_SCALE`) multiplies the world gravity for
that projectile; slots 22–23 are spare.

Positions and the teleport height in this buffer are in the squad's **simulation space**, not
world space: `SpawnProjectile` subtracts the squad node's height (`SimOriginY`, 0.25 in
Main.tscn) and `ReclaimGpuKilledProjectiles` adds it back to the reported hit point. Bodies live
in that space, so without the shift projectiles collided with hogs 0.25 m below where they are
drawn and reached the GPU's ground 0.25 m under the visible floor.

### Instance (physics_compute.glsl tail output, binding 5)

`INSTANCE_STRIDE = 20` floats per instance = `INSTANCE_VEC4S = 5` vec4 rows, matching Godot's
row-major MultiMesh layout. Slots 16–19 are `INSTANCE_CUSTOM` (R/G/B/A). Slot 17
(`INST_HEALTH`) and slot 18 (`INST_STATE`) are read back every frame and read by `ReadbackPass`
in `CompleteGpuTick` (deaths, trigger zones) and by `DrawHogs`.

The custom row only feeds the CPU: the hog shader reads `COLOR` alone. So the MultiMesh itself
carries no custom data — `SetupMultiMesh` forces `UseColors = true`, `UseCustomData = false` —
and `DrawHogs` uploads the first `DRAW_STRIDE = 16` floats of each row (transform + colour),
20% less than the readback's stride. `_transformFloats` (the upload staging) is grow-only, and
only its first `InstanceCount × DRAW_STRIDE` floats are uploaded; `_transformBuffer` (the GPU
instance buffer) is `capacity × INSTANCE_STRIDE`. If a hog shader ever needs `INSTANCE_CUSTOM`,
turn custom data back on and upload all 20.

The shader declares the buffer as `vec4 instances[]` and indexes rows, so the C# float indices
map as `INST_ROW_CUSTOM = 4` ↔ `INST_CUSTOM_R = 16`. Keep both sides in step: the C# constants
are float offsets, the GLSL constants are vec4 offsets.

### Spatial hash

| Constant | Value | Note |
|----------|-------|------|
| `HASH_TABLE_SIZE` | 32768 | `= HASH_GRID_W × HASH_GRID_H`, both powers of two |
| `HASH_GRID_W` / `HASH_GRID_H` | 256 / 128 | GLSL-only. Cells along x / z before the grid wraps |
| `HASH_MAX_PER_CELL` | 64 | Query loop runs `count` times, not this many |
| `HASH_CELL_SIZE` | 2.0 | GLSL-only |
| `HASH_STAMP_MASK` | `0xFFFF` | Bucket word is `(stamp << 16) \| count`; see "Frame stamp" in §5 |
| `HASH_AIR_BUCKET` | `HASH_TABLE_SIZE` | Count word of the airborne list (below); `spatial_hash()` never returns it |
| `HASH_AIR_MAX` | 4096 | Airborne list capacity; its entries follow the grid's |
| `HASH_OVERFLOW_SLOT` | `HASH_TABLE_SIZE + 1` | Overflow counter after both; cannot collide with a real bucket |
| `HASH_COUNTS_BUFFER_SIZE` | `(HASH_TABLE_SIZE + 2) * 4` | Grid words, airborne word, overflow counter |
| `HASH_ENTRIES_BUFFER_SIZE` | `(HASH_TABLE_SIZE * 64 + HASH_AIR_MAX) * 4` | Grid entries, then the airborne list |
| `HASH_FEAR_BUFFER_SIZE` | `HASH_TABLE_SIZE * 4` | One fear word per grid bucket, zeroed every tick (below) |
| `NEIGHBOUR_STRIDE` | 32 | Bytes per body of the neighbour snapshot (below); buffer grows with the bodies |

**Airborne bodies are not in the grid.** Physics never pairs a grounded hog with an airborne one
(its neighbour scan skips them), so they would only cost it candidates and eat into per-cell
capacity. The build puts them in one extra bucket instead — a flat list stamped and counted like
any grid bucket — and `projectile_compute` scans it whenever nothing on the ground was hit. Before
that list existed, a hog in the air could not be hit by anything.

Despite the name, `spatial_hash()` is a **wrap-around grid**, not a hash: cell `(cx, cz)` maps to
bucket `(cx mod 256) + (cz mod 128) × 256`. Two cells share a bucket only when they are a whole
grid apart — 512 m in x, 256 m in z — so a scan window never holds two cells of one bucket and
each bucket's 64 entries really are per cell. The multiplicative hash it replaced,
`(cx·A ^ cz·B) & mask`, collided structurally: modelled on a 20k-hog crowd it added 20–50%
extra neighbour candidates, visited one bucket twice in 0.2% of 5×5 windows (double-counting
those neighbours), and let dense cells split one bucket's capacity. The function is duplicated
in all three shaders; keep them identical.

Oversizing the table is free at runtime, not just cheap: the frame-stamp scheme means nothing
ever iterates the table, so a bucket no body lands in is never touched. The only cost is the
fixed allocation (~128 KB counts + ~8 MB entries). This is why it is a constant rather than
scaling with body count — a game starting with five hogs pays the VRAM and zero per-frame time.

The count half of a bucket word keeps rising past `HASH_MAX_PER_CELL` for overflowed inserts,
so it only spills into the stamp at 65 536 inserts into one 2 m cell in a single frame.

Per-bucket overflow is a graceful no-op (the body is invisible as a neighbour — or, past
`HASH_AIR_MAX` hogs in the air, to projectiles — for one frame) but
is **counted**, not silent: `atomicAdd(hash_counts[HASH_OVERFLOW_SLOT], 1u)`. Set the
`DebugHashOverflow` export to have C# sample it at 1 Hz. Non-zero means raise
`HASH_MAX_PER_CELL` or shrink `HASH_CELL_SIZE`. The symptom otherwise — hogs walking through
each other in a dense pile — is very hard to attribute.

### Neighbour snapshots and fear words

The hash build writes two more things for every body it puts in the grid, and physics reads
them instead of other bodies:

- **`struct Neighbour`** (32 bytes, binding 3 of the build, 6 of physics, one per body): position,
  velocity, radius, `last_hit_time`, the bomb origin packed as two halves, and the drunk expiry
  — every field of another hog the neighbour scan reads. The scan used to load each
  candidate's `Body` (120 bytes, so often two cache lines) while that candidate's own invocation
  was rewriting it in the same dispatch, so a position could be read torn. The snapshot is the
  start-of-tick state of every candidate alike, and a line holds whole snapshots. It is
  duplicated in the two shaders (`⚠ KEEP IN SYNC`) and sized by `NEIGHBOUR_STRIDE` in C#. Contagion
  spread still writes `bodies[i]` through `infect()`'s atomics.
- **`hash_fear`** (one word per grid bucket, binding 4 of the build, 7 of physics): the bucket's
  most frightened hog, as `(rank << 6) | slot`, kept by `atomicMax`. Only hogs inside their fear
  window (`time - last_hit_time < bomb_fear_duration`, from the build's push constants) are
  ranked, latest hit highest. C# zeroes the words every tick (`EnqueueGpuClear(GpuTarget.HashFear)`
  before the flush), so a non-zero word is this tick's.

The 5×5 scan's outer ring exists only for fear contagion, and it now reads one fear word per
cell — plus at most one snapshot — instead of every hog in the 16 cells. That is the hog the
full scan would have picked: fear falls off with time since the hit, so the latest-hit hog is
the most afraid, and the spread window that rejects it rejects the whole cell. A throwaway
check that ran both side by side found 0 mismatches in 68.7M outer-cell evaluations with
fear present. The inner 3×3 still visits every hog.

Physics went from ~4.5 to ~2.7 ms a tick at 100k hogs (GPU timestamps; figures and method in
§12.1).

### Push Constant Sizes

| Shader | Size | Constant |
|--------|------|----------|
| `spatial_hash_build.glsl` | 24 bytes (6 × float) | `HASH_BUILD_PUSH_SIZE` |
| `projectile_compute.glsl` | 32 bytes (8 × float) | `PROJ_PUSH_SIZE` |
| `physics_compute.glsl` | 72 bytes (18 × float) | `PHYSICS_PUSH_SIZE` |
| `compositor_fx/Outline.glsl` | 72 bytes (mat4 64B + vec2 8B) | hardcoded in `Outline.gd` |

Push constant byte arrays are pre-allocated once and reused every frame.
`MemoryMarshal.Cast<byte, float/int/uint>` overlays them as typed spans — zero
allocation, zero copy.

---

## 8. Projectile System — End to End

### Spawn path

```
GDScript (Main.gd — paced by each ability's fire_interval)
  └─ ProjectileBase.launch(from, to)           # or launch_velocity(from, velocity)
       ├─ aim_velocity: direct at ability.speed, or ballistic_velocity at
       │  ability.launch_angle_deg (a lob that lands on `to`), then spread + speed variance
       ├─ ProjectilesSpawner.SpawnProjectileWithVelocity(pos, vel, ability)
       │    └─ SquadMultiMeshInstance3D.SpawnProjectile(pos, vel, ability)
       │         ├─ Pop the lowest free slot from _projFreeSlots, raise _projHighWater
       │         ├─ Write floats into _projAllStagingFloats[slot * PROJ_STRIDE + ...]
       │         │  (heights shifted into simulation space — see §7)
       │         └─ Enqueue slot index into _pendingProjSpawns
       ├─ ProjectilesSpawner.RegisterProjectileHitCallback(slot, _on_gpu_hit)
       └─ one _step() straight away, to match the GPU's first step (below)
```

Staging floats are uploaded in `UploadPendingProjectiles()`, early in the squad's
`_PhysicsProcess`. When `Main.gd` fires, that is the same physics frame — `Main` is the squad's
parent and is processed first — so the GPU copy takes its first step in the frame it was fired.

### Two copies, one path

Every projectile exists twice: the drawn `ProjectileBase` node and the GPU copy that does the
damage. They must fly the same path, so both use:

- the same velocity (the node passes its own to `SpawnProjectileWithVelocity`);
- the same gravity — world `Gravity` × the ability's `gravity_scale` (0 = dead straight), read
  by the node from the spawner (`GetGravity`), never from a scene export;
- the same ground height (`GetGroundHeight` = `YOffset` + the squad node's height);
- the same semi-implicit Euler, taken on the same frames: the node is only processed from the
  frame after it was added, so `_start` takes the first step itself.

They used to disagree — the scene flew the node with gravity 0 while the GPU applied 9.8 — so
damage landed short of the shot you could see.

`ballistic_velocity` solves the analytic parabola, which the per-tick Euler step undershoots by
`g·dt/2` per second of flight; `aim_velocity` adds that to the vertical speed, which makes the
stepped path pass through the analytic one at every tick, so a lobbed shell lands where aimed.

### Drawing

The node steps on physics frames but draws in `_process`, lerping between its last two stepped
positions by `Engine.get_physics_interpolation_fraction()`. At 80 m/s a shot covers 1.3 m per
60 Hz tick; drawn only on physics frames, a stream of shots hopped in step every other rendered
frame and read as a static dotted grid.

Colour: `SimpleProjectile.tscn`'s mesh and its material are sub-resources, so **every projectile
instance shares them**. `_ready` therefore never touches that material; it sets a surface
override from `_material_for(color)`, a copy made once per colour and cached in the static
`_materials_by_color`. Recolouring the shared material itself turned every projectile in flight
the colour of the latest shot.

### Collision (projectile_compute.glsl)

Each frame the GPU sweeps the projectile's path — cut short where it meets the ground —
against every body it could touch: the grid cells around the path (grown by the projectile's
radius plus `BodyRadius`, pushed as `body_radius`) and the airborne bucket. It hits the body met
**earliest along the path** (`contact_t`, a segment-vs-sphere test) and stops at the point of
contact, which is what C# reports as the hit position. The old test checked only the end of each
step and took the first body the grid scan happened to reach: fast shots could pass through a
hog between frames, and hits were biased toward the lowest cell of the scan window, so a stream
of shots carved the crowd along the grid.

An ability without its own `force_dir` knocks hogs along the projectile's direction of travel
at impact (for a lob, down and forward — not the direction it was launched in).

### Firing feel and explosions

`fire_interval` (seconds between shots while held), `spread_deg` (aim cone) and
`speed_variance` (fractional muzzle speed error) are per ability. Firing one identical shot
per physics frame from one point is what made a held key draw a solid column of evenly spaced
beads, and a tap a clump of them.

An ability with `explosion_radius > 0` bursts where it lands, on a hog or the ground:
`ProjectileBase.kill` calls `ProjectilesSpawner.Detonate` → `SquadMultiMeshInstance3D.Detonate`,
the same shockwave, damage falloff and panic as a dropped bomb (`DropBomb` is now a
`Detonate` with the bomb exports). `MortarProjectile.tres` (key 6) is the example: lobbed at 55°
with `gravity_scale` 2.5, bursting over 3.5 m.

### Lob modifier (Shift)

Holding the `lob_modifier` action (Shift) while firing lobs **any** projectile onto the mouse
point instead of firing it straight: `Main._as_fired` hands `spawn_projectile` a copy of the
ability with `launch_angle_deg` / `gravity_scale` set from `Main.lob_angle_deg` /
`lob_gravity_scale` (defaults match the mortar). Everything else about the ability is kept.
Copies of the shared abilities are made once and cached in `_lobbed`; the teleport ability,
already duplicated per shot for its destination, is lobbed in place instead, so the cache
cannot grow per shot. The cooldown stays keyed on the original ability. An ability that lobs by
itself (the mortar) is fired unchanged.

The fire actions match with Shift held because Godot matches actions non-exactly by default
(modifiers ignored). The camera's own Shift use is pan-while-orbit-dragging only.

While a lobbed shot is being fired — Shift or the mortar key held — the HeadHog also pitches up
to its launch angle, like a mortar barrel: `lob_angle_deg` for Shift, the mortar's own
`launch_angle_deg` whenever its key is held (it flies at that angle with or without Shift; see
`Main._head_lob_angle_deg`). `Main._aim_head` sets `LookAtTracker.aim_direction_override` on
the head's tracker (`Main.head_tracker`) to that launch direction — horizontally toward the
mouse point, raised by the angle — and clears it to `Vector3.ZERO` on release. The tracker is not
disabled: an override only replaces the direction it turns toward, so its speed, easing and
weights carry the head into the pitch and back out of it (~0.4 s each way at the defaults). The
muzzle marker rides on the head, so it rises about 0.6 m while lobbing; the lob solver aims from
wherever it is, and the shells still land on the aim point. The shot always leaves at the lob
angle, even in the first few frames while the head is still turning up to it.

### Kill path (GPU-initiated)

```
projectile_compute.glsl clears PROJ_FLAG_ALIVE in flags slot
  → UpdateProjectileLifetimes() detects flag cleared (readback every 2 frames,
    of the slots below _projHighWater only)
       ├─ Fires _projHitCallbacks[slot](hitPos)
       │    └─ ProjectileBase._on_gpu_hit(pos) → kill(pos, HitType.HOG)
       └─ Clears alive flag in GPU buffer, pushes slot back onto _projFreeSlots
```

### Kill path (lifetime expiry)

```
ability.lifetime runs out in flight (nothing hit, ground never reached)
  ├─ GPU: projectile_compute clears PROJ_FLAG_ALIVE when its lifetime reaches 0
  ├─ Node: ProjectileBase._step expires it on the same step → expire() → _on_expire()
  │        (no projectile_impact, no explosion — it hit nothing)
  └─ C#: _projLifetimes[slot] (lifetime + PROJ_LIFETIME_GRACE) ticks to zero
       → Writes _zeroFlagBytes to GPU PROJ_FLAGS offset (safety net)
       → Pushes slot back onto _projFreeSlots
```

`_projFreeSlots` is a stack, filled so that slot 0 comes out first: live projectiles stay packed
at the bottom, and `_projHighWater` — one past the highest slot in use, lowered past free slots
at the end of `UpdateProjectileLifetimes` — bounds the projectile dispatch (`num_projectiles`
push constant), the flag readback and the C# slot loops. With no projectile live the projectile
dispatch and its barrier are skipped. Every slot at or above the mark is dead on the GPU: killed
there, or by the `_zeroFlagBytes` write, which lands before the next dispatch. It used to be a
FIFO queue that cycled through all 1024 slots, so all of them were dispatched and read back.

C# fires **no hit callback** for a lifetime expiry: by then the slot is inside its grace window,
which `ReclaimGpuKilledProjectiles` skips. So the node has to expire itself — before it did, a
shot that never came down (aimed toward a far point and tipped upward by spread, or one that got
no GPU slot) flew on forever.

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
| Trigger zones | Any `CollisionShape3D` with metadata key `damage`, `multiply`, or `add` | **No** — hogs pass through | CPU, `ReadbackPass` → `TestTriggerZones` on the transform readback |

### Cache lifecycle

`_staticShapes`, `_movableShapes`, `_staticObstacleData`, and `_triggerZones` are
null until first use (`EnsureObstacleCache()`), then held until `InvalidateObstacleCache()`
is called. Visibility changes on any `Node3D` under `ObstaclesRoot` auto-fire
`InvalidateObstacleCache` via connected signals — **except** trigger zone shapes
(connecting them would race with the trigger-zone pass).

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

### Two distances to an obstacle

`get_obstacle_surface` takes a `padding` that it adds to the obstacle (on top of its
`margin`). The two physics passes use it differently, on purpose:

- **Soft steering** pads by the body radius, so its distance is the gap at the hog's *edge*
  — what `OBSTACLE_DETECT_RADIUS` is measured against.
- **The hard (PBD) contact** pads by nothing and measures from the hog's *centre*, then adds
  how far the **drawn** hog reaches toward the obstacle: the support distance of the mesh's
  XZ footprint (`footprint_min/max` push constants, measured from `Multimesh.Mesh.GetAabb()`
  in `SetupMultiMesh`), turned by the hog's facing, never less than `BodyRadius`. `BodyRadius`
  is only the spacing between hogs and is much smaller than the mesh (0.15 vs a 0.5 × 0.75 box),
  so a contact built on it lets the mesh sink into walls. The old code padded by the radius
  twice, which happened to hide most of that: measured against the CircularPancake with the
  0.5 × 0.75 box, 3 of 37 boxes sat up to 9.7 cm inside it; with the footprint, none, and the
  closest rests at the 5 cm margin. Swapping the hog mesh needs no code change. Friction still
  grows with overlap depth, so hogs slide along walls instead of sticking.

---

## 10. Signal Architecture

All cross-system signals are declared on the `Global` autoload (`Global.gd`).
Components connect to `Global`, never to each other directly.

The exception is a component's own lifecycle: a signal about nothing but the node it is
attached to may be declared on the component, since there is no cross-system coupling to
route through `Global`. `GateAnimation.fully_opened` / `fully_closed` are the current
example. Anything a *second* system reacts to still belongs on `Global`.

```
Global.gd signals:
  projectile_impact(pos: Vector3, hit_type: HitType)   ← fired by ProjectileBase.kill()
  projectile_launched(from: Vector3, to: Vector3)      ← fired by ProjectileBase.launch()
  score_hit(ui_marker: Marker2D)                       ← fired by HogsKilled.gd
  notification_wrapped                                 ← fired when UI notification wraps

SquadMultiMeshInstance3D C# signals:
  HogsDied(indices, positions, stateBits)           ← once per tick with that tick's deaths, as
                                                      three parallel packed arrays (EmitHogsDied)
  ZoneTriggered(zone, effect, count, position)      ← once per tick per zone hogs entered, with how
                                                      many and where the last one was
                                                      (EndTriggerZonePass); whether or not ShowHogs
  HogStateChanged(index, newState, worldPos)        ← declared, unused (available for GDScript)
```

Both used to fire once per hog — `HogDied(index, position, stateBits)` and
`HogZoneTriggered(hogIndex, position, zone, effect)` — so a bomb killing ten thousand hogs, or a
crowd pouring through a gate, made that many Variant-marshalled calls into GDScript in one tick,
each handler instancing nodes. No script runs during the readback pass any more: both are
emitted after it. The death count for the HUD is a property, `DeadHogCount`, like `AliveHogCount`.

`GateTrigger.trigger(count, position, zone, effect, show_fx)` counts down by `count` and plays
one flash and one `Announce3D` per call, however many hogs entered that tick. `show_fx` is the
squad's `ShowHogs` (`HogZoneTriggers.gd` passes it): with the crowd hidden the gate still counts
its triggers and closes, but skips its flash and announcement.

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
- **Obstacle staging:** `float[] _obstacleStaging` grown with headroom, never shrunk, and
  queued straight from the floats with `MemoryMarshal.AsBytes` (as are the bomb and projectile
  staging floats); there is no separate byte copy any more.
- **Projectile staging:** `float[] _projAllStagingFloats` (size `MAX_PROJECTILES *
  PROJ_STRIDE`) written in `SpawnProjectile`, queued per slot in `UploadPendingProjectiles`.
- **Hog spawns:** `SpawnHogs` writes its `GpuBody` structs straight into the queue's payload
  through `ReserveGpuWrite` + `MemoryMarshal.Cast<byte, GpuBody>`, not into a new array.
- **Batched signals:** `HogsDied`'s three arrays come from `List`s cleared each tick and passed
  as spans (`Variant.CreateFrom(CollectionsMarshal.AsSpan(...))`).
- **Movable obstacle state:** two `Dictionary<CollisionShape3D, (Vector2, float)>`
  swapped each frame via tuple assignment — no new dictionary allocated.
- **Label sets:** two `HashSet<int>` swapped after each full recalculation.
- **Death FX:** pooled `Queue<Node3D>` capped at `MAX_POOLED_DEATH_FX`.
- **GDScript calls:** method and action names are `static readonly StringName` fields
  (`_releaseLabelMethod`, …). A string literal passed to `Call`/`IsActionPressed` builds a new
  `StringName` every call.

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

GPU writes are queued (`EnqueueGpuWrite`, or `ReserveGpuWrite` to fill the payload in place) and
applied by `FlushGpuCommands` just before the next dispatch. Writes queued in `CompleteGpuTick`
(trigger-zone damage) or in the staging calls after it (projectile reclaim) therefore reach the
dispatch submitted later in the same `_PhysicsProcess`. This is the expected pattern for
`DamageHogViaBuffer` and projectile reclaim writes.

A write that continues the previous command — same target, next offset — is merged into it, so a
run of `SpawnHogs(1)` calls from a gate, or consecutive projectile slots, is one `BufferUpdate`.
Only adjacent writes merge; a write *replaces* the bytes it covers, and two writes to the same
word are not summed.
`DamageHogViaBuffer` relies on physics zeroing `damage_accum` every frame, so it must run at
most once per hog per frame — trigger zones sum their damage per hog with `QueueZoneDamage` and
write it once in `FlushZoneDamage`. Two direct calls in one frame keep only the last.

### Uniform set lifecycle

Uniform sets are invalidated whenever a referenced buffer is freed and recreated
(e.g., `SpawnHogs` reallocating `_physicsBuffer`). When any buffer RID changes:
1. Set the affected uniform set fields to `new Rid()`.
2. Call the corresponding `RebuildXxxUniformSet()` before the next dispatch.

There are **three** uniform sets — `_physicsUniformSet`, `_hashUniformSet`,
`_projUniformSet` — since the transform set went away with its shader. All three reference
`_physicsBuffer`, so a body buffer reallocation must rebuild all three.

`_physicsUniformSet` spans bindings 0–7: bodies, obstacles, bombs, hash counts, hash entries,
instances, neighbour snapshots, fear words; `_hashUniformSet` 0–4: bodies, hash counts, hash
entries, neighbour snapshots, fear words. Binding 5 (the instance buffer) means
`_transformBuffer` must exist *before* `RebuildPhysicsUniformSet()` is called, and likewise
`_neighbourBuffer` / `_hashFearBuffer` before both sets — check the ordering in `SetupCompute`
if you move buffer creation around. `ApplyPhysicsGrowth` recreates `_neighbourBuffer` with the
bodies (nothing to copy: the build rewrites every snapshot it hands out each tick).

Free uniform sets **before** the buffers they reference, not after. `ApplyPhysicsGrowth` was
leaking four sets per growth event until this was fixed.

---

## 12. Performance Rules

These are non-negotiable. Do not introduce patterns that violate them.

1. **No per-frame heap allocations in `_PhysicsProcess` or any callee.** Use
   pre-allocated staging buffers, span overlays, and `Buffer.BlockCopy`.

2. **No `get_nodes_in_group` or `get_children` in `_PhysicsProcess` or
   `_physics_process`.** Cache node references at `_ready` time.

3. **One GPU submit per physics frame, synced at the start of the next.** All three dispatches
   are in a single `ComputeListBegin → End → Submit`; its `Sync` is the first thing the next
   `_PhysicsProcess` does (`CompleteGpuTick`). A local RenderingDevice must be synced before
   anything else is recorded or read, so never submit twice, and never touch `_rd` between the
   `Submit` and that `Sync`.

4. **No additional `BufferGetData` calls beyond the existing transform readback, the
   throttled projectile flag readback, and the 1 Hz hash-overflow sample (which only runs
   when `DebugHashOverflow` is set).** Each `BufferGetData` forces a GPU sync stall.

4a. **All GPU buffer mutations go through `EnqueueGpuWrite` / `ReserveGpuWrite` / `EnqueueGpuClear` / `EnqueueGrowXxx`.** Do not call
   `_rd.BufferUpdate`, `_rd.BufferCopy` or `_rd.BufferClear` outside `GpuQueue.cs`. See §5.

4b. **Read back only the live prefix.** The transform readback is
   `_gpuTickBodies * INSTANCE_STRIDE * sizeof(float)` — the bodies that dispatch covered — not
   the full `_bodyCapacity`. Every consumer takes its count from the span it is handed, so copying
   the slack was pure waste.
   `BODY_CAPACITY_GROWTH` is 2 with a `BODY_CAPACITY_MIN_STEP` of 256. It was 1.25 while the
   MultiMesh was sized to the capacity and uploaded in full every frame; now that it is sized
   to the drawn hogs, spare capacity costs only VRAM, and doubling keeps growth (a GPU copy of
   every body plus three uniform-set rebuilds) rare while gates keep adding hogs.

5. **Projectile flag readback is throttled to every 2 physics frames**, and covers only the
   slots below `_projHighWater` (§8). It only runs when at least one uploaded slot is active.
   Do not remove the `AnyProjectileActiveOnGpu` guard.

6. **Dead hogs are never removed from the body buffer.** `STATE_DEAD` is the
   authoritative marker. `DrawHogs` walks only the live list, so corpses never reach the
   MultiMesh buffer. Body indices are permanent for the lifetime of the scene. The readback pass
   remembers which deaths it has handled in `_deadHogs`, a `bool[]` sized to `_bodyCapacity` and
   grown in `SpawnHogs` — it was a `HashSet<int>`, probed for every corpse on every tick.

6a. **The MultiMesh is uploaded once per rendered frame, by `DrawHogs`, and only with the hogs in
   view.** Do not upload it from the tick again, and do not turn `FrustumCulling` off to make a
   count come out right: `Multimesh.VisibleInstanceCount` is the number drawn, `AliveHogCount` the
   number alive. Keep setting the custom AABB before `MultimeshSetBuffer`, so that Godot does not
   rebuild one from every row of the buffer (0.36 vs 1.13 ms per upload at 100k). Keep the
   MultiMesh sized by `DrawHogs` (§5); do not tie `InstanceCount` to the body capacity again.

6b. **Every GPU write goes through `BufferUpdate`'s `ReadOnlySpan<byte>` overload**, sliced to the
   payload. The `byte[]` overload marshals the whole array, so handing it a grow-only scratch
   array copied kilobytes into a native array for every 4-byte zone-damage write.

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
  guessing. Until `_Process` zeroed `VisibleInstanceCount` for it, only the `show_hogs` key did:
  setting the property from a script stopped the uploads and left the last crowd drawn, frozen.
  The "hidden" figures measured that way (before frustum culling) still included drawing the crowd.
- ~0.5% of hogs end up inside an obstacle at `PBD_ITERATIONS = 1` in a dense crowd. Pre-existing
  solver behaviour, verified identical with and without the broad-phase.

**Crowd size.** With the box mesh `Main.tscn` now ships, the default camera and hogs scattered
over the map (about half in view), M4 Pro, as shipped vs the version before frustum culling,
measured in one session: 20k–75k at the 120 fps display cap either way; 100k 97 fps (65 before);
125k 28–47 fps (19), simulation at 86–94% of real time; 150k 13.5 fps (6.5), 90%. **With the hogs
truly hidden, every size up to 150k runs at the display cap: the simulation does not limit the
crowd, drawing it does.** The same session measured the pre-culling code much faster than an
earlier one had (65 vs 39 fps at 100k), so compare numbers only within a session, interleaving
the configurations.

History: before the pipelining and the optimised build, 100k was 20 fps; pipelining alone took it
to 24, the optimised build to 39 (the earlier session). With a synced tick, 100k cost roughly: GPU
dispatch + `Sync` 4–10 ms (grows with crowd density), `BufferGetData` ~1.1 ms, compaction ~1 ms
(unoptimised), trigger zones ~3 ms (unoptimised; plus 1–3 ms of `HogZoneTriggered` handlers while
hogs are shown), `MultimeshSetBuffer` ~1.1 ms (0.36 ms since the custom AABB). Pipelining won less
than the idle `Sync` suggested, presumably because compute and rendering share the one GPU.

- **Frustum culling (§5).** The default view draws about half the crowd, a close one a fifth. At
  100k: 65 fps before, 76 with the per-frame upload and custom AABB but `FrustumCulling` off, 97
  with it on. In a slower session, interleaved: close view 65 → 88 fps, far 77 → 103. `DrawHogs`
  itself costs ~1.0 ms at 100k (0.75 ms with culling off), once per rendered frame, where the
  compaction and upload it replaced ran once per tick, up to 8 times a frame in catch-up.

- **Shadow casters.** Hogs sit on visual layer 4 (`layers = 8`), which the target-marker omni,
  the teleport spot and the bomb omni leave out of their `shadow_caster_mask`: only the sun's
  shadow map draws hogs. Projectiles and death-FX particles cast no shadows; the sun uses 2
  cascades over 60 m (it was 4 over 100); the wall materials dropped subsurface scattering.
  Measured with 50k hogs started under the target omni, interleaved, 3 pairs: 2.07 vs 2.23 ms a
  frame, consistent but inside the noise floor. Frames are now cheap enough that shadows no
  longer dominate this scene the way the 20k table above shows.

- **Mass deaths.** A bomb killing a settled pile of 50k hogs at once, measured over the 60 frames
  after it, 3 interleaved pairs: worst `_PhysicsProcess` 40 → 16 ms, worst frame 48 → 24 ms, from
  batching `HogDied` into `HogsDied`, the single readback pass and the `DrawableGround` ring.
  Steady-state frame time at 100k did not move measurably (the run was pinned at the display's
  120 Hz by driver vsync); the MultiMesh upload now follows the drawn count, e.g. 1.3k rows
  instead of the 30k capacity after a bomb.

- **Neighbour snapshots and fear words (§7).** GPU timestamps around each pass, 100k hogs
  scattered over 60 × 120 m and gathering on the target, a fear bomb every 0.5 s from t = 10 s,
  3 interleaved pairs:

  | per tick | before | after |
  |---|---|---|
  | physics, calm (t 3–9 s) | 4.43–4.74 ms | 2.62–2.67 ms |
  | physics, bombs (t 11–18 s) | 4.20–4.40 ms | 2.89–2.95 ms |
  | hash build, calm / bombs | 46–48 / 50–53 µs | 82–87 / 132–148 µs |

  Forcing the old scan to 3×3 or 5×5 for every hog measured 3.26 vs 5.24 ms: the outer ring was
  ~2 ms whenever it ran. The build pays for the snapshot writes and the fear atomics. The same
  runs ended with 88.0–88.3k hogs alive against 88.6–88.9k before (deaths come from the damage
  zones the crowd is pushed into): reading every neighbour's start-of-tick state, instead of
  whichever side of its own update the racy read caught, shifts the crowd slightly.
  Measure GPU passes this way, not by frame time: a one-point spawn (`SpawnPoint` set, as in
  `Main.tscn`) puts 100k hogs in one cell, overflows it, and times nothing but atomic contention.

- **The cliff is the physics catch-up, not linear cost.** Physics is fixed at 60 Hz; once a tick
  plus the frame's drawing exceeds 16.7 ms, Godot runs extra ticks per frame (up to
  `max_physics_steps_per_frame`, 8), and every tick here is a full dispatch + `Sync`. Before the
  trigger-zone rewrite (§14) a 100k tick was ~17.6 ms on its own, so every frame ran 8 ticks (6 fps).
  Capping the steps at 2 gives smoother frames but slows the simulation below real time.
- **Optimised vs unoptimised C#.** The csproj optimises every configuration (§2). To compare
  against unoptimised code, `dotnet build -p:Optimize=false --no-incremental` — without
  `--no-incremental` MSBuild skips the recompile and the flag silently does nothing.
- **`BufferGetData` allocates the whole readback every tick** (8 MB at 100k), a large-object
  allocation that triggers a gen-2 GC roughly every third tick. Not yet avoided.

---

## 13. Making Changes — by Task Type

### Add a new projectile ability

1. Create `projectiles/MyAbility.tres` (class: `ProjectileAbility`).
2. Set the ability fields: `damage`, `radius`, `force`, `contagion_type`, etc. For flight:
   `speed` (direct shots), `gravity_scale`, `launch_angle_deg` (> 0 lobs it onto the target),
   `spread_deg`, `speed_variance`, `fire_interval`; for a burst on impact, `explosion_*`.
3. Add a matching input action in Godot's Project Settings → Input Map.
4. In `Main.gd`, preload the resource and, in `_physics_process`, call
   `spawn_projectile(my_ability)` when the action is held **and**
   `_ready_to_fire(my_ability)` — that is what applies `fire_interval`.
5. No C# changes needed unless the ability requires a new GPU field.

### Add a new GPU body field

1. Add the field to `GpuBody` in `SquadMultiMeshInstance3D.cs` (maintain
   `LayoutKind.Sequential, Pack = 4`).
2. Update `BODY_STRIDE` if total float count changes.
3. Add the matching field at the same offset to `struct Body` in **all three** shaders —
   `physics_compute.glsl`, `spatial_hash_build.glsl`, `projectile_compute.glsl`. Missing one
   silently corrupts the stride for that shader only, which is a miserable bug to find.
   If physics' neighbour scan needs to read it from *other* hogs, add it to `struct Neighbour`
   in the build and physics shaders instead of reading `bodies[i]`, and update
   `NEIGHBOUR_STRIDE` (a multiple of 8: std430 aligns the struct's `vec2` members to 8) (§7).
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
4. Add a case to the `switch (zone.Effect)` in `OnZoneEntered` (TriggerZones.cs).

### Add a new GDScript visual component

1. Create the script under `components/` or `visuals/`.
2. Connect to `Global` signals rather than to specific nodes.
3. If it needs hog position data, connect to `HogsDied` or
   `ZoneTriggered` on the `SquadMultiMeshInstance3D` node — do not read
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

### Trigger zones are one pass with a bitmask per hog — keep them that way

`ReadbackPass` walks the readback once, and `TestTriggerZones` tests each live hog against every zone (a world-aligned
box reject from `GetTriggerBounds`, then the exact circle / OBB). Occupancy is a `ulong` per hog in
`_zoneMasks`, bit *z* for zone *z*, so an enter is `inside & ~previous`. It used to keep a
`HashSet<int>` of occupants per zone and walk every hog once per zone: at 100k hogs and four zones
that was ~10 ms of every tick, half the tick, and the reason 75k hogs fell into the physics
catch-up spiral (§12.1). Do not reintroduce a per-zone pass or a per-hog hash lookup.

Behaviour the masks preserve:

- A zone that is disabled or hidden this pass is left out of `activeMask`; its bits carry over, so
  it neither fires nor forgets who was inside.
- When `_triggerZones` is rebuilt (a new list), `_zoneMasks` is cleared: every hog inside a zone
  enters it again, as it did when rebuilt zones started with empty occupant sets.
- At most `MAX_TRIGGER_ZONES = 64` zones are tested (one bit each); extras are ignored with a warning.
- `_zoneMasks` is sized to `_bodyCapacity` and grown with `_hogStates` in `SpawnHogs`. Nothing can
  grow it mid-pass: Multiply/Add spawns are deferred to `EndTriggerZonePass`, and `ZoneTriggered`
  is emitted only after the walk, so no script runs during it.
- The pass is one walk with the death check and the live list (`ReadbackPass`), not a walk of its
  own: `BeginTriggerZonePass` resolves the zones, `EndTriggerZonePass` applies damage, spawns and
  signals. Keep new per-hog CPU work in that walk rather than adding another over 8 MB of rows.

### Trigger zone shapes must not connect VisibilityChanged

`ConnectVisibilitySignals` explicitly skips shapes with `damage` / `multiply` / `add`
metadata. If a new trigger effect key is added, it must be added to the `isTriggerZone`
check there, or visibility toggles on trigger shapes will null `_triggerZones`
mid-pass.

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

`_deathFxTotalCreated` is capped at `MAX_POOLED_DEATH_FX = 30`. When every pooled effect is
playing and the cap is reached, `DrainDeathFxQueue` clears the rest of the queue: those deaths
get no effect rather than a late one at a stale position. This is intentional to prevent
unbounded node creation. `MaxDeathFxPerFrame` only matters below the pool size; raise
`MAX_POOLED_DEATH_FX` if deaths feel visually sparse at high kill rates.

### Frame stamp must advance after Sync, not before

`_hashFrameStamp` is advanced in `CompleteGpuTick`, after `_rd.Sync()` and before the next
tick's push constants are written. Moving it between writing the push constants and `Submit`
would cause the hash build, projectile and physics shaders in the same frame to disagree on
which stamp is "current", leading to physics seeing stale hash buckets.

### The GPU runs a tick behind — code that reads it must allow for that

`_PhysicsProcess` returns with its dispatch still running; `CompleteGpuTick` at the top of the
next one syncs it. Consequences for new code:

- **Read GPU buffers only after `CompleteGpuTick`.** `BufferGetData` (or anything else on `_rd`)
  between the `Submit` and that `Sync` is not allowed on a local RenderingDevice.
  `UpdateProjectileLifetimes` is called after it for this reason. `Dispose` syncs a pending tick
  before freeing anything.
- **Use the readback's count, not `NumBodies`.** Hogs spawned since the dispatch (from `_Process`,
  or by the trigger-zone pass) have no row in the instance buffer yet, and the capacity growth
  they queued is only applied at the next flush — the buffer may be smaller than `NumBodies` rows.
  The readback covers `_gpuTickBodies`; `ReadbackPass`, `UpdateLabels` and `DrawHogs` take their
  count from the span or from the live list built from it.
- **Growth leaves the MultiMesh alone.** `ApplyPhysicsGrowth` resizes the body and instance
  buffers only; the MultiMesh is sized by `DrawHogs` (§5), which resizes and refills it in the
  same call. To test for a blank frame, note that `Multimesh.VisibleInstanceCount` still reads
  the old value after a resize: look at `RenderingServer.MultimeshGetBuffer`, from
  `RenderingServer.FramePreDraw`.

### Do not mark the body buffer `coherent`

None of the three shaders declares a `coherent` buffer, deliberately. Atomics are device-scope
with or without the qualifier (the SPIR-V atomics are identical either way), and no invocation
reads another body's plain fields: the neighbour scan reads the build's snapshots (§7). The
qualifier only costs: Godot's Metal backend (SPIRV-Cross) turns it into `coherent device` at
MSL 3.2+ and `volatile device` below that, so loads skip the cache. `coherent` (plus a
`memoryBarrier`) is only for an invocation that must *observe* another's plain write within
the same dispatch; nothing here does that.

### `Multimesh.VisibleInstanceCount` vs `Multimesh.InstanceCount` vs `AliveHogCount`

`InstanceCount` is the MultiMesh's allocated rows, sized by `DrawHogs` to about 1.25× the hogs it
draws (§5) — not the body capacity, and not the number alive.
`VisibleInstanceCount` is set each frame to the number of hogs `DrawHogs` uploaded: the live ones
in the camera's view, often half the crowd or less. Rendering respects `VisibleInstanceCount`. For
how many hogs are alive, read `AliveHogCount` (the HUD's `TotalHogs.gd` does); it used to be
`VisibleInstanceCount`, before culling. Do not confuse any of them with `NumBodies` when
calculating buffer sizes or work group counts.

### Hogs are culled to the viewport's current camera

`DrawHogs` culls against `GetViewport().GetCamera3D()`. Anything else that renders the crowd, such
as a second camera, a SubViewport or a split screen, sees only what the main camera sees; turn
`FrustumCulling` off for that. Hogs within `FrustumCullMargin` (2 m) plus the mesh's bounding
radius of the view are kept, so a hog just off-screen still casts its shadow into view. The sun is
78° up, so hog shadows from it reach ~0.1 m. The sun is the only light hogs cast shadows from
(§12.1, shadow casters); if a low omni or spot light gets the hog layer back in its caster mask,
a hog further off-screen than the margin, between that light and a surface in view, loses its
shadow there. Raise the margin if that shows.

### Never write `bodies[id] = self` in physics_compute

The two contagion arrays are atomic-owned and written by other invocations concurrently (§7). A
wholesale struct store clobbers them. The shader writes 16 named fields instead.

Do not bring back a stored, shared `state` word for the contagion bits. It needed an
`atomicAnd`/`atomicOr` dance so neighbours' bits survived, which forced those bits to be sticky
past expiry; every attempt to clear them from a local snapshot raced a neighbour setting one
("contagion infects but instantly disappears"). Deriving the bits from the per-type expiries
each frame removed the problem instead of guarding it.

### Work group count uses NumBodies, not InstanceCount

```csharp
var workGroups = (uint)Mathf.CeilToInt((float)NumBodies / GPU_THREAD_GROUP_SIZE);
```
`NumBodies` tracks the *current* logical count (grows when hogs are spawned).
`_bodyCapacity` can be larger due to capacity
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
      `struct Body` copies updated to match (§7), and `struct Neighbour` (build + physics)
      matches `NEIGHBOUR_STRIDE` if a neighbour field changed
- [ ] If a GPU buffer write was added → it goes through `EnqueueGpuWrite`, not a direct
      `_rd.BufferUpdate` (§5)
- [ ] If contagion logic changed → every infection goes through `infect()` (both copies
      identical), each type's expiry is only ever raised via `atomicMax`, the state bits are
      still derived from the live types, and the chain still terminates (§7)
- [ ] If a new buffer RID field was added → `Dispose()` frees it; `SpawnHogs`
      rebuilds its uniform set
- [ ] If new code reads a GPU buffer or the transform readback → it runs after
      `CompleteGpuTick`'s `Sync`, and counts bodies from the readback, not `NumBodies` (§14)
- [ ] If new code needs the number of live hogs → `AliveHogCount`, not
      `Multimesh.VisibleInstanceCount`, which counts only the hogs in view (§14)
- [ ] If a new per-frame code path was added in C# → no heap allocations
      (verify with Rider's Heap Allocations Viewer or manual audit)
- [ ] If a new trigger effect key was added → `FindCollisionShapes`,
      `ConnectVisibilitySignals`, `ScanForTriggers`, and `OnZoneEntered`
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
