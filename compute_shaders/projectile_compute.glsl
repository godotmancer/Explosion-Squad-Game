// =============================================================================
// PROJECTILE COMPUTE SHADER
// =============================================================================
// Runs every physics frame AFTER spatial_hash_build and BEFORE physics_compute.
//
// Each invocation handles one projectile:
//   1. Skip inactive slots (PROJ_FLAG_ALIVE clear).
//   2. Integrate 3D position (gravity + velocity).
//   3. Expire if lifetime ≤ 0 or projectile hits the ground.
//   4. Query the spatial hash (3×3 XZ neighbourhood) for candidate bodies.
//   5. Sphere-vs-sphere 3D collision check.
//   6. On hit: apply flat damage, contagion, knockback impulse, teleport via
//      atomic operations on Body fields. Kill the projectile.
//
// Special case — PROJ_FLAG_IS_HOG:
//   The projectile was thrown by a live hog (source_body ≥ 0).
//   Actual damage = proj.damage (treated as health fraction 0-1) × source health.
//
// Bindings (set 0):
//   0 — BodiesBuffer      (coherent read/write — atomics for damage/impulse/etc.)
//   1 — ProjectilesBuffer (coherent read/write — position integration, alive flag)
//   2 — HashCountsBuffer  (readonly)
//   3 — HashEntriesBuffer (readonly)
// =============================================================================
#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ---------------------------------------------------------------------------
// ⚠ KEEP IN SYNC — 28 floats, identical field order in all four copies:
//   compute_shaders/physics_compute.glsl
//   compute_shaders/spatial_hash_build.glsl
//   compute_shaders/projectile_compute.glsl        (this file)
//   compute_shaders/SquadMultiMeshInstance3D.cs  (struct GpuBody, BODY_STRIDE)
// Adding/reordering/resizing a field in one without the others silently
// corrupts the buffer stride. No GLSL #include exists, so this is manual.
// ---------------------------------------------------------------------------
struct Body {
    vec2  position;
    vec2  velocity;
    float height;
    float vertical_velocity;
    float radius;
    float mass;
    float facing_angle;
    float wander_angle;
    float health;
    float last_hit_time;
    float bomb_origin_x;
    float bomb_origin_y;
    float damaged_time;
    uint  state;
    uint  damage_accum;
    uint  contagion_timer_u;
    uint  dps_rate_u;
    uint  body_flags;
    float teleport_x;
    float teleport_z;
    int   impulse_x;
    int   impulse_z;
    int   impulse_y;
    float teleport_y;         // 25  teleport spawn height
    float speed_ema;          // 26  written by physics_compute.glsl only, unused here
    float pad3;               // 27
};

// ---------------------------------------------------------------------------
// Projectile struct — PROJ_STRIDE = 24 floats (96 bytes, 4-byte aligned)
// ---------------------------------------------------------------------------
struct Projectile {
    float pos_x;          //  0  world X
    float pos_y;          //  1  world Y (height)
    float pos_z;          //  2  world Z
    float radius;         //  3
    float vel_x;          //  4
    float vel_y;          //  5
    float vel_z;          //  6
    float damage;         //  7  flat damage OR health_fraction (if IS_HOG)
    float dps;            //  8  damage per second for contagion
    float force;          //  9  knockback magnitude
    float force_dir_x;    // 10  knockback direction unit vector
    float force_dir_y;    // 11  (Y component — launches hogs into air)
    float force_dir_z;    // 12
    float lifetime;       // 13  remaining seconds (decremented here)
    float teleport_x;     // 14  XZ destination
    float teleport_z;     // 15
    uint  contagion;      // 16  STATE_ON_FIRE | STATE_POISONED | STATE_DRUNK
    float contagion_dur;  // 17
    uint  flags;          // 18  PROJ_FLAG_ALIVE | PROJ_FLAG_HAS_TELE | PROJ_FLAG_IS_HOG
    float source_body;    // 19  body index as float, -1 = no source
    float teleport_y;     // 20  spawn height for teleport (world Y)
    float _pad21;         // 21
    float _pad22;         // 22
    float _pad23;         // 23
};

