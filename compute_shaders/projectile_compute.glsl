// =============================================================================
// PROJECTILE COMPUTE SHADER
// =============================================================================
// Runs every physics frame AFTER spatial_hash_build and BEFORE physics_compute.
//
// Each invocation handles one projectile:
//   1. Skip inactive slots (PROJ_FLAG_ALIVE clear).
//   2. Integrate 3D position (gravity + velocity).
//   3. Expire if lifetime ≤ 0 or projectile hits the ground.
//   4. Query the spatial hash (3×3 XZ neighbourhood) for grounded candidate bodies,
//      then, if nothing was hit, the airborne bucket for bodies in the air.
//   5. Sphere-vs-sphere 3D collision check.
//   6. On hit: apply flat damage, contagion, knockback impulse, teleport via
//      atomic operations on Body fields. Kill the projectile.
//
// Special case — PROJ_FLAG_IS_HOG:
//   The projectile was thrown by a live hog (source_body ≥ 0).
//   Actual damage = proj.damage (treated as health fraction 0-1) × source health.
//
// Bindings (set 0):
//   0 — BodiesBuffer      (read/write — atomics for damage/impulse/etc.)
//   1 — ProjectilesBuffer (read/write — each invocation owns one slot)
//   2 — HashCountsBuffer  (readonly)
//   3 — HashEntriesBuffer (readonly)
// =============================================================================
#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ---------------------------------------------------------------------------
// ⚠ KEEP IN SYNC — 30 floats, identical field order in all four copies:
//   compute_shaders/physics_compute.glsl
//   compute_shaders/spatial_hash_build.glsl
//   compute_shaders/projectile_compute.glsl        (this file)
//   compute_shaders/SquadMultiMeshInstance3D.cs  (struct GpuBody, BODY_STRIDE)
// Adding/reordering/resizing a field in one without the others silently
// corrupts the buffer stride. No GLSL #include exists, so this is manual.
// ---------------------------------------------------------------------------
struct Body {
    vec2  position;              //  0
    vec2  velocity;              //  2
    float height;                //  4
    float vertical_velocity;     //  5
    float radius;                //  6
    float mass;                  //  7
    float facing_angle;          //  8
    float health;                //  9
    float last_hit_time;         // 10
    float bomb_origin_x;         // 11
    float bomb_origin_y;         // 12
    float damaged_time;          // 13
    uint  damage_accum;          // 14  flat damage × 256 (atomicAdd)
    uint  body_flags;            // 15  BODY_FLAG_TELEPORT
    uint  contagion_expiry_u[3]; // 16  per contagion type: absolute expiry × 256 (atomicMax only)
    uint  contagion_dps_u[3];    // 19  per contagion type: DPS × 256
    float teleport_x;            // 22
    float teleport_z;            // 23
    float teleport_y;            // 24  teleport spawn height
    int   impulse_x;             // 25  knockback impulse × 1000 (atomicAdd)
    int   impulse_z;             // 26
    int   impulse_y;             // 27
    float speed_ema;             // 28  written by physics_compute.glsl only, unused here
    float pad29;                 // 29
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
// Neither body nor projectile buffer is `coherent` — same reasoning as physics_compute.glsl:
// cross-invocation writes to bodies are atomics (device-scope regardless), and each
// projectile slot is only ever touched by its own invocation.
layout(set = 0, binding = 0, std430) restrict buffer          BodiesBuffer      { Body       bodies[];      };
layout(set = 0, binding = 1, std430) restrict buffer          ProjectilesBuffer  { Projectile projectiles[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer HashCountsBuffer  { uint       hash_counts[]; };
layout(set = 0, binding = 3, std430) restrict readonly buffer HashEntriesBuffer { uint       hash_entries[];};

layout(push_constant, std430) uniform Params {
    float delta_time;
    int   num_projectiles;
    int   num_bodies;
    float gravity;
    float y_offset;
    uint  frame_stamp;   // frame index mod 65536, as given to spatial_hash_build.glsl
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

// Contagion (must match physics_compute.glsl). proj.contagion carries state bits; type t's
// bit is STATE_ON_FIRE << t, and t indexes Body.contagion_expiry_u[] / contagion_dps_u[].
const uint STATE_ON_FIRE = 256u;
const uint CONT_TYPES    = 3u;   // fire, poison, drunk

// ---------------------------------------------------------------------------
// Fixed-point scales (must match physics_compute.glsl)
// ---------------------------------------------------------------------------
const float DAMAGE_SCALE    = 256.0;
const float CONT_TIME_SCALE = 256.0;
const float IMPULSE_SCALE   = 1000.0;

// ---------------------------------------------------------------------------
// Spatial hash constants (must match spatial_hash_build.glsl)
// ---------------------------------------------------------------------------
const uint  HASH_TABLE_SIZE   = 32768u; // == HASH_GRID_W * HASH_GRID_H; see the sizing note in
                                        // spatial_hash_build.glsl. Oversizing is free at
                                        // runtime, so this does not scale with body count.
const uint  HASH_GRID_W       = 256u;   // cells along x before the grid wraps (power of two)
const uint  HASH_GRID_H       = HASH_TABLE_SIZE / HASH_GRID_W; // along z: 128 (power of two)
const uint  HASH_MAX_PER_CELL = 64u;
const float HASH_CELL_SIZE    = 2.0;
// Bucket word layout: frame stamp in the high 16 bits, entry count in the low 16.
const uint  HASH_STAMP_SHIFT  = 16u;
const uint  HASH_COUNT_MASK   = 0xFFFFu;
// Airborne bodies: one flat bucket after the grid — see spatial_hash_build.glsl.
const uint  HASH_AIR_BUCKET       = HASH_TABLE_SIZE;
const uint  HASH_AIR_MAX          = 4096u;
const uint  HASH_AIR_ENTRIES_BASE = HASH_TABLE_SIZE * HASH_MAX_PER_CELL;

// Wrap-around grid, identical in all three shaders — see spatial_hash_build.glsl.
uint spatial_hash(int cx, int cz) {
    return (uint(cx) & (HASH_GRID_W - 1u)) + (uint(cz) & (HASH_GRID_H - 1u)) * HASH_GRID_W;
}

// ⚠ KEEP IN SYNC with the copy in physics_compute.glsl, which explains the reasoning.
// Give body i contagion type t until new_expiry at dps_u; the invocation that revives a
// lapsed expiry replaces the stale DPS, everyone else only raises it.
void infect(int i, uint t, uint new_expiry, uint dps_u, uint now_u) {
    uint prev_expiry = atomicMax(bodies[i].contagion_expiry_u[t], new_expiry);
    if (prev_expiry <= now_u && new_expiry > prev_expiry)
        atomicExchange(bodies[i].contagion_dps_u[t], dps_u);
    else
        atomicMax(bodies[i].contagion_dps_u[t], dps_u);
}

// Tests body bi against the projectile and, on contact, applies every ability to it and
// kills the projectile. Returns whether it hit.
bool try_hit(inout Projectile proj, int bi) {
    if (bi < 0 || bi >= num_bodies) return false;

    // Read only the fields the collision test needs — loading the whole Body struct per
    // candidate wastes memory bandwidth in this hot loop (up to 9 cells ×
    // HASH_MAX_PER_CELL candidates).
    if (bodies[bi].health <= 0.0) return false;

    // 3D sphere vs body position + height
    float dx = proj.pos_x - bodies[bi].position.x;
    float dz = proj.pos_z - bodies[bi].position.y; // body.position.y == world Z
    float dy = proj.pos_y - bodies[bi].height;
    float dist2 = dx*dx + dz*dz + dy*dy;
    float comb_r = proj.radius + bodies[bi].radius;

    if (dist2 >= comb_r * comb_r) return false;

    // ==================================================================
    // HIT — apply all projectile abilities atomically
    // ==================================================================

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
    // Every type the projectile carries gets this duration and DPS, on its own clock.
    // Absolute expiry, not a duration — physics_compute compares it against `time`
    // instead of counting it down.
    if (proj.contagion != 0u && proj.contagion_dur > 0.0) {
        uint now_u      = uint(time * CONT_TIME_SCALE);
        uint new_expiry = uint((time + proj.contagion_dur) * CONT_TIME_SCALE);
        uint dps_u      = uint(max(proj.dps, 0.0) * DAMAGE_SCALE);
        for (uint t = 0u; t < CONT_TYPES; t++) {
            if ((proj.contagion & (STATE_ON_FIRE << t)) != 0u)
                infect(bi, t, new_expiry, dps_u, now_u);
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
        // First-setter guard on the TELEPORT bit itself: only the first teleporting
        // projectile to hit writes the destination. It must not key off a generic
        // "hit this frame" bit — an ordinary hit landing first would then make the
        // teleport skip its write, and physics would move the hog to whatever
        // destination was left over (the world origin, for a hog never teleported).
        uint prev_flags = atomicOr(bodies[bi].body_flags, BODY_FLAG_TELEPORT);
        if ((prev_flags & BODY_FLAG_TELEPORT) == 0u) {
            bodies[bi].teleport_x = proj.teleport_x;
            bodies[bi].teleport_z = proj.teleport_z;
            bodies[bi].teleport_y = proj.teleport_y;
        }
    }

    // Kill projectile — main() writes it back
    proj.flags &= ~PROJ_FLAG_ALIVE;
    return true;
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
    // Spatial hash collision query — 3×3 XZ neighbourhood (grounded bodies)
    // ------------------------------------------------------------------
    int cx = int(floor(proj.pos_x / HASH_CELL_SIZE));
    int cz = int(floor(proj.pos_z / HASH_CELL_SIZE));

    bool hit = false;

    // x innermost, matching the grid layout (adjacent buckets along x).
    for (int dcz = -1; dcz <= 1 && !hit; dcz++) {
        for (int dcx = -1; dcx <= 1 && !hit; dcx++) {

            uint bucket = spatial_hash(cx + dcx, cz + dcz);
            uint stored  = hash_counts[bucket];
            if ((stored >> HASH_STAMP_SHIFT) != frame_stamp) continue; // not written this frame
            uint count = min(stored & HASH_COUNT_MASK, HASH_MAX_PER_CELL);

            for (uint k = 0u; k < count && !hit; k++) {
                hit = try_hit(proj, int(hash_entries[bucket * HASH_MAX_PER_CELL + k]));
            }
        }
    }

    // ------------------------------------------------------------------
    // Airborne bodies — not in the grid, so without this a hog in the air could not be
    // hit at all. The bucket is a flat list, but it only holds the hogs currently in the
    // air (hundreds at most in practice), and it is only scanned when nothing on the
    // ground was hit.
    // ------------------------------------------------------------------
    if (!hit) {
        uint stored = hash_counts[HASH_AIR_BUCKET];
        if ((stored >> HASH_STAMP_SHIFT) == frame_stamp) {
            uint count = min(stored & HASH_COUNT_MASK, HASH_AIR_MAX);
            for (uint k = 0u; k < count && !hit; k++) {
                hit = try_hit(proj, int(hash_entries[HASH_AIR_ENTRIES_BASE + k]));
            }
        }
    }

    // Write back updated projectile (position, velocity, lifetime, flags)
    projectiles[id] = proj;
}
