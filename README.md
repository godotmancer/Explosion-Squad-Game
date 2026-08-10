# Explosion Squad Godot Game Sandbox

![Godot](https://img.shields.io/badge/Godot-4.7-blue?logo=godotengine&logoColor=white)
![Language](https://img.shields.io/badge/GDScript%20%2B%20C%23-mixed-purple)
![License](https://img.shields.io/badge/License-MIT-green)
![Platform](https://img.shields.io/badge/Platform-Desktop-lightgrey)

A GPU-accelerated 3D action sandbox where you throw various projectiles at 5,000 simultaneously simulated hogs. All physics runs on the GPU via compute shaders — because doing it on the CPU would be a terrible idea.

> Built mainly to see how far you can push Godot's compute shader support before the GPU gives up. It hasn't yet.

---

![Gameplay screenshot](screenshots/main.png)

---

## What's in the box

- **5,000 hogs** running boids AI with separation, alignment, and cohesion — all on the GPU
- **4 compute shader dispatches per frame**: spatial hashing → projectile physics → boids/bombs/contagion → MultiMesh transform buffer
- **5 projectile types** with distinct behaviors (see below)
- **Contagion system**: fire, poison, and alcohol spread between hogs
- **Bomb mechanics**: radius blast + fear impulses that send nearby hogs into a panic
- **Death fear**: hogs near a death event briefly scatter
- **Floating damage numbers** that lerp from 3D world space to 2D screen positions
- **Post-process outline** via depth-based edge detection compute shader
- **Black hole bomb** with Doppler, warp, and accretion disc shader effects
- **Drawable ground**: impact marks baked from rotated/tinted textures at startup — no per-frame cost
- **Parabolic trajectory preview** at 120 Hz so you can aim your shots

---

## Projectiles

| Key | Type | Behavior |
|-----|------|----------|
| `1` | Bullet | 50 damage, hard knockback |
| `2` | Fire | 2.0 DPS, spreads fire contagion |
| `3` | Poison | 1.0 DPS, adds upward force, spreads poison |
| `4` | Drunk | 0.3 DPS, staggers hogs, spreads alcohol contagion |
| `5` | Teleport | Grabs a hog at 75% health and throws it as a projectile |

---

## Architecture

The language split is intentional and worth explaining:

- **C#** handles anything that talks to the GPU: compute shader dispatch, MultiMesh, projectile spawning facade, bomb spawner, and mouse→3D world position conversion (a speed improvemnt of about 30% versus GDScript)
- **GDScript** handles everything else: visuals, UI, camera, animation components, compositor effects.

```
GPU Physics Pipeline (per frame)
─────────────────────────────────
1. spatial_hash_build.glsl    — neighbor lookup in O(1)
2. projectile_compute.glsl    — projectile integration + sphere collision + damage (atomic ops)
3. physics_compute.glsl       — boids AI + bomb forces + fear + contagion spread
4. transform_compute.glsl     — builds MultiMesh transform buffer (1 draw call for all 5k hogs)
```

All 5,000 hogs render in a single draw call. The spatial hash makes neighbor queries O(1) instead of O(n²) — that part matters a lot at this scale.

---

## Controls

| Key / Input | Action |
|-------------|--------|
| `1–5` | Spawn projectile type |
| `S` | Spawn hogs |
| `A` | Show/Hide hogs |
| `L` | Toggle per-hog state labels |
| `P` | Pause (0.1× time scale) |
| Mouse drag | Orbit camera |
| Shift + drag | Pan camera |
| Pinch / scroll | Zoom |

---

## Screenshots

| Hog crowd | Contagion spread |
|---|---|
| ![crowd](screenshots/5000_hogs.png) | ![fire spread](screenshots/fire_spread.png) |

| Bomb blast   | Poisoned hogs   |
|---|---|
| ![bomb blast](screenshots/bombs.png) | ![poisoned hogs](screenshots/poisoned_hogs.png) |

---

## Project Structure

```
Explosion-Squad-Game/
├── Main.tscn / Main.gd              # Entry point, input dispatch
├── Global.gd                        # Autoload — state enums + cross-system signals
├── compute_shaders/                 # C# GPU manager + 4 GLSL compute shaders
│   ├── SquadMultiMeshInstance3D.cs          # Orchestrator — types, fields, lifecycle
│   ├── SquadMultiMeshInstance3D.GpuSetup.cs # Setup, Dispose, push constants, RebuildXxx
│   ├── SquadMultiMeshInstance3D.Obstacles.cs# Obstacle cache, OBB/circle emit
│   ├── SquadMultiMeshInstance3D.Projectiles.cs # Slot pool, SpawnProjectile, UploadPending
│   ├── SquadMultiMeshInstance3D.Bombs.cs    # Bomb buffer, death FX pool, OnHogDied
│   ├── SquadMultiMeshInstance3D.TriggerZones.cs # Zone detection, deferred spawns
│   ├── SquadMultiMeshInstance3D.Labels.cs   # Distance-sorted label assignment
│   ├── spatial_hash_build.glsl                # O(1) spatial hash construction
│   ├── physics_compute.glsl                   # Boids, obstacles, bombs, contagion
│   ├── projectile_compute.glsl                # Projectile integration + sphere collision
│   └── transform_compute.glsl                 # Writes MultiMesh transform buffer
├── projectiles/                     # GDScript visual projectiles + C# spawner facade
│   ├── ProjectilesSpawner.cs         # GDScript-callable C# facade
│   ├── ProjectileBase.gd             # Semi-implicit Euler physics, GPU sync
│   ├── ProjectileAbility.gd          # Resource class for ability data
│   └── *.tres                        # ProjectileAbility resources per type
├── bombs/
│   └── BombSpawner.cs                # Spawns bomb visual + invokes DropBomb callback
├── components/                      # GDScript @tool components
│   ├── Animator.gd                   # 8 animation modes with editor preview
│   └── LookAtTracker.gd              # Spring-physics smooth rotation
├── visuals/                         # GDScript FX
│   ├── Announce3D.gd                 # Floating damage numbers (3D → 2D)
│   ├── DrawableGround.gd             # Dynamic impact marks
│   ├── DeathFxScene.gd               # Particle FX, auto queue_free
│   └── HogLabels.gd               # Label3D pool, no per-frame allocs
├── compositor_fx/                   # Post-process Outline effect (GDScript + GLSL)
├── shaders/                         # Visual-only gdshaders
│   ├── black_hole_3d.gdshader        # Bomb vortex (spin, warp, Doppler, accretion)
│   ├── openvat.gdshader              # Vertex Animation Texture for deformation
│   └── broken_tv.gdshader            # TV glitch effect
├── ui/                              # GDScript UI nodes
│   ├── Fps.gd                        # FPS + active projectile count
│   ├── SquadsKilled.gd              # Kill counter
│   └── TrajectoryOverlay.cs          # 2D arc + 3D animated preview at 120 Hz
└── AGENTS.md                        # Architecture, layout, and instructions
```

---

## Running It

Requires Godot 4.7 with C# / .NET support.

```bash
# Open the editor
godot -e .

# Run directly
godot Main.tscn
```

Display is 780×1080 portrait, always-on-top, HDR enabled. Works best on a discrete GPU — compute shaders don't exactly thrive on integrated graphics.

---

## Key Tunable Values

These live in the inspector on `SquadMultiMeshInstance3D`:

```
NumBodies        = 5000
HogHealth     = 100
BombRadius       = 15
BombDamage       = 80
BombFearDuration = 3s
```

Boids parameters are in `physics_compute.glsl`:

```glsl
SEPARATION_PADDING = 3.0
ALIGNMENT_RADIUS   = 2.5
COHESION_RADIUS    = 5.0
```

---

## Performance Notes

The whole point of this project is that it stays fast. A few things that make that work:

- **MultiMesh instancing** — all 5,000 hogs in 1 draw call
- **Spatial hashing** — O(1) neighbor queries
- **Label3D pooling** — no allocs per frame
- **Pre-baked texture rotations** in `DrawableGround` — rotation pool built at startup
- **Forward Plus renderer** chosen for the GPU-heavy workload

---

## Assets and attributions

Hog characters, blasters, and environment pieces from [Kenney](https://kenney.nl/) asset packs (mini-characters, blaster kit, modular space kit, cube pets). Great quality, very permissive license.

OpenVAT for vertex animation textures [OpenVAT](https://openvat.org/) - #todo

Black Hole shader courtesy of: [hyperjragon](https://godotshaders.com/author/hyperjragon)

Editor Config based on [Chickensoft Games C# Template](https://github.com/chickensoft-games/EditorConfig)

---

## License

MIT — see [LICENSE](LICENSE).

Do whatever you want with it. If you find the compute shader pipeline useful, great. If something is broken, well, it worked on my machine.
