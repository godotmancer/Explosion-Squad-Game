// =============================================================================
// SPATIAL HASH BUILD SHADER  (single-pass, no clear required)
// =============================================================================
// Inserts alive ground bodies into a per-bucket hash table that physics_compute
// reads this same frame.
//
// Dispatch once per frame: ceil(NumBodies / 64) workgroups.
//
// The bucket count word packs two fields into one uint:
//
//   bits 16..31 — frame stamp (physics frame index mod 65536, from C#)
//   bits  0..15 — entry count for this frame
//
// A bucket is "valid this frame" iff its stamp matches push frame_stamp.
// Instead of a separate clear pass, each inserting thread lazily resets any
// bucket it finds with another stamp before claiming its slot.  A CAS
// ensures only one thread resets each bucket; all others detect the already-
// updated stamp and proceed directly to atomicAdd.
//
// The stamp is 16 bits, not a 1-bit parity. A parity cannot tell "written this
// frame" from "written two frames ago", so every cell a hog walked out of came
// back as valid on alternate frames with its old entries — ghost neighbours,
// double-counted ones, and stale counts that pushed real inserts into overflow.
// C# zeroes the bucket words when the stamp wraps, so no stale stamp can ever
// match (see _PhysicsProcess).
//
// Bindings (set 0):
//   0 — BodiesBuffer      (readonly)
//   1 — HashCountsBuffer  (atomic)   uint[TABLE_SIZE + 1]
//   2 — HashEntriesBuffer (write)    uint[TABLE_SIZE * MAX_PER_CELL]
// =============================================================================
#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ⚠ KEEP IN SYNC — 28 floats, identical field order in all four copies:
//   compute_shaders/physics_compute.glsl
//   compute_shaders/spatial_hash_build.glsl        (this file)
//   compute_shaders/projectile_compute.glsl
//   compute_shaders/SquadMultiMeshInstance3D.cs  (struct GpuBody, BODY_STRIDE)
// Adding/reordering/resizing a field in one without the others silently
// corrupts the buffer stride. No GLSL #include exists, so this is manual.
struct Body {
    vec2  position;
    vec2  velocity;
    float height;
    float vertical_velocity;
    float radius;
    float mass;
    float facing_angle;
    float pad7;               // 7   spare (was wander_angle)
    float health;
    float last_hit_time;
    float bomb_origin_x;
    float bomb_origin_y;
    float damaged_time;
    uint  state;
    // projectile effect accumulators (written by projectile_compute, applied/cleared by physics_compute)
    uint  damage_accum;       // 16  flat damage × 256 (atomicAdd)
    uint  contagion_expiry_u; // 17  absolute contagion expiry time × 256 (atomicMax)
    uint  dps_rate_u;         // 18  contagion DPS × 256 (atomicMax)
    uint  body_flags;         // 19  BODY_FLAG_TELEPORT
    float teleport_x;         // 20
    float teleport_z;         // 21
    int   impulse_x;          // 22  knockback impulse X × 1000 (atomicAdd)
    int   impulse_z;          // 23  knockback impulse Z × 1000
    int   impulse_y;          // 24  vertical (Y) knockback impulse × 1000
    float teleport_y;         // 25
    float speed_ema;          // 26  written by physics_compute.glsl only, unused here
    float pad3;               // 27
};

layout(set = 0, binding = 0, std430) restrict readonly  buffer BodiesBuffer      { Body bodies[]; };
// Not `coherent`: every cross-invocation access to the counts is an atomic, and atomics are
// device-coherent regardless of the qualifier. The one plain load (the stamp check in main)
// is safe even if it returns an older value — see the CAS comment there.
layout(set = 0, binding = 1, std430) restrict           buffer HashCountsBuffer  { uint hash_counts[]; };
layout(set = 0, binding = 2, std430) restrict           buffer HashEntriesBuffer { uint hash_entries[]; };

layout(push_constant, std430) uniform Params {
    uint  frame_stamp;   // physics frame index mod 65536 — see the header
    int   num_bodies;
    float y_offset;
    float _pad;
};

// =============================================================================
// SPATIAL HASH CONSTANTS  (must be identical in physics_compute.glsl and projectile_compute.glsl)
// =============================================================================
// Sizing rule: the table is a wrap-around grid (see spatial_hash), so its size decides how
// far apart two cells must be before they share a bucket: HASH_GRID_W × HASH_GRID_H cells,
// 512 m × 256 m at 2 m cells. The arena is ~300 m across, so only cells at opposite z edges
// can ever share one, and the exact distance checks in the queries reject those. Oversizing
// is free at runtime: the stamp scheme in main() means nothing ever iterates the table, so a
// bucket that no body lands in is never touched. The only cost is the fixed allocation
// (counts 128 KB + entries 8 MB), which is why this stays a constant rather than scaling with
// body count — a game that starts with five hogs pays the VRAM but zero per-frame time.
const uint  HASH_TABLE_SIZE   = 32768u; // == HASH_GRID_W * HASH_GRID_H
const uint  HASH_GRID_W       = 256u;   // cells along x before the grid wraps (power of two)
const uint  HASH_GRID_H       = HASH_TABLE_SIZE / HASH_GRID_W; // along z: 128 (power of two)

