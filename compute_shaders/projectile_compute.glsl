// =============================================================================
// PROJECTILE COMPUTE SHADER
// =============================================================================
// Runs every physics frame AFTER spatial_hash_build and BEFORE physics_compute.
//
// Each invocation handles one projectile:
//   1. Skip inactive slots (PROJ_FLAG_ALIVE clear).
//   2. Integrate 3D position (gravity × the projectile's own gravity_scale + velocity).
//   3. Sweep this frame's path, cut short where it meets the ground, against every body
//      it could touch: grounded bodies from the spatial-hash cells around the path, and
//      the airborne bucket. The body touched EARLIEST along the path is hit.
//   4. On hit: apply flat damage, contagion, knockback impulse, teleport via atomic
//      operations on Body fields, and kill the projectile at the point of contact.
//      Otherwise kill it where it met the ground, or when its lifetime runs out.
//
// Positions are in the squad's simulation space: C# shifts world positions down by the
// squad node's height on the way in and back up on the way out, so projectiles collide
// with bodies where the hogs are drawn.
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
    float gravity_scale;  // 21  × world gravity: 0 flies dead straight, 1 falls like a hog would
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
    float body_radius;   // BodyRadius — how far past a projectile's path a body centre can be
                         // and still be touched, beyond the projectile's own radius
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

// Cap on the cells the sweep visits along each axis. A path plus its reach spans 2–3 cells
// at the speeds used here (80 m/s is 1.3 m a frame); the cap only stops a runaway
// projectile from looping over half the map, which beyond ~480 m/s would start to skip bodies.
const int   MAX_SWEEP_CELLS = 6;

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

// How far along this frame's path — from p0, by d — the projectile first touches body bi, as a
// fraction t of the step in [0, 1]; negative if it does not touch it this frame. A standard
// segment-vs-sphere test on the combined radius, so a fast projectile cannot pass through a
// body between two frames, and among several bodies in reach the one met first can be told
// apart from the one merely found first.
float contact_t(vec3 p0, vec3 d, float proj_radius, int bi) {
    if (bi < 0 || bi >= num_bodies) return -1.0;

    // Read only the fields the test needs — loading the whole Body struct per candidate
    // wastes memory bandwidth in this hot loop.
    if (bodies[bi].health <= 0.0) return -1.0;

    vec3  c  = vec3(bodies[bi].position.x, bodies[bi].height, bodies[bi].position.y); // position.y == world Z
    float r  = proj_radius + bodies[bi].radius;
    vec3  m  = p0 - c;
    float mc = dot(m, m) - r * r;
    if (mc <= 0.0) return 0.0;        // already touching where this step starts

    float a = dot(d, d);
    float b = dot(m, d);
    if (a < 1e-12 || b >= 0.0) return -1.0; // not moving, or moving away from it
    float disc = b * b - a * mc;
    if (disc < 0.0) return -1.0;       // passes it by
    float t = (-b - sqrt(disc)) / a;
    return t <= 1.0 ? t : -1.0;
}

// Applies every ability of the projectile to body bi, which it has just touched, and kills
// the projectile. proj's position must already be the point of contact.
void apply_hit(inout Projectile proj, int bi) {
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
        // An ability without its own knockback direction pushes the way the projectile is
        // travelling when it lands — which for a lobbed shot is down and forward, not the
        // up-and-forward it was launched at.
        vec3 dir = vec3(proj.force_dir_x, proj.force_dir_y, proj.force_dir_z);
        if (dot(dir, dir) < 1e-6) {
            vec3 v = vec3(proj.vel_x, proj.vel_y, proj.vel_z);
            dir = dot(v, v) > 1e-6 ? normalize(v) : vec3(0.0);
        }
        atomicAdd(bodies[bi].impulse_x, int(dir.x * proj.force * IMPULSE_SCALE));
        atomicAdd(bodies[bi].impulse_z, int(dir.z * proj.force * IMPULSE_SCALE));
        atomicAdd(bodies[bi].impulse_y, int(dir.y * proj.force * IMPULSE_SCALE));

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

    proj.flags &= ~PROJ_FLAG_ALIVE;
}

