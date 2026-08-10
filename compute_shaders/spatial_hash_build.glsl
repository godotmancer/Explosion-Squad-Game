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
//   bit 31      — frame parity (0 or 1, alternates every frame)
//   bits 0..30  — entry count for this frame
//
// A bucket is "valid this frame" iff its parity bit matches push_parity.
// Instead of a separate clear pass, each inserting thread lazily resets any
// bucket it finds with the wrong parity before claiming its slot.  A CAS
// ensures only one thread resets each bucket; all others detect the already-
// updated parity and proceed directly to atomicAdd.
//
// Bindings (set 0):
//   0 — BodiesBuffer      (readonly)
//   1 — HashCountsBuffer  (coherent, atomic)   uint[TABLE_SIZE]
//   2 — HashEntriesBuffer (write)              uint[TABLE_SIZE * MAX_PER_CELL]
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
    float wander_angle;
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
    uint  body_flags;         // 19  BODY_FLAG_TELEPORT | BODY_FLAG_HIT_FRAME
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
// `coherent` is required for cross-workgroup atomic visibility in Vulkan.
layout(set = 0, binding = 1, std430) coherent           buffer HashCountsBuffer  { uint hash_counts[]; };
layout(set = 0, binding = 2, std430) restrict           buffer HashEntriesBuffer { uint hash_entries[]; };

layout(push_constant, std430) uniform Params {
    uint  frame_parity;  // 0 or 1 — alternates every physics frame
    int   num_bodies;
    float y_offset;
    float _pad;
};

// =============================================================================
// SPATIAL HASH CONSTANTS  (must be identical in physics_compute.glsl)
// =============================================================================
// Sizing rule: HASH_TABLE_SIZE should be roughly 2x the number of occupied cells, and a
// spread-out crowd occupies close to one cell per body. 32768 buckets therefore keeps the
// load factor near 0.6 at ~20k bodies. Oversizing is free at runtime: the parity scheme in
// main() means nothing ever iterates the table, so a bucket that no body hashes to is never
// touched. The only cost is the fixed allocation (counts 128 KB + entries 8 MB), which is
// why this stays a constant rather than scaling with body count — a game that starts with
// five hogs pays the VRAM but zero per-frame time.
const uint  HASH_TABLE_SIZE   = 32768u; // MUST be a power of two — spatial_hash masks with (size - 1)

// Held at 64 rather than trimmed to the ~18 hogs that physically fit in a 2.0u cell at the
// default 0.25 radius: a smaller BodyRadius packs far more per cell, and SpawnHogs/teleport
// drop an entire batch on one point. Per-cell capacity costs only the entries allocation —
// the query loop runs `count` times, not HASH_MAX_PER_CELL times.
const uint  HASH_MAX_PER_CELL = 64u;
const float HASH_CELL_SIZE    = 2.0;
const float GROUND_EPSILON    = 0.01;

// Debug: one extra uint allocated past the end of the bucket array, used as a running
// count of bodies dropped by per-cell overflow. spatial_hash() masks with
// (HASH_TABLE_SIZE - 1), so this index can never collide with a real bucket, and the
// physics/projectile queries never read it. Sampled from C# behind DebugHashOverflow.
const uint  HASH_OVERFLOW_SLOT = HASH_TABLE_SIZE;

uint spatial_hash(int cx, int cz) {
    uint hx = uint(cx) * 2654435761u;
    uint hz = uint(cz) * 2246822519u;
    return (hx ^ hz) & (HASH_TABLE_SIZE - 1u);
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
    // Read the stored count word.  If the parity bit doesn't match this frame's
    // parity the bucket belongs to a previous frame and must be zeroed.
    //
    // CAS semantics:
    //   Win  → we atomically reset bucket to (frame_parity<<31 | 0).
    //   Lose → another thread already reset it; the bucket now has the correct
    //          parity and a count of zero (or more, if others already inserted).
    // Either way the bucket is guaranteed to carry the current frame_parity
    // after this block, so the unconditional atomicAdd below is always safe.
    // -------------------------------------------------------------------------
    uint stored = hash_counts[bucket];
    if ((stored >> 31u) != frame_parity) {
        atomicCompSwap(hash_counts[bucket], stored, frame_parity << 31u);
    }

    // Claim a slot.  The count lives in bits 0..30; adding 1 cannot spill into
    // bit 31 because HASH_MAX_PER_CELL (64) is far below 2^31.
    uint slot = atomicAdd(hash_counts[bucket], 1u) & 0x7FFFFFFFu;
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