// Held at 64 rather than trimmed to the ~18 hogs that physically fit in a 2.0u cell at the
// default 0.25 radius: a smaller BodyRadius packs far more per cell, and SpawnHogs/teleport
// drop an entire batch on one point. Per-cell capacity costs only the entries allocation —
// the query loop runs `count` times, not HASH_MAX_PER_CELL times.
const uint  HASH_MAX_PER_CELL = 64u;
const float HASH_CELL_SIZE    = 2.0;
const float GROUND_EPSILON    = 0.01;

// Bucket word layout: frame stamp in the high 16 bits, entry count in the low 16.
const uint  HASH_STAMP_SHIFT  = 16u;
const uint  HASH_COUNT_MASK   = 0xFFFFu;

// Debug: one extra uint allocated past the end of the bucket array, used as a running
// count of bodies dropped by per-cell overflow. spatial_hash() never returns an index
// >= HASH_TABLE_SIZE, so this can never collide with a real bucket, and the
// physics/projectile queries never read it. Sampled from C# behind DebugHashOverflow.
const uint  HASH_OVERFLOW_SLOT = HASH_TABLE_SIZE;

// Map 2-D integer cell coords to a bucket — identical in all three shaders. A wrap-around
// grid rather than a hash: two cells share a bucket only when they are a whole grid apart,
// so no query window ever sees two cells in one bucket and the per-bucket capacity really
// is per cell. (The multiplicative hash this replaced gave a dense crowd 20–50% extra
// neighbour candidates from collisions, and let 2–5 dense cells share one 64-entry bucket.)
// uint() keeps the two's-complement bits, so negative cells wrap as well.
uint spatial_hash(int cx, int cz) {
    return (uint(cx) & (HASH_GRID_W - 1u)) + (uint(cz) & (HASH_GRID_H - 1u)) * HASH_GRID_W;
}

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(num_bodies)) return;

    Body b = bodies[id];
    if (b.health <= 0.0 || b.height > y_offset + GROUND_EPSILON) return;

    int  cx     = int(floor(b.position.x / HASH_CELL_SIZE));
    int  cz     = int(floor(b.position.y / HASH_CELL_SIZE));
    uint bucket = spatial_hash(cx, cz);

    // -------------------------------------------------------------------------
    // Lazy bucket reset — no separate clear pass needed.
    //
    // Read the stored count word.  If its stamp doesn't match this frame's
    // stamp the bucket belongs to a previous frame and must be zeroed.
    //
    // CAS semantics:
    //   Win  → we atomically reset bucket to (frame_stamp<<16 | 0).
    //   Lose → another thread already reset it; the bucket now has the current
    //          stamp and a count of zero (or more, if others already inserted).
    // Either way the bucket is guaranteed to carry the current frame_stamp
    // after this block, so the unconditional atomicAdd below is always safe.
    //
    // The plain load may return an older value than memory holds, and that is
    // fine: within a frame a word only ever moves from an old stamp to the
    // current one, so a stale read either finds the old stamp (and the CAS,
    // expecting that exact old word, fails harmlessly if someone reset it
    // first) or the current one (and memory has it too).
    // -------------------------------------------------------------------------
    uint stored = hash_counts[bucket];
    if ((stored >> HASH_STAMP_SHIFT) != frame_stamp) {
        atomicCompSwap(hash_counts[bucket], stored, frame_stamp << HASH_STAMP_SHIFT);
    }

    // Claim a slot.  The count lives in bits 0..15. It keeps climbing past
    // HASH_MAX_PER_CELL for overflowed inserts, so it would only spill into the
    // stamp at 65,536 inserts into one 2 m cell in a single frame.
    uint slot = atomicAdd(hash_counts[bucket], 1u) & HASH_COUNT_MASK;
    if (slot < HASH_MAX_PER_CELL) {
        hash_entries[bucket * HASH_MAX_PER_CELL + slot] = id;
    } else {
        // Overflow is still a graceful no-op — the body is simply invisible as a
        // neighbour this frame — but it is no longer silent. The symptom (hogs walking
        // through each other in a dense pile) is otherwise very hard to attribute, so
        // count the drops and let C# surface them. Raise HASH_MAX_PER_CELL, or shrink
        // HASH_CELL_SIZE, if this reads non-zero at your body count.
        atomicAdd(hash_counts[HASH_OVERFLOW_SLOT], 1u);
    }
}