// ---------------------------------------------------------------------------
void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(num_projectiles)) return;

    Projectile proj = projectiles[id];
    if ((proj.flags & PROJ_FLAG_ALIVE) == 0u) return;

    // Decrement lifetime and integrate the 3D position under this projectile's gravity
    // (semi-implicit Euler, matched step for step by ProjectileBase.gd).
    vec3 p0 = vec3(proj.pos_x, proj.pos_y, proj.pos_z);
    proj.lifetime -= delta_time;
    proj.vel_y    -= gravity * proj.gravity_scale * delta_time;
    proj.pos_x    += proj.vel_x * delta_time;
    proj.pos_y    += proj.vel_y * delta_time;
    proj.pos_z    += proj.vel_z * delta_time;
    vec3 d = vec3(proj.pos_x, proj.pos_y, proj.pos_z) - p0;

    // The path this frame ends where it meets the ground, if it does: nothing past that
    // point can be hit.
    float t_end = 1.0;
    bool  grounded = proj.pos_y < y_offset;
    if (grounded) {
        t_end = d.y < 0.0 ? clamp((y_offset - p0.y) / d.y, 0.0, 1.0) : 0.0;
    }
    vec3 p_end = p0 + d * t_end;

    // ------------------------------------------------------------------
    // Grounded bodies — every spatial-hash cell a body touching the path could stand in:
    // the path's XZ bounds grown by the projectile's and a body's radius.
    // ------------------------------------------------------------------
    float reach = proj.radius + body_radius;
    int cx0 = int(floor((min(p0.x, p_end.x) - reach) / HASH_CELL_SIZE));
    int cz0 = int(floor((min(p0.z, p_end.z) - reach) / HASH_CELL_SIZE));
    int cx1 = min(int(floor((max(p0.x, p_end.x) + reach) / HASH_CELL_SIZE)), cx0 + MAX_SWEEP_CELLS - 1);
    int cz1 = min(int(floor((max(p0.z, p_end.z) + reach) / HASH_CELL_SIZE)), cz0 + MAX_SWEEP_CELLS - 1);

    // Keep the body met EARLIEST along the path, not the first one the scan happens to
    // reach. Taking the first found biased every hit toward the lowest cell of the scan
    // window, so a stream of shots carved the crowd along the grid.
    float best_t  = 2.0;
    int   best_bi = -1;

    // x innermost, matching the grid layout (adjacent buckets along x).
    for (int cz = cz0; cz <= cz1; cz++) {
        for (int cx = cx0; cx <= cx1; cx++) {
            uint bucket = spatial_hash(cx, cz);
            uint stored = hash_counts[bucket];
            if ((stored >> HASH_STAMP_SHIFT) != frame_stamp) continue; // not written this frame
            uint count = min(stored & HASH_COUNT_MASK, HASH_MAX_PER_CELL);

            for (uint k = 0u; k < count; k++) {
                int   bi = int(hash_entries[bucket * HASH_MAX_PER_CELL + k]);
                float t  = contact_t(p0, d, proj.radius, bi);
                if (t >= 0.0 && t <= t_end && t < best_t) {
                    best_t  = t;
                    best_bi = bi;
                }
            }
        }
    }

    // ------------------------------------------------------------------
    // Airborne bodies — not in the grid, so without this a hog in the air could not be
    // hit at all. The bucket is a flat list, but it only holds the hogs currently in the
    // air (hundreds at most in practice).
    // ------------------------------------------------------------------
    uint air = hash_counts[HASH_AIR_BUCKET];
    if ((air >> HASH_STAMP_SHIFT) == frame_stamp) {
        uint count = min(air & HASH_COUNT_MASK, HASH_AIR_MAX);
        for (uint k = 0u; k < count; k++) {
            int   bi = int(hash_entries[HASH_AIR_ENTRIES_BASE + k]);
            float t  = contact_t(p0, d, proj.radius, bi);
            if (t >= 0.0 && t <= t_end && t < best_t) {
                best_t  = t;
                best_bi = bi;
            }
        }
    }

    if (best_bi >= 0) {
        // Stop at the point of contact: that is where C# reports the hit, and where the
        // flee origin and a lobbed shot's burst are placed.
        vec3 hit = p0 + d * best_t;
        proj.pos_x = hit.x;
        proj.pos_y = hit.y;
        proj.pos_z = hit.z;
        apply_hit(proj, best_bi);
    } else if (grounded) {
        proj.pos_x = p_end.x;
        proj.pos_y = p_end.y;
        proj.pos_z = p_end.z;
        proj.flags &= ~PROJ_FLAG_ALIVE;
    } else if (proj.lifetime <= 0.0) {
        proj.flags &= ~PROJ_FLAG_ALIVE;
    }

    // Write back updated projectile (position, velocity, lifetime, flags)
    projectiles[id] = proj;
}