// ---------------------------------------------------------------------------
// Buffer bindings
// ---------------------------------------------------------------------------
layout(set = 0, binding = 0, std430) coherent buffer         BodiesBuffer      { Body       bodies[];      };
layout(set = 0, binding = 1, std430) coherent buffer         ProjectilesBuffer  { Projectile projectiles[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer HashCountsBuffer  { uint       hash_counts[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer HashEntriesBuffer { uint       hash_entries[];};

layout(push_constant, std430) uniform Params {
    float delta_time;
    int   num_projectiles;
    int   num_bodies;
    float gravity;
    float y_offset;
    uint  frame_parity;
    float time;
    float pad;
};

// ---------------------------------------------------------------------------
// Projectile flag bits
// ---------------------------------------------------------------------------
const uint PROJ_FLAG_ALIVE     = 1u;
const uint PROJ_FLAG_HAS_TELE  = 2u;
const uint PROJ_FLAG_IS_HOG = 4u;

// ---------------------------------------------------------------------------
// Body flag bits (must match physics_compute.glsl)
// ---------------------------------------------------------------------------
const uint BODY_FLAG_TELEPORT  = 1u;
const uint BODY_FLAG_HIT_FRAME = 2u;

// ---------------------------------------------------------------------------
// Fixed-point scales (must match physics_compute.glsl)
// ---------------------------------------------------------------------------
const float DAMAGE_SCALE    = 256.0;
const float CONT_TIME_SCALE = 256.0;
const float IMPULSE_SCALE   = 1000.0;

// ---------------------------------------------------------------------------
// Spatial hash constants (must match spatial_hash_build.glsl)
// ---------------------------------------------------------------------------
const uint  HASH_TABLE_SIZE   = 4096u; // MUST be a power of two — spatial_hash masks with (size - 1)
const uint  HASH_MAX_PER_CELL = 64u;
const float HASH_CELL_SIZE    = 2.0;

uint spatial_hash(int cx, int cz) {
    uint hx = uint(cx) * 2654435761u;
    uint hz = uint(cz) * 2246822519u;
    return (hx ^ hz) & (HASH_TABLE_SIZE - 1u);
}

// ---------------------------------------------------------------------------
void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(num_projectiles)) return;

    Projectile proj = projectiles[id];
    if ((proj.flags & PROJ_FLAG_ALIVE) == 0u) return;

    // Decrement lifetime and integrate the 3D position under gravity.
    proj.lifetime -= delta_time;
    proj.vel_y    -= gravity * delta_time;
    proj.pos_x    += proj.vel_x * delta_time;
    proj.pos_y    += proj.vel_y * delta_time;
    proj.pos_z    += proj.vel_z * delta_time;

    // Expire when its time runs out or it strikes the ground — kills zombie
    // projectiles burning GPU time. The body dies this frame either way; a dead
    // projectile is skipped everywhere, so the extra integration step is harmless.
    if (proj.lifetime <= 0.0 || proj.pos_y < y_offset) {
        proj.flags &= ~PROJ_FLAG_ALIVE;
        projectiles[id] = proj;
        return;
    }

    // ------------------------------------------------------------------
    // Spatial hash collision query — 3×3 XZ neighbourhood
    // ------------------------------------------------------------------
    int cx = int(floor(proj.pos_x / HASH_CELL_SIZE));
    int cz = int(floor(proj.pos_z / HASH_CELL_SIZE));

    bool hit = false;

    for (int dcx = -1; dcx <= 1 && !hit; dcx++) {
        for (int dcz = -1; dcz <= 1 && !hit; dcz++) {

            uint bucket = spatial_hash(cx + dcx, cz + dcz);
            uint stored  = hash_counts[bucket];
            if ((stored >> 31u) != frame_parity) continue;
            uint count = min(stored & 0x7FFFFFFFu, HASH_MAX_PER_CELL);

            for (uint k = 0u; k < count && !hit; k++) {
                int bi = int(hash_entries[bucket * HASH_MAX_PER_CELL + k]);
                if (bi < 0 || bi >= num_bodies) continue;

                // Read only the fields the collision test needs — loading the whole
                // 112-byte Body struct per candidate wastes memory bandwidth in this
                // hot loop (up to 9 cells × HASH_MAX_PER_CELL candidates).
                if (bodies[bi].health <= 0.0) continue;

                // 3D sphere vs body position + height
                float dx = proj.pos_x - bodies[bi].position.x;
                float dz = proj.pos_z - bodies[bi].position.y; // body.position.y == world Z
                float dy = proj.pos_y - bodies[bi].height;
                float dist2 = dx*dx + dz*dz + dy*dy;
                float comb_r = proj.radius + bodies[bi].radius;

                if (dist2 >= comb_r * comb_r) continue;

                // ==============================================================
                // HIT — apply all projectile abilities atomically
                // ==============================================================

                // --- Flat damage ---
                float dmg = proj.damage;
                if ((proj.flags & PROJ_FLAG_IS_HOG) != 0u && proj.source_body >= 0.0) {
                    int src = int(proj.source_body);
                    if (src < num_bodies && bodies[src].health > 0.0) {
                        dmg = bodies[src].health * proj.damage; // health_fraction × source_health
                    }
                }
                if (dmg > 0.0) {
                    atomicAdd(bodies[bi].damage_accum, uint(dmg * DAMAGE_SCALE));
                }

                // --- Contagion ---
                if (proj.contagion != 0u && proj.contagion_dur > 0.0) {
                    atomicOr(bodies[bi].state, proj.contagion);
                    atomicMax(bodies[bi].contagion_timer_u, uint(proj.contagion_dur * CONT_TIME_SCALE));
                    if (proj.dps > 0.0) {
                        atomicMax(bodies[bi].dps_rate_u, uint(proj.dps * DAMAGE_SCALE));
                    }
                }

                // --- Knockback impulse ---
                if (proj.force > 0.0) {
                    atomicAdd(bodies[bi].impulse_x, int(proj.force_dir_x * proj.force * IMPULSE_SCALE));
                    atomicAdd(bodies[bi].impulse_z, int(proj.force_dir_z * proj.force * IMPULSE_SCALE));
                    atomicAdd(bodies[bi].impulse_y, int(proj.force_dir_y * proj.force * IMPULSE_SCALE));

                    // Set flee origin (best-effort direct write — racy under multiple simultaneous hits,
                    // but all competing values are nearby, so any winner gives correct flee direction)
                    bodies[bi].bomb_origin_x = proj.pos_x;
                    bodies[bi].bomb_origin_y = proj.pos_z;
                }

                // --- Teleport ---
                if ((proj.flags & PROJ_FLAG_HAS_TELE) != 0u) {
                    // Use HIT_FRAME as a first-setter guard: only the first projectile to hit
                    // writes the teleport destination.
                    uint prev_flags = atomicOr(bodies[bi].body_flags, BODY_FLAG_TELEPORT | BODY_FLAG_HIT_FRAME);
                    if ((prev_flags & BODY_FLAG_HIT_FRAME) == 0u) {
                        bodies[bi].teleport_x = proj.teleport_x;
                        bodies[bi].teleport_z = proj.teleport_z;
                        bodies[bi].teleport_y = proj.teleport_y;
                    }
                } else {
                    atomicOr(bodies[bi].body_flags, BODY_FLAG_HIT_FRAME);
                }

                // Kill projectile — write back below
                proj.flags &= ~PROJ_FLAG_ALIVE;
                hit = true;
            }
        }
    }

    // Write back updated projectile (position, velocity, lifetime, flags)
    projectiles[id] = proj;
}
