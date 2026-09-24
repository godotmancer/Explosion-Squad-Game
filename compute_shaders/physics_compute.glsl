#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

// ⚠ KEEP IN SYNC — 30 floats, identical field order in all four copies:
//   compute_shaders/physics_compute.glsl        (this file)
//   compute_shaders/spatial_hash_build.glsl
//   compute_shaders/projectile_compute.glsl
//   compute_shaders/SquadMultiMeshInstance3D.cs  (struct GpuBody, BODY_STRIDE)
// Adding/reordering/resizing a field in one without the others silently
// corrupts the buffer stride. No GLSL #include exists, so this is manual.
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
    float damaged_time;          // 13  wall-clock time after which DAMAGED bit clears
    // projectile effect accumulators (written by projectile_compute, applied/cleared here)
    uint  damage_accum;          // 14  flat damage × 256 (atomicAdd)
    uint  body_flags;            // 15  BODY_FLAG_TELEPORT
    // One entry per contagion type, indexed by CONT_FIRE / CONT_POISON / CONT_DRUNK, so each
    // type runs on its own clock. Both are written only through infect(), by projectile hits
    // and by neighbour threads spreading contagion during this dispatch.
    uint  contagion_expiry_u[3]; // 16  ABSOLUTE time at which that type lapses × 256. Only
                                 //     ever raised (atomicMax), so "infected" is a comparison
                                 //     against `time`, not a countdown concurrent spreaders
                                 //     could lose.
    uint  contagion_dps_u[3];    // 19  that type's damage per second × 256
    float teleport_x;            // 22
    float teleport_z;            // 23
    float teleport_y;            // 24  teleport spawn height (world Y); 0 = near ground
    int   impulse_x;             // 25  knockback impulse X × 1000 (atomicAdd)
    int   impulse_z;             // 26  knockback impulse Z × 1000
    int   impulse_y;             // 27  vertical (Y) knockback × 1000
    float speed_ema;             // 28  exponentially-smoothed speed, drives locomotion-state
                                 //     classification only (see STATE_EASE_RATE below) — written
                                 //     here, unused by the other three copies of this struct
    float pad29;                 // 29  keeps the size a multiple of 8 bytes (vec2 alignment),
                                 //     so C#'s packed GpuBody and std430 agree on the stride
};

struct Obstacle {
    vec2 center;
    vec2 half_extents;
    vec2 local_x_axis;
    vec2 velocity;
    float type;         // < 0.5 circle, otherwise OBB (OBS_TYPE_* in C#)
    float margin;
    float angular_vel;
    float pad;
};

struct Bomb {
    vec2 pos;
    float force;
    float radius;
    float damage;
    float causes_fear;  // 1.0 for a real bomb; 0.0 for the death-fear nudge C# adds when a hog dies
    float _pad2;
    float _pad3;
};

// Deliberately NOT `coherent`. Atomics are device-scope with or without it, and every plain
// read of another body (the neighbour scan) already accepts that body's value from either
// side of its own update this frame. What the qualifier did cost: on Metal it becomes
// `coherent device` (MSL 3.2+) or `volatile device` (older), so every neighbour load skips
// the cache and cannot be trimmed to the fields actually used. See AGENTS.md §14.
layout(set = 0, binding = 0, std430) restrict buffer          BodiesBuffer    { Body     bodies[];    };
layout(set = 0, binding = 1, std430) restrict readonly buffer ObstaclesBuffer { Obstacle obstacles[]; };
layout(set = 0, binding = 2, std430) restrict readonly buffer BombsBuffer     { Bomb     bombs[];     };
// Spatial hash table written by spatial_hash_build.glsl each frame before this shader runs.
layout(set = 0, binding = 3, std430) restrict readonly buffer HashCountsBuffer  { uint hash_counts[];  };
layout(set = 0, binding = 4, std430) restrict readonly buffer HashEntriesBuffer { uint hash_entries[]; };
// MultiMesh instance data, written at the tail of main(). This used to be a separate
// transform_compute dispatch, which re-read all 112 bytes of every Body that this shader
// already had in registers. Declared as vec4 so the 20 floats per instance go out as five
// coalesced 16-byte stores instead of 20 scalar ones (20 floats == 80 bytes == 5 * vec4,
// so every instance stays 16-byte aligned).
layout(set = 0, binding = 5, std430) restrict writeonly buffer InstanceBuffer { vec4 instances[]; };

layout(push_constant, std430) uniform Params {
    float delta_time;
    int   num_bodies;
    vec2  target;
    float arrive_radius;
    float rotation_speed;
    float time;
    int   num_obstacles;
    int   num_bombs;
    float bomb_fear_duration;
    float gravity;
    float y_offset;
    uint  frame_stamp;   // frame index mod 65536, as given to spatial_hash_build.glsl — buckets
                         // carrying any other stamp are stale
    float hog_gravity_scale;
    // XZ bounds of the drawn hog mesh in its own frame (x = right, y = forward), from the
    // MultiMesh's mesh AABB. The obstacle hard contact keeps this box out of walls; the
    // BodyRadius circle used between hogs is much smaller than what is drawn.
    vec2  footprint_min;
    vec2  footprint_max;
};

// =============================================================================
// MATHEMATICAL CONSTANTS
// =============================================================================
const float PI  = 3.14159265;
const float TAU = 6.28318530;

// =============================================================================
// BOIDS: FLOCKING RADII
// =============================================================================
const float SEPARATION_PADDING = 3.0; // Personal-space bubble: multiplier on combined bounding radii
const float ALIGNMENT_RADIUS   = 2.5; // Detect neighbors to match their average velocity
const float COHESION_RADIUS    = 5.0; // Detect neighbors to steer toward their center of mass

// =============================================================================
// SPEED & FORCE LIMITS
// =============================================================================
const float MAX_WALK_SPEED = 5.0;  // Standard cruising speed toward the target
const float MAX_RUN_SPEED  = 34.0; // Sprint speed when far from target and the crowd
const float MAX_FLEE_SPEED = 20.0; // Maximum speed when panicked by a bomb
const float MAX_FORCE      = 10.0; // Maximum steering force per frame (higher = more agile)

// =============================================================================
// BOIDS: BEHAVIOR WEIGHTS
// =============================================================================
const float SEPARATION_WEIGHT = 33.5;  // Avoid collisions with nearby peers (highest, prevents clumping)
const float ALIGNMENT_WEIGHT  = 0.15; // Match the direction of the local crowd
const float COHESION_WEIGHT   = 0.15; // Group up with the local crowd
const float ARRIVE_WEIGHT     = 1.0;  // Navigate directly toward the global target point
                                      // Was 10.0 but lower value seems more stable

// =============================================================================
// IDLE / WALKING FOOTSTEP SWAY
// =============================================================================
const float WANDER_STRENGTH      = 1.02; // Amplitude of sinusoidal directional sway (footstep simulation)
const float STRIDE_FREQ          = 3.5;  // Sway frequency in Hz (cycles per second)
const float WANDER_SPEED_BLEND   = 0.3;  // Fraction of max_speed below which wander sway fades out
const float WANDER_ARRIVE_BLEND  = 0.4;  // Fraction of arrive_radius inside which wander fades to zero
const float WANDER_HARMONIC_FREQ = 2.0;  // Second harmonic frequency multiplier (subtle rhythm variation)
const float WANDER_HARMONIC_AMP  = 0.15; // Second harmonic amplitude weight
const float WANDER_HARMONIC_PHASE = 1.7; // Phase offset for second harmonic (prevents perfect overlap)

// =============================================================================
// BOMB FLEEING MECHANICS
// =============================================================================
const float FLEE_WEIGHT              = 25.0; // Dominant steering priority when panicked
const float FLEE_MIN_RADIUS          = 28.0;  // Distance from bomb origin below which active fleeing stops
const float FEAR_CONTAGION_DECAY     = 0.65; // Fraction of fear retained when passed to a neighbor
const float FEAR_CONTAGION_RADIUS    = 20.0; // Maximum proximity required to spread panic to a neighbor
const float FEAR_CONTAGION_WINDOW    = 0.8;  // Fraction of bomb_fear_duration a neighbor must be within to spread panic
const float FEAR_SPREAD_THRESHOLD    = 0.02; // Minimum fear advantage before overwriting this body's fear state

// =============================================================================
// OBSTACLE AVOIDANCE (SOFT / STEERING)
// =============================================================================
const float OBSTACLE_DETECT_RADIUS  = 0.3;  // Surface distance at which soft steering kicks in
const float OBSTACLE_WEIGHT         = 14.0;  // Priority of steering away from terrain/walls
const float OBSTACLE_TANGENT_BLEND  = 0.7;  // Weight toward tangent (skirting) vs normal (push-away)
const float OBSTACLE_HALF_DETECT    = 0.5;  // Fraction of detect radius where full push-away begins
const uint  OBSTACLE_HASH_SEED      = 7u;   // Bit-mixing seed for random tangent side disambiguation

// =============================================================================
// OBSTACLE AVOIDANCE (HARD / POSITION-BASED DYNAMICS)
// =============================================================================
const int   PBD_ITERATIONS        = 1;    // Hard constraint solver iterations per frame
const float PBD_VEL_LOOKAHEAD     = 3.0;  // dt multiplier: expands contact radius by surface speed
const float PBD_CORRECTION_SCALE  = 10.0; // Positional correction strength scalar (scales with delta_time)
const float PBD_CORRECTION_MAX    = 2.0;  // Cap on correction: limits to this multiple of body radius

// =============================================================================
// SETTLING / STOPPING MECHANICS
// =============================================================================
const float VELOCITY_EPSILON         = 0.15; // Speed below which body is considered completely stopped
const float SETTLE_RADIUS            = 0.65; // Fraction of arrive_radius where braking and damping kicks in
const float SETTLE_INNER_FRACTION    = 0.2;  // Inner fraction of settle zone where full stop begins
const float OVERLAP_DEAD_BAND        = 0.18; // Minimum penetration depth before hard overlap correction applies
const float OVERLAP_CORRECTION_FACTOR = 0.6; // Fraction of penetration resolved per neighbor step

// =============================================================================
// CATCH-UP SPRINT (DYNAMIC SPEED OVERRIDE)
// =============================================================================
const float SPRINT_DIST_MULT   = 1.5;  // arrive_radius multiplier: lower distance bound to begin sprinting
const float SPRINT_DIST_RANGE  = 20.0; // Gradient range (world units) from threshold to full sprint speed
const float CROWD_CLEAR_MULT   = 3.0;  // Personal radius multiplier: inner spacing bound for sprinting
const float CROWD_CLEAR_RANGE  = 10.0; // Gradient range beyond crowd threshold to allow full sprint

// =============================================================================
// DAMPING COEFFICIENTS
// =============================================================================
const float DAMPING_FAR    = 0.99;  // Light damping during normal travel (far from target)
const float DAMPING_NEAR   = 0.90;  // Stronger damping near target (suppresses oscillation)
const float DAMPING_SETTLE = 0.75;  // Aggressive damping when stopping (snap-to-rest)
const float DAMPING_FEAR   = 0.995; // Near-zero damping when panicked (preserve flee momentum)
const float AIR_FRICTION   = 0.995; // Velocity decay while airborne (low-drag simulation)

// =============================================================================
// FACING / ROTATION
// =============================================================================
const float SPEED_TRUST_LOW  = 0.05; // Below this fraction of max_speed, ignore velocity for facing
const float SPEED_TRUST_HIGH = 0.30; // Above this fraction of max_speed, fully trust velocity direction
const float ROT_SPEED_BASE   = 2.0;  // Baseline rotation rate during settling (prevents spin-in-place)
const float ROT_SPEED_BIAS   = 0.30; // Minimum rotation speed fraction at low velocity
const float ROT_SPEED_SCALE  = 0.70; // Additional rotation speed fraction gained at full velocity
const float ROT_SPEED_HALF   = 0.50; // Velocity fraction of max_speed at which rotation is half-scaled
const float ROT_DEADBAND_MOVING = 0.01; // Angle snap threshold during movement (ignores micro-jitter)
const float ROT_DEADBAND_SETTLE = 0.05; // Larger snap threshold when nearly stopped

// =============================================================================
// STEER FORCE MODIFIERS
// =============================================================================
const float STEER_STRAGGLER_BOOST      = 3.0; // Extra arrive-force multiplier for isolated bodies
const float STEER_SEP_PROXIMITY_BOOST  = 0.06; // Separation weight boost deep inside crowd (reduced: was 1.5, high values amplify jitter at target)
const float STEER_COH_PROXIMITY_DECAY  = 0.8; // Cohesion weight reduction near crowd center

// =============================================================================
// NEAR-ZERO GUARDS
// =============================================================================
const float NEAR_ZERO      = 0.001; // General guard against division by near-zero lengths
const float NEAR_ZERO_DIST = 0.01;  // Near-zero guard for position offsets
const float GROUND_EPSILON = 0.01;  // Height threshold above y_offset to count as airborne

// Contagion behaviour
const float FIRE_SPREAD_RADIUS    = 3.0;
const float FIRE_SPREAD_PROB      = 0.012; // per-frame, per-neighbor probability
const float FIRE_SPREAD_MAX_DUR   = 3.0;   // seconds: cap on the duration handed to a neighbor
const float POISON_SPREAD_RADIUS  = 2.5;
const float POISON_SPREAD_PROB    = 0.004;
const float POISON_SPREAD_MAX_DUR = 5.0;

// Fraction of our REMAINING contagion time passed on to a neighbour. Below 1.0 every hop is
// weaker than the one that infected it, so an outbreak decays geometrically along the chain
// and burns itself out instead of saturating every connected hog and then all clearing at
// once. Mirrors FEAR_CONTAGION_DECAY, which does the same job for panic.
const float CONTAGION_SPREAD_DECAY = 0.6;

// Once the duration we could pass on falls below this, stop spreading altogether. Without a
// floor the geometric decay would trail off into a long tail of imperceptible infections.
const float CONTAGION_MIN_SPREAD_DUR = 0.35;
const float DRUNK_JITTER_STR      = 10.5;  // velocity noise amplitude

// A drunk hog unsettles the hogs immediately around it, and that unease eases off as the
// drunkenness wears away. This feeds the SAME fear pipeline the bomb panic uses (see the
// neighbour scan in main), so a spooked hog gets the usual lingering fear, flee steering and
// IN_FEAR / FLEEING state rather than a parallel one-off effect.
const float DRUNK_FEAR_RADIUS   = 2.0;  // "close neighbours" — deliberately inside the 3×3 scan's
                                        // guaranteed coverage (HASH_CELL_SIZE), so the effect never
                                        // silently depends on whether the wide fear ring is scanned.
const float DRUNK_FEAR_STRENGTH = 0.4;  // peak fear radiated, on the same 0-1 scale where 1.0 is a
                                        // point-blank bomb. Above ~0.31 a spooked neighbour lands
                                        // inside FEAR_CONTAGION_WINDOW itself and relays the panic
                                        // onward, so it ripples a hop or two past DRUNK_FEAR_RADIUS
                                        // before the per-hop decay puts it outside that window;
                                        // below ~0.31 the fear stops at the neighbours the drunk
                                        // hog can reach directly.
const float DRUNK_FEAR_FADE     = 1.0; // seconds of remaining drunkenness over which the radiated
                                        // fear ramps down to nothing. Shorter than the 50s
                                        // contagion_duration on DrunkProjectile.tres, so most of a
                                        // drunk hog's life radiates full-strength fear and only the
                                        // tail winds down.

// The most fear a neighbour can hand over: a bomb-panicked hog relays at most full fear (1.0),
// a drunk one DRUNK_FEAR_STRENGTH, and either is scaled by FEAR_CONTAGION_DECAY. A hog whose
// own fear is already at least this minus FEAR_SPREAD_THRESHOLD cannot be made more afraid by
// the neighbour scan, so it skips the fear checks and the wide ring (see can_gain_fear in main).
const float FEAR_MAX_SPREAD = FEAR_CONTAGION_DECAY * max(1.0, DRUNK_FEAR_STRENGTH);

// Thresholds used when computing state bits — kept here so C# only needs to
// read the pre-computed state, not re-derive it from raw values.
const float DAMAGED_DISPLAY_DURATION = 1.6;  // seconds the DAMAGED bit stays set after a hit
const float FEAR_THRESHOLD           = 0.01;  // minimum fear_factor to enter FLEEING / IN_FEAR
                                             // Lower = the more fear lingers
const float SPRINT_SPEED_THRESHOLD   = 6.0;  // speed above MAX_WALK_SPEED that counts as SPRINTING

// Exponential ease rate (1/seconds) for speed_ema — the smoothed speed signal that drives
// locomotion-state classification (IDLE/WALKING/SPRINTING/FLEEING/IN_FEAR) below. Raw velocity
// hovers right on these thresholds under boid/damping forces; classifying off the eased value
// instead of the instantaneous one turns a hard per-frame snap into a smooth curve, so the
// reported state (and anything reading it — labels, animation) settles instead of flickering.
const float STATE_EASE_RATE          = 0.9;


// =============================================================================
// BEHAVIOUR STATE FLAGS  (bitwise — multiple bits may be set simultaneously)
// =============================================================================
const uint STATE_IDLE      = 1u;    // bit 0
const uint STATE_WALKING   = 2u;    // bit 1
const uint STATE_SPRINTING = 4u;    // bit 2
const uint STATE_DAMAGED   = 8u;    // bit 3
const uint STATE_FLEEING   = 16u;   // bit 4
const uint STATE_IN_FEAR   = 32u;   // bit 5
const uint STATE_AIRBORNE  = 64u;   // bit 6
const uint STATE_DEAD      = 128u;  // bit 7
// Contagion state bits, derived each frame from which contagion types are live — type t's
// bit is STATE_ON_FIRE << t
const uint STATE_ON_FIRE   = 256u;  // bit 8
const uint STATE_POISONED  = 512u;  // bit 9
const uint STATE_DRUNK     = 1024u; // bit 10

// Contagion types — indices into Body.contagion_expiry_u[] / contagion_dps_u[]
const uint CONT_FIRE   = 0u;
const uint CONT_POISON = 1u;
const uint CONT_DRUNK  = 2u;
const uint CONT_TYPES  = 3u;

// Body flag bits (body_flags field)
const uint BODY_FLAG_TELEPORT  = 1u;

// Fixed-point scale factors
const float DAMAGE_SCALE    = 256.0;
const float CONT_TIME_SCALE = 256.0;
const float IMPULSE_SCALE   = 1000.0;

// =============================================================================
// MULTIMESH INSTANCE LAYOUT  (written at the tail of main)
// =============================================================================
// 20 floats per instance: 12 transform + 4 color + 4 custom, addressed as 5 vec4 rows.
const uint INSTANCE_VEC4S = 5u;
const uint INST_ROW_CUSTOM = 4u; // (speed, health, state bits, time)

// Seconds of remaining contagion over which the tint eases back to white. Because a spread
// hop only inherits a fraction of its infector's remaining time, hops far from the origin
// start out already inside this window and so render faint — the outbreak visibly weakens
// as it travels instead of every infected hog looking equally lit.
const float CONTAGION_FADE_TIME = 1.5;

// Contagion tint: a display-range hue and an HDR gain applied to it. The gains are above 1.0
// on purpose. shaders/hog_contagion.gdshader renormalises the in-range part of an instance
// colour into ALBEDO and turns everything above 1.0 into EMISSION, so the gain — not the hue —
// is what makes an infected hog bloom through the WorldEnvironment's HDR glow instead of just
// reading as a brighter albedo that dies in shadow. Keep every hue channel <= 1.0 so the gain
// alone controls how hot a contagion looks; a gain of 1.0 would emit nothing at all.
const vec3  FIRE_TINT   = vec3(1.0, 0.08, 0.0);
const float FIRE_GLOW   = 2.1;
const vec3  POISON_TINT = vec3(0.18, 1.0, 0.12);
const float POISON_GLOW = 2.1;
const vec3  DRUNK_TINT  = vec3(0.62, 0.06, 1.0);
const float DRUNK_GLOW  = 2.3;


// =============================================================================
// UTILITY FUNCTIONS
// =============================================================================

// Clamp a vector's length to max_len without changing its direction
vec2 limit_vec(vec2 v, float max_len) {
    float len = length(v);
    return (len > max_len && len > NEAR_ZERO) ? (v / len) * max_len : v;
}

// Return the shortest signed angle from from_angle to to_angle in [-PI, PI]
float shortest_angle_diff(float from_angle, float to_angle) {
    return mod(to_angle - from_angle + PI, TAU) - PI;
}

// Low-quality but GPU-friendly integer hash, returns [0, 1)
float hash(uint n) {
    n = (n << 13u) ^ n;
    n = n * (n * n * 15731u + 789221u) + 1376312589u;
    return float(n & 0x7fffffffu) / float(0x7fffffff);
}

// Rotate a 2D vector by angle (counter-clockwise)
vec2 rotate2d(vec2 v, float angle) {
    float c = cos(angle), s = sin(angle);
    return vec2(v.x * c - v.y * s, v.x * s + v.y * c);
}

// Falls smoothly from 1 at `lo` to 0 at `hi` (lo < hi). The reversed-edge form
// smoothstep(hi, lo, x) says the same thing, but GLSL and MSL both leave
// edge0 >= edge1 undefined, so this is the spec-safe spelling of it.
float smooth_fall(float lo, float hi, float x) {
    return 1.0 - smoothstep(lo, hi, x);
}

// How far the drawn hog reaches from its centre in world direction `dir` (unit, XZ): the
// support distance of its footprint box, given the hog's right and forward axes in world XZ.
// Exact for a flat surface, whatever way the hog is turned.
float footprint_reach(vec2 dir, vec2 right, vec2 fwd) {
    float lx = dot(dir, right);
    float lz = dot(dir, fwd);
    return (lx >= 0.0 ? footprint_max.x : footprint_min.x) * lx
         + (lz >= 0.0 ? footprint_max.y : footprint_min.y) * lz;
}

// =============================================================================
// SPATIAL HASH  (matches spatial_hash_build.glsl — keep constants in sync)
// =============================================================================
const uint  HASH_TABLE_SIZE   = 32768u; // == HASH_GRID_W * HASH_GRID_H; see the sizing note in
                                        // spatial_hash_build.glsl. Oversizing is free at
                                        // runtime, so this does not scale with body count.
const uint  HASH_GRID_W       = 256u;   // cells along x before the grid wraps (power of two)
const uint  HASH_GRID_H       = HASH_TABLE_SIZE / HASH_GRID_W; // along z: 128 (power of two)
const uint  HASH_MAX_PER_CELL = 64u;
const float HASH_CELL_SIZE    = 2.0;  // world units per cell edge — kept small on purpose so
                                       // densely packed crowds stay below HASH_MAX_PER_CELL.
                                       // Guaranteed coverage: 3×3 scan ≥ 2.0u, 5×5 scan ≥ 4.0u;
                                       // larger query radii are approximate (see main()).
// Bucket word layout: frame stamp in the high 16 bits, entry count in the low 16.
const uint  HASH_STAMP_SHIFT  = 16u;
const uint  HASH_COUNT_MASK   = 0xFFFFu;

// Map 2-D integer cell coords to a bucket — identical in all three shaders. A wrap-around
// grid rather than a hash: two cells share a bucket only when they are a whole grid apart
// (512 m in x, 256 m in z), so no scan window ever holds two cells of one bucket and the
// HASH_MAX_PER_CELL capacity really is per cell. uint() keeps the two's-complement bits, so
// negative cells wrap as well.
uint spatial_hash(int cx, int cz) {
    return (uint(cx) & (HASH_GRID_W - 1u)) + (uint(cz) & (HASH_GRID_H - 1u)) * HASH_GRID_W;
}

// Given an obstacle, compute the signed distance from pos to its padded surface
// and the outward surface normal at the closest point.
// Negative dist_to_surface means pos is inside the obstacle.
void get_obstacle_surface(Obstacle obs, vec2 pos, float padding,
                          out float dist_to_surface, out vec2 closest_normal) {
    if (obs.type < 0.5) {
        // ---- Circle obstacle ----
        vec2 diff = pos - obs.center;
        float dist = length(diff);
        dist_to_surface  = dist - (obs.half_extents.x + obs.margin + padding);
        closest_normal   = dist > NEAR_ZERO ? diff / dist : vec2(1.0, 0.0);
    } else {
        // ---- OBB obstacle ----
        // Project world position into the obstacle's local (axis-aligned) space
        vec2 local_x = obs.local_x_axis;
        vec2 local_z = vec2(-local_x.y, local_x.x); // perpendicular axis

        vec2 diff      = pos - obs.center;
        vec2 local_pos = vec2(dot(diff, local_x), dot(diff, local_z));

        vec2 padded  = obs.half_extents + vec2(obs.margin + padding);
        vec2 clamped = clamp(local_pos, -padded, padded);
        vec2 local_diff = local_pos - clamped;
        float local_dist = length(local_diff);

        if (local_dist < NEAR_ZERO) {
            // pos is inside the OBB — push out along the shortest axis
            vec2 to_edge = padded - abs(local_pos);
            if (to_edge.x < to_edge.y) {
                closest_normal  = local_pos.x >= 0.0 ? local_x : -local_x;
                dist_to_surface = -to_edge.x;
            } else {
                closest_normal  = local_pos.y >= 0.0 ? local_z : -local_z;
                dist_to_surface = -to_edge.y;
            }
        } else {
            // pos is outside the OBB — normal points from closest surface point to pos
            dist_to_surface = local_dist;
            vec2 local_norm = local_diff / local_dist;
            closest_normal  = local_norm.x * local_x + local_norm.y * local_z;
        }
    }
}

// =============================================================================
// STEERING / STATE HELPERS
// =============================================================================

// Reynolds steering: a force that nudges the current velocity toward
// (desired_dir * speed), capped at MAX_FORCE. desired_dir is expected unit-length.
vec2 steer_toward(vec2 desired_dir, float speed, vec2 velocity) {
    return limit_vec(desired_dir * speed - velocity, MAX_FORCE);
}

// Flag a body as just hit: starts the red damage flash and (re)arms the
// fear/flee timer that the bomb-flee and fear-contagion logic read from.
void mark_damaged(inout Body b) {
    b.last_hit_time = time;
    b.damaged_time  = time + DAMAGED_DISPLAY_DURATION;
}

// The expiry a neighbour inherits when we infect it. It gets a FRACTION of our remaining
// time (CONTAGION_SPREAD_DECAY), capped at max_duration, so each hop is strictly weaker
// than its infector and the outbreak dies out on its own. Returns 0 — spread nothing — once
// that window falls below CONTAGION_MIN_SPREAD_DUR, the floor that ends the chain.
uint child_contagion_expiry(float self_remaining, float max_duration, uint now_u) {
    float child_duration = min(self_remaining * CONTAGION_SPREAD_DECAY, max_duration);
    if (child_duration < CONTAGION_MIN_SPREAD_DUR) return 0u;
    return now_u + uint(child_duration * CONT_TIME_SCALE);
}

// ⚠ KEEP IN SYNC with the copy in projectile_compute.glsl.
// Give body i contagion type t until new_expiry, at dps_u damage per second (× 256). The
// expiry is only ever raised, so concurrent infectors cannot lose each other's time. Keep
// atomicMax's return value: the one invocation that lifts a LAPSED expiry into the future
// starts a new outbreak of this type on this hog, and it replaces the DPS the previous one
// left behind (a stronger old infection would otherwise outlive its own window). Everyone
// else only raises it. A concurrent infector whose atomicMax lands between the winner's two
// atomics loses its DPS to the winner's for that outbreak — accepted, since infections of
// one type normally carry the same DPS.
void infect(int i, uint t, uint new_expiry, uint dps_u, uint now_u) {
    uint prev_expiry = atomicMax(bodies[i].contagion_expiry_u[t], new_expiry);
    if (prev_expiry <= now_u && new_expiry > prev_expiry)
        atomicExchange(bodies[i].contagion_dps_u[t], dps_u);
    else
        atomicMax(bodies[i].contagion_dps_u[t], dps_u);
}

// Probabilistically pass contagion type t to neighbour `i`, expiring at new_expiry (from
// child_contagion_expiry). DPS is inherited at full strength; only the window shrinks.
void try_spread_contagion(int i, uint t, uint new_expiry, uint self_dps,
                          float prob, uint rnd_seed, uint now_u) {
    if (hash(rnd_seed) >= prob) return;
    infect(i, t, new_expiry, self_dps, now_u);
}

// =============================================================================
// MAIN COMPUTE KERNEL
// =============================================================================
void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= uint(num_bodies))
        return;

    Body self = bodies[id];
    if (self.health <= 0.0) {
        // Already a corpse — skip the simulation, but keep the instance's state row marked
        // dead. This shader now owns the instance buffer, and the CPU compaction pass decides
        // what to draw from that state slot alone. Without this write a freshly grown (and
        // therefore uninitialised) instance buffer would hand the CPU garbage that does not
        // read as STATE_DEAD, and corpses would be drawn as live hogs. Only this row needs
        // refreshing: the position rows were written on the frame the hog died, which is the
        // one frame the CPU reads them for the death event.
        instances[(id * INSTANCE_VEC4S) + INST_ROW_CUSTOM] =
            vec4(0.0, 0.0, uintBitsToFloat(STATE_DEAD), time);
        return;
    }

    vec2  to_target      = target - self.position;
    float dist_to_target = length(to_target);
    vec2  target_dir     = dist_to_target > NEAR_ZERO_DIST ? to_target / dist_to_target : vec2(0.0);
    float arrive_t       = clamp(dist_to_target / arrive_radius, 0.0, 1.0); // 0 at the target, 1 from arrive_radius out

    // Body is "airborne" when its height is meaningfully above the ground plane
    bool is_falling = self.height > y_offset + GROUND_EPSILON;

    // =========================================================================
    // FEAR FACTOR  (decays quadratically from 1 → 0 over bomb_fear_duration)
    // =========================================================================
    float fear_factor = 0.0;
    float time_since_hit = time - self.last_hit_time;
    float time_t = 0.0; // normalised elapsed fear time [0, 1]

    if (self.last_hit_time > 0.0 && bomb_fear_duration > 0.0 && time_since_hit < bomb_fear_duration) {
        time_t      = time_since_hit / bomb_fear_duration;
        fear_factor = (1.0 - time_t) * (1.0 - time_t);
    }

    // Blend between calm walk speed and panicked flee speed based on how scared we are
    float max_speed = mix(MAX_WALK_SPEED, MAX_FLEE_SPEED, fear_factor);

    // =========================================================================
    // BOMB IMPULSE + DAMAGE
    // =========================================================================
    // A real bomb anywhere in the buffer widens the neighbour scan below (see `ring`) so its
    // panic can spread. The death-fear nudges C# adds whenever a hog dies cause no fear, so
    // they must not: during an outbreak hogs die every few frames, and counting the nudges
    // kept the whole crowd on the 25-bucket scan for nothing.
    bool fear_bomb_live = false;
    for (int bi = 0; bi < num_bombs; bi++) {
        Bomb bomb       = bombs[bi];
        fear_bomb_live  = fear_bomb_live || bomb.causes_fear > 0.5;
        vec2 to_hog  = self.position - bomb.pos;
        float dist_bomb = length(to_hog);

        if (dist_bomb < bomb.radius && dist_bomb > NEAR_ZERO) {
            // Quadratic falloff: full force/damage at center, zero at edge
            float t = 1.0 - (dist_bomb / bomb.radius);
            float falloff = t * t;

            self.velocity += (to_hog / dist_bomb) * bomb.force * falloff * delta_time;

            // damage > 0 means a real bomb: apply damage flash and set flee origin.
            // damage == 0 is a pure-impulse "fear" wave (e.g. nearby hog death):
            // it nudges velocity only — no red flash, no flee steering.
            if (bomb.damage > 0.0) {
                self.health        -= bomb.damage * falloff;
                self.bomb_origin_x  = bomb.pos.x;
                self.bomb_origin_y  = bomb.pos.y;
                mark_damaged(self);
            }
        }
    }
    self.health = max(0.0, self.health);

    // =========================================================================
    // PROJECTILE EFFECTS  (accumulated by projectile_compute, applied once here)
    // =========================================================================

    // --- Flat damage ---
    if (self.damage_accum > 0u) {
        float proj_dmg = float(self.damage_accum) / DAMAGE_SCALE;
        self.health = max(0.0, self.health - proj_dmg);
        mark_damaged(self);
    }
    self.damage_accum = 0u;

    // --- Contagion DPS tick ---
    // No countdown to write: each expiry is an absolute timestamp that only ever ratchets
    // upward via atomicMax, so being infected is a comparison. (A countdown cannot survive
    // the concurrent spreaders — an earlier version lost every tick to them, and contagion
    // never lapsed.) Each type runs on its own clock and deals its own DPS, so a drunk hog
    // set on fire burns for the fire's window, not the drink's.
    uint now_u = uint(time * CONT_TIME_SCALE); // `time` in the same fixed point as the expiry
    uint contagion_bits = 0u; // STATE_ON_FIRE / POISONED / DRUNK for every live type
    float contagion_dps = 0.0;
    for (uint t = 0u; t < CONT_TYPES; t++) {
        if (self.contagion_expiry_u[t] > now_u) {
            contagion_bits |= STATE_ON_FIRE << t;
            contagion_dps  += float(self.contagion_dps_u[t]) / DAMAGE_SCALE;
        }
    }
    self.health = max(0.0, self.health - contagion_dps * delta_time);

    // --- Teleport ---
    if ((self.body_flags & BODY_FLAG_TELEPORT) != 0u) {
        self.position          = vec2(self.teleport_x, self.teleport_z);
        self.velocity          = vec2(0.0);
        self.height            = self.teleport_y;
        self.vertical_velocity = 0.0;
        self.body_flags        &= ~BODY_FLAG_TELEPORT;
        // Re-evaluate so boids scan and steering below use the new height;
        // prevents arrive/separation forces from injecting XZ velocity the same frame.
        is_falling = self.height > y_offset + GROUND_EPSILON;
    }

    // --- Knockback impulse ---
    // Tested on the raw fixed-point ints: exact, and no float compare that quietly
    // dropped impulses of ±1 unit.
    if ((self.impulse_x | self.impulse_z | self.impulse_y) != 0) {
        float imp_x = float(self.impulse_x) / IMPULSE_SCALE;
        float imp_z = float(self.impulse_z) / IMPULSE_SCALE;
        float imp_y = float(self.impulse_y) / IMPULSE_SCALE;
        self.velocity          += vec2(imp_x, imp_z);
        self.vertical_velocity += imp_y;
        if (imp_y > 0.1) {
            self.height = max(self.height, y_offset + GROUND_EPSILON * 2.0);
        }
        mark_damaged(self);
    }
    self.impulse_x = 0;
    self.impulse_z = 0;
    self.impulse_y = 0;

    // --- Drunk jitter ---
    if ((contagion_bits & STATE_DRUNK) != 0u) {
        float jt = time * 7.3 + float(id) * 1.7;
        self.velocity.x += sin(jt) * DRUNK_JITTER_STR * delta_time;
        self.velocity.y += cos(jt * 0.7) * DRUNK_JITTER_STR * delta_time;
    }

    // =========================================================================
    // BOIDS NEIGHBOR SCAN + FEAR CONTAGION
    // =========================================================================
    vec2 separation       = vec2(0.0); // Weighted sum: push away from nearby peers
    vec2 avg_velocity     = vec2(0.0); // Accumulate neighbor velocities for alignment
    vec2 avg_position     = vec2(0.0); // Accumulate neighbor positions for cohesion
    vec2 overlap_correction = vec2(0.0); // Immediate penetration resolution

    int sep_count = 0, align_count = 0, cohesion_count = 0;

    float best_contagion_fear = 0.0;
    vec2  contagion_bomb_origin = vec2(0.0);

    float closest_neighbor_dist = 9999.0; // Track nearest neighbor for sprint speed logic

    // Our own fear on the linear 1 → 0 scale that the spread test below compares against
    // (fear_factor is its square). No neighbour can hand over more than FEAR_MAX_SPREAD, so a
    // hog already that afraid — typically for a few seconds after a real hit — cannot have
    // its fear changed by the scan, and skips the fear checks and the wide ring outright.
    float self_fear     = fear_factor > 0.0 ? (1.0 - time_t) : 0.0;
    bool  can_gain_fear = bomb_fear_duration > 0.0
                       && FEAR_MAX_SPREAD > self_fear + FEAR_SPREAD_THRESHOLD;

    // What each contagion type would hand a neighbour, from that type's own remaining time.
    // It depends only on this body, so it is worked out once here rather than per neighbour.
    // Zero means nothing to pass on: the type is not live, or the inherited window would fall
    // below the spread floor. (The live bits guarantee the expiry is ahead of now_u, so the
    // subtraction cannot wrap.)
    uint fire_child_expiry   = 0u;
    uint poison_child_expiry = 0u;
    if ((contagion_bits & STATE_ON_FIRE) != 0u)
        fire_child_expiry = child_contagion_expiry(
            float(self.contagion_expiry_u[CONT_FIRE] - now_u) / CONT_TIME_SCALE,
            FIRE_SPREAD_MAX_DUR, now_u);
    if ((contagion_bits & STATE_POISONED) != 0u)
        poison_child_expiry = child_contagion_expiry(
            float(self.contagion_expiry_u[CONT_POISON] - now_u) / CONT_TIME_SCALE,
            POISON_SPREAD_MAX_DUR, now_u);
    bool spreads_fire   = fire_child_expiry   != 0u;
    bool spreads_poison = poison_child_expiry != 0u;

    if (!is_falling) {
        // =====================================================================
        // SPATIAL HASH NEIGHBOR QUERY
        // =====================================================================
        // The hash table was built this frame by spatial_hash_build.glsl before
        // this shader was dispatched.  We query a 5×5 cell neighbourhood:
        //
        //   Inner 3×3  (|dcx|≤1 && |dcz|≤1):
        //     Guarantees full coverage out to HASH_CELL_SIZE (2.0u) — always
        //     enough for separation (comb_radius × SEPARATION_PADDING ≈ 1.5u)
        //     and overlap correction.  ALIGNMENT_RADIUS (2.5) and
        //     COHESION_RADIUS (5.0) exceed the guaranteed coverage, so
        //     flock-mates in those outer bands are only sampled when they land
        //     in a scanned cell — an accepted approximation, chosen so that
        //     densely packed crowds never overflow HASH_MAX_PER_CELL.
        //
        //   Outer ring of 5×5  (|dcx|>1 || |dcz|>1):
        //     Extends guaranteed coverage to 2 × HASH_CELL_SIZE (4.0u) for fear
        //     contagion only.  FEAR_CONTAGION_RADIUS (20) is an upper bound,
        //     not the effective range: per-frame spread is limited by this scan,
        //     and fear travels farther by relaying through intermediate hogs
        //     over several frames.
        //
        // The table is a wrap-around grid (see spatial_hash), so no two cells in
        // this window share a bucket. Cells a whole grid apart (512 m / 256 m) do,
        // and every behavior already has an exact distance check that rejects them.
        // =====================================================================

        int self_cx = int(floor(self.position.x / HASH_CELL_SIZE));
        int self_cz = int(floor(self.position.y / HASH_CELL_SIZE));

        // The outer 5×5 ring exists solely for fear contagion, so scan it only when
        // fear can actually change this frame: this body can still gain fear, and
        // either a real bomb is live or it is inside its own fear window. Otherwise
        // 3×3 is enough and the bucket count per body drops from 25 to 9.
        //
        // Gate on fear_factor, not last_hit_time: last_hit_time is never reset, so
        // once a body has been hit even a single time it would scan the wide ring
        // forever and the saving would decay away as the crowd takes damage.
        int ring = (can_gain_fear && (fear_bomb_live || fear_factor > 0.0)) ? 2 : 1;

        // x innermost: the grid puts a row of cells in adjacent buckets, so
        // consecutive iterations read neighbouring hash_counts words.
        for (int dcz = -ring; dcz <= ring; dcz++) {
            for (int dcx = -ring; dcx <= ring; dcx++) {

                bool inner = (abs(dcx) <= 1 && abs(dcz) <= 1);

                uint bucket      = spatial_hash(self_cx + dcx, self_cz + dcz);
                uint stored      = hash_counts[bucket];
                // Skip buckets not written this frame (stamp mismatch) — that is how
                // the build invalidates old contents without a clear pass.
                if ((stored >> HASH_STAMP_SHIFT) != frame_stamp) continue;
                uint count = min(stored & HASH_COUNT_MASK, HASH_MAX_PER_CELL);

                for (uint k = 0u; k < count; k++) {
                    int i = int(hash_entries[bucket * HASH_MAX_PER_CELL + k]);
                    if (i == int(id)) continue;

                    // Snapshot once. BodiesBuffer is not `coherent`, so these are
                    // ordinary cacheable loads and the compiler is free to fetch only
                    // the fields used below. The atomics in try_spread_contagion run
                    // after this load, so a register copy is correct.
                    Body n = bodies[i];

                    // Re-check aliveness here: a body could have died between
                    // the hash build pass and this pass (same frame, same Sync).
                    if (n.health <= 0.0 || n.height > y_offset + GROUND_EPSILON) continue;

                    vec2  diff  = self.position - n.position;
                    float dist2 = dot(diff, diff);
                    if (dist2 < NEAR_ZERO * NEAR_ZERO) continue;

                    // ---- Fear contagion: both inner and outer rings (up to 20u) ----
                    // Outer ring never needs `dist` — squared compare only.
                    if (can_gain_fear
                        && dist2 < FEAR_CONTAGION_RADIUS * FEAR_CONTAGION_RADIUS) {
                        float n_time = time - n.last_hit_time;
                        // Only spread from neighbors still actively afraid (within early window)
                        if (n.last_hit_time > 0.0 && n_time >= 0.0
                            && n_time < bomb_fear_duration * FEAR_CONTAGION_WINDOW) {
                            float n_fear = 1.0 - (n_time / bomb_fear_duration);
                            if (n_fear > best_contagion_fear) {
                                best_contagion_fear   = n_fear;
                                contagion_bomb_origin = vec2(n.bomb_origin_x, n.bomb_origin_y);
                            }
                        }
                    }

                    // Inner 3×3 only: boid forces and overlap (all within CELL_SIZE = 10u)
                    if (inner) {
                        // One inversesqrt for the unit vector and `dist`. Outer-ring
                        // candidates never enter here, so they never pay a sqrt.
                        float inv_dist = inversesqrt(dist2);
                        float dist     = dist2 * inv_dist;
                        closest_neighbor_dist = min(closest_neighbor_dist, dist);

                        float comb_radius = self.radius + n.radius;

                        // ---- Separation: quadratic repulsion within personal-space bubble ----
                        float sep_radius = comb_radius * SEPARATION_PADDING;
                        if (dist2 < sep_radius * sep_radius) {
                            float norm_dist = dist / sep_radius;
                            separation += diff * inv_dist * (1.0 - norm_dist) * (1.0 - norm_dist);
                            sep_count++;
                        }

                        // ---- Alignment: match heading of nearby neighbors ----
                        if (dist2 < ALIGNMENT_RADIUS * ALIGNMENT_RADIUS) {
                            avg_velocity += n.velocity;
                            align_count++;
                        }

                        // ---- Cohesion: steer toward local crowd center ----
                        if (dist2 < COHESION_RADIUS * COHESION_RADIUS) {
                            avg_position += n.position;
                            cohesion_count++;
                        }

                        // ---- Hard overlap correction: resolve actual body interpenetration ----
                        if (dist2 < comb_radius * comb_radius) {
                            overlap_correction += diff * inv_dist * (comb_radius - dist) * OVERLAP_CORRECTION_FACTOR;
                        }

                        // ---- Drunk fear: a staggering hog unsettles the hogs right next to it ----
                        // Pull-based, exactly like the bomb fear above: the frightened hog reads
                        // the drunk one, so this needs no atomics and re-evaluates every frame the
                        // two stay close. Inner ring only — DRUNK_FEAR_RADIUS sits inside the 3×3's
                        // guaranteed coverage, so it does not depend on `ring`.
                        if (can_gain_fear
                            && dist2 < DRUNK_FEAR_RADIUS * DRUNK_FEAR_RADIUS
                            && n.contagion_expiry_u[CONT_DRUNK] > now_u) {
                            float n_remaining = float(n.contagion_expiry_u[CONT_DRUNK] - now_u) / CONT_TIME_SCALE;
                            // Falls off with both the neighbour's remaining drunkenness and the
                            // gap between us — the second factor keeps the effect from having a
                            // hard edge at DRUNK_FEAR_RADIUS.
                            float n_fear = DRUNK_FEAR_STRENGTH
                                         * clamp(n_remaining / DRUNK_FEAR_FADE, 0.0, 1.0)
                                         * (1.0 - dist / DRUNK_FEAR_RADIUS);
                            if (n_fear > best_contagion_fear) {
                                best_contagion_fear = n_fear;
                                // Flee the drunk hog itself rather than any bomb: this is the
                                // origin the panic steers away from, and it is re-read every
                                // frame, so hogs keep backing away as the drunk one staggers.
                                contagion_bomb_origin = n.position;
                            }
                        }

                        // ---- Contagion spread: fire and poison propagate to nearby bodies ----
                        // Per-frame random seed mixes id, neighbour index and time so no
                        // two pairs (and no two frames) roll the same probability.
                        if (spreads_fire && dist2 < FIRE_SPREAD_RADIUS * FIRE_SPREAD_RADIUS) {
                            try_spread_contagion(i, CONT_FIRE, fire_child_expiry,
                                self.contagion_dps_u[CONT_FIRE], FIRE_SPREAD_PROB,
                                id * 31u + uint(i) + uint(time * 100.0 + 0.5), now_u);
                        }
                        if (spreads_poison && dist2 < POISON_SPREAD_RADIUS * POISON_SPREAD_RADIUS) {
                            try_spread_contagion(i, CONT_POISON, poison_child_expiry,
                                self.contagion_dps_u[CONT_POISON], POISON_SPREAD_PROB,
                                id * 47u + uint(i) * 3u + uint(time * 100.0 + 1.5), now_u);
                        }
                    }
                }
            }
        }

        // Apply contagion only if the spread fear is meaningfully stronger than our current fear.
        // best_contagion_fear is whichever source won above — a panicking neighbour relaying a bomb,
        // or a drunk hog next to us — so the two share one back-calculated fear state and cannot
        // stack. Strongest wins.
        if (best_contagion_fear > 0.0) {
            float spread_fear = best_contagion_fear * FEAR_CONTAGION_DECAY;

            if (spread_fear > self_fear + FEAR_SPREAD_THRESHOLD && spread_fear > FEAR_SPREAD_THRESHOLD) {
                // Back-calculate a last_hit_time that produces spread_fear's intensity
                self.last_hit_time  = time - bomb_fear_duration * (1.0 - spread_fear);
                self.bomb_origin_x  = contagion_bomb_origin.x;
                self.bomb_origin_y  = contagion_bomb_origin.y;

                // The fear state that last_hit_time now encodes. time_t has to move with
                // fear_factor: the flee radius below divides by it, and leaving it stale
                // (0 for a hog that was calm) let a newly frightened hog flee from any
                // distance for a frame.
                time_t      = 1.0 - spread_fear;
                fear_factor = spread_fear * spread_fear;
                max_speed   = mix(MAX_WALK_SPEED, MAX_FLEE_SPEED, fear_factor);
            }
        }
    }

    // =========================================================================
    // CATCH-UP SPRINT  (only when calm and not airborne)
    // =========================================================================
    if (!is_falling && fear_factor < FEAR_THRESHOLD) {
        // Ramp up from zero to full sprint as distance to target grows beyond SPRINT_DIST_MULT * arrive_radius
        float target_dist_blend = smoothstep(
            arrive_radius * SPRINT_DIST_MULT,
            arrive_radius * SPRINT_DIST_MULT + SPRINT_DIST_RANGE,
            dist_to_target
        );

        // Throttle sprint back to walk speed when a neighbor is within CROWD_CLEAR_MULT * radius
        float crowd_clearance = smoothstep(
            self.radius * CROWD_CLEAR_MULT,
            self.radius * CROWD_CLEAR_MULT + CROWD_CLEAR_RANGE,
            closest_neighbor_dist
        );

        float sprint_blend = target_dist_blend * crowd_clearance;
        max_speed = mix(max_speed, MAX_RUN_SPEED, sprint_blend);
    }

    // =========================================================================
    // STEERING FORCES
    // =========================================================================

    // Speed going into this frame's steering. Nothing below changes self.velocity until the
    // integration step, so this serves the arrive, straggler and settle terms alike.
    float pre_speed = length(self.velocity);

    // ---- Separation ----
    // Guarded like alignment and cohesion: neighbours that cancel exactly would otherwise
    // hand normalize() a zero vector and poison the body with NaN.
    vec2 steer_separation = (sep_count > 0 && length(separation) > NEAR_ZERO)
        ? steer_toward(normalize(separation), max_speed, self.velocity)
        : vec2(0.0);

    // ---- Alignment ----
    vec2 steer_alignment = (align_count > 0 && length(avg_velocity) > NEAR_ZERO)
        ? steer_toward(normalize(avg_velocity), max_speed, self.velocity)
        : vec2(0.0);

    // ---- Cohesion ----
    vec2 cohesion_center = avg_position / float(max(cohesion_count, 1));
    vec2 steer_cohesion  = (cohesion_count > 0 && length(cohesion_center - self.position) > NEAR_ZERO)
        ? steer_toward(normalize(cohesion_center - self.position), max_speed, self.velocity)
        : vec2(0.0);

    // ---- Arrive ----
    vec2  steer_arrive = vec2(0.0);
    float straggler    = 0.0;

    if (!is_falling) {
        // Smooth-step desired speed to zero as we enter the arrive radius (prevents overshooting)
        float desired_speed = max_speed * smoothstep(0.0, arrive_radius, dist_to_target);

        // straggler: amplifies arrive force for bodies far behind the crowd that have nearly stopped
        straggler = smoothstep(arrive_radius, arrive_radius * 3.0, dist_to_target)
                  * smooth_fall(0.0, max_speed * STEER_STRAGGLER_BOOST * 0.033, pre_speed);

        // Footstep sway: two-harmonic sinusoid modulated by speed and proximity to target
        float stride_phase = hash(id) * TAU; // per-body phase so strides don't sync up
        float sway = WANDER_STRENGTH * (
              sin(time * STRIDE_FREQ * TAU + stride_phase)
            + WANDER_HARMONIC_AMP * sin(time * STRIDE_FREQ * TAU * WANDER_HARMONIC_FREQ
                                        + stride_phase * WANDER_HARMONIC_PHASE)
        );
        float wander_angle = sway
            * clamp(pre_speed / (max_speed * WANDER_SPEED_BLEND), 0.0, 1.0)
            * smoothstep(0.0, arrive_radius * WANDER_ARRIVE_BLEND, dist_to_target);

        steer_arrive = steer_toward(rotate2d(target_dir, wander_angle), desired_speed, self.velocity);
    }

    // ---- Obstacle avoidance (soft steering) ----
    vec2 steer_obstacle = vec2(0.0);
    for (int oi = 0; oi < num_obstacles; oi++) {
        // Broad phase — reject on centre distance before running the surface math.
        //
        // padded.x + padded.y is an upper bound on the distance from the obstacle centre to
        // any point on its padded surface, since sqrt(x*x + y*y) <= x + y for non-negative
        // x, y. So dist_surface >= dist_centre - (padded.x + padded.y), and anything failing
        // the test below could not possibly have satisfied dist_surface < DETECT_RADIUS.
        // The reject is therefore conservative by construction: it changes which obstacles
        // are *evaluated*, never which ones have an effect.
        vec2  to_obs = self.position - obstacles[oi].center;
        vec2  padded = obstacles[oi].half_extents + vec2(obstacles[oi].margin + self.radius);
        float reach  = padded.x + padded.y + OBSTACLE_DETECT_RADIUS;
        if (dot(to_obs, to_obs) > reach * reach) continue;

        float dist_surface;
        vec2  normal;
        get_obstacle_surface(obstacles[oi], self.position, self.radius, dist_surface, normal);

        if (dist_surface < OBSTACLE_DETECT_RADIUS) {
            float t = 1.0 - clamp(dist_surface / OBSTACLE_DETECT_RADIUS, 0.0, 1.0);

            // Choose a skirting tangent side based on current velocity; randomise if ambiguous
            float side = dot(self.velocity, vec2(-normal.y, normal.x));
            side = abs(side) < NEAR_ZERO
                ? (hash(id + uint(oi) * OBSTACLE_HASH_SEED) > 0.5 ? 1.0 : -1.0)
                : side;

            vec2 tangent  = vec2(-normal.y, normal.x) * sign(side);
            // Close to surface: pure push-away (normal). Farther out: blend toward tangent (skirting).
            vec2 steer_dir = mix(
                normalize(normal * (1.0 - OBSTACLE_TANGENT_BLEND) + tangent * OBSTACLE_TANGENT_BLEND),
                normal,
                smooth_fall(0.0, OBSTACLE_DETECT_RADIUS * OBSTACLE_HALF_DETECT, dist_surface)
            );
            steer_obstacle += steer_dir * (t * t * MAX_FORCE);
        }
    }
    steer_obstacle = limit_vec(steer_obstacle, MAX_FORCE);

    // ---- Flee from bomb origin ----
    vec2 steer_flee = vec2(0.0);
    if (!is_falling && fear_factor > 0.0) {
        vec2  away     = self.position - vec2(self.bomb_origin_x, self.bomb_origin_y);
        float dist_bomb = length(away);
        // Flee radius shrinks as fear fades (less urgency to run further over time)
        if (dist_bomb > NEAR_ZERO_DIST && dist_bomb < FLEE_MIN_RADIUS / max(time_t, NEAR_ZERO_DIST)) {
            steer_flee = steer_toward(normalize(away), max_speed, self.velocity);
        }
    }

    // =========================================================================
    // VELOCITY INTEGRATION + DAMPING
    // =========================================================================

    // prox_settle: proximity-only settle factor. Reaches 1.0 based on distance alone,
    // regardless of current velocity. Used to suppress forces that cause jitter (separation
    // steering, neighbour-overlap nudges) BEFORE the combined settle can engage — breaking
    // the catch-22 where separation keeps velocity too high for settle to ever trigger.
    float prox_settle = smooth_fall(arrive_radius * SETTLE_RADIUS * SETTLE_INNER_FRACTION,
                                    arrive_radius * SETTLE_RADIUS,
                                    dist_to_target);

    // settle: blends to 1 only when BOTH close AND nearly stopped → triggers hard braking.
    // Because prox_settle has already suppressed the destabilising forces by this point,
    // velocity will have decayed enough for this condition to be reachable.
    float settle = prox_settle
                 * smooth_fall(max_speed * 0.02, max_speed * 0.15, pre_speed);

    float calm     = 1.0 - fear_factor;
    float activity = 1.0 - settle;
    float proximity = 1.0 - arrive_t; // 1 = at target, 0 = far away

    // Combine all steering forces with their behavior weights
    vec2 arrive_contrib = steer_arrive * ARRIVE_WEIGHT * (1.0 + straggler * STEER_STRAGGLER_BOOST) * activity * calm;
    // Scale separation down in the settle zone so packed resting bodies stop fighting each other.
    // Keep a 10% floor so hard interpenetration still gets resolved even when fully settled.
    vec2 separation_contrib = steer_separation * SEPARATION_WEIGHT
                            * max(1.0 - prox_settle * 0.9, 0.1)
                            * (1.0 + proximity * STEER_SEP_PROXIMITY_BOOST);
    vec2 alignment_contrib  = steer_alignment  * ALIGNMENT_WEIGHT  * activity * calm;
    vec2 cohesion_contrib   = steer_cohesion   * COHESION_WEIGHT   * (1.0 - proximity * STEER_COH_PROXIMITY_DECAY) * activity * calm;
    vec2 obstacle_contrib   = steer_obstacle   * OBSTACLE_WEIGHT;
    vec2 flee_contrib       = steer_flee       * FLEE_WEIGHT       * fear_factor;

    vec2 force = arrive_contrib + separation_contrib + alignment_contrib
               + cohesion_contrib + obstacle_contrib + flee_contrib;

    self.velocity += (limit_vec(force, MAX_FORCE) / self.mass) * delta_time;

    if (!is_falling) {
        self.velocity = limit_vec(self.velocity, max_speed);

        // Three-way damping blend:
        //   NEAR → FAR  based on distance to target
        //   then crush toward SETTLE when stopping
        //   then relax toward FEAR to preserve flee momentum
        float base_damp   = mix(DAMPING_NEAR, DAMPING_FAR, arrive_t);
        float damping     = mix(mix(base_damp, DAMPING_SETTLE, settle), DAMPING_FEAR, fear_factor);
        self.velocity    *= damping;

        // Snap velocity to zero below a small threshold to prevent endless micro-drift
        // Use the higher of settle and prox_settle so we snap to zero aggressively near the
        // target even before the velocity-gated settle has fully engaged.
        float stop_epsilon = mix(VELOCITY_EPSILON, VELOCITY_EPSILON * 8.0, max(settle, prox_settle));
        if (length(self.velocity) < stop_epsilon) {
            self.velocity = vec2(0.0);
        }

        // Apply neighbour overlap correction when penetration exceeds the dead-band.
        // Fade out near the target (prox_settle) so that packed resting bodies stop
        // nudging each other and oscillating; the PBD obstacle section still handles hard
        // wall/object contacts independently.
        if (length(overlap_correction) > OVERLAP_DEAD_BAND) {
            self.position += limit_vec(overlap_correction, self.radius * PBD_CORRECTION_MAX)
                           * (1.0 - prox_settle * 0.8)
                           * delta_time * PBD_CORRECTION_SCALE;
        }
    } else {
        self.velocity *= AIR_FRICTION; // Minimal air resistance while airborne
    }

    self.position += self.velocity * delta_time;

    // =========================================================================
    // OBSTACLE HARD CONSTRAINT  (Position-Based Dynamics)
    // =========================================================================
    if (!is_falling) {
        // The hog's own axes in world XZ — the instance basis written at the tail maps local
        // +z (forward) to (sin f, cos f) and local +x (right) to (cos f, -sin f) — and the
        // furthest its drawn footprint reaches in any direction, for the broad phase. The
        // facing is still last frame's (it is updated below), so a hog turning its nose into a
        // wall can graze it for a frame before the next pass pushes it clear.
        vec2  fwd       = vec2(sin(self.facing_angle), cos(self.facing_angle));
        vec2  right     = vec2(fwd.y, -fwd.x);
        float max_reach = max(self.radius, length(max(abs(footprint_min), abs(footprint_max))));

        for (int iter = 0; iter < PBD_ITERATIONS; iter++) {
            for (int oi = 0; oi < num_obstacles; oi++) {
                Obstacle obs = obstacles[oi];

                // Broad phase — same centre-distance bound as the soft-steering loop, but taken
                // to the margin-padded surface only (the hog's own reach arrives through
                // contact_radius below), and allowing for a contact radius that grows with
                // surface speed. |surf_vel| <= |linear| + |angular| * |offset from centre|, an
                // upper bound on the speed_clearance computed below, so this stays conservative
                // for moving and rotating obstacles too.
                vec2  to_obs = self.position - obs.center;
                float dist_centre = length(to_obs);
                vec2  padded = obs.half_extents + vec2(obs.margin);
                float max_surf_speed = length(obs.velocity) + (abs(obs.angular_vel) * dist_centre);
                float max_clearance  = max_surf_speed * delta_time * PBD_VEL_LOOKAHEAD;
                if (dist_centre > padded.x + padded.y + max_reach + max_clearance) {
                    continue;
                }

                // Distance from the hog's CENTRE to the margin-padded surface; how far the hog
                // reaches toward it is added below. (The soft steering above pads by BodyRadius
                // instead: it wants a gap to steer by, not a contact.)
                float dist_surface;
                vec2  normal;
                get_obstacle_surface(obs, self.position, 0.0, dist_surface, normal);

                // Surface velocity at this contact point (linear + rotational components)
                vec2 surf_vel = obs.velocity + vec2(
                     obs.angular_vel * (self.position.y - obs.center.y),
                    -obs.angular_vel * (self.position.x - obs.center.x)
                );

                // In contact once the DRAWN hog reaches the surface: its footprint's extent
                // toward the obstacle, never less than BodyRadius. BodyRadius alone is far
                // smaller than the mesh and let hogs sink into walls. A moving surface reaches
                // further, by the distance it will cover in PBD_VEL_LOOKAHEAD frames, so a
                // sweeping wall cannot tunnel through a hog.
                float reach           = max(self.radius, footprint_reach(-normal, right, fwd));
                float speed_clearance = length(surf_vel) * delta_time * PBD_VEL_LOOKAHEAD;
                float contact_radius  = reach + speed_clearance;

                if (dist_surface < contact_radius) {
                    // Push out until the hog rests against the surface (plus the lookahead)
                    self.position += normal * (contact_radius - dist_surface);

                    // Blend velocity toward the surface velocity (friction/conveyor effect),
                    // harder the deeper the overlap — fully once the centre was inside
                    self.velocity = dist_surface < 0.0
                        ? surf_vel
                        : mix(self.velocity, surf_vel, 1.0 - clamp(dist_surface / contact_radius, 0.0, 1.0));

                    // Cancel any velocity component driving deeper into the surface
                    float into_vel = dot(self.velocity, -normal);
                    if (into_vel > 0.0)
                        self.velocity += normal * into_vel;
                }
            }
        }
    }

    // =========================================================================
    // FACING ANGLE UPDATE
    // =========================================================================
    float speed = length(self.velocity);

    // Ease speed toward its instantaneous value at a fixed rate (frame-rate independent) so the
    // locomotion-state classification below reacts smoothly instead of snapping every frame.
    self.speed_ema += (speed - self.speed_ema) * (1.0 - exp(-STATE_EASE_RATE * delta_time));

    // speed_trust: how much we trust the velocity vector for facing vs. looking at the target
    // Low speed → trust the target direction; high speed → trust the movement direction
    float speed_trust = smoothstep(max_speed * SPEED_TRUST_LOW, max_speed * SPEED_TRUST_HIGH, speed);

    float target_angle = self.facing_angle; // Default: hold current angle
    if (dist_to_target > self.radius * 2.0) {
        // target_dir is the unit look direction here: the distance test above clears its
        // NEAR_ZERO_DIST guard.
        vec2 move_dir = speed > NEAR_ZERO ? (self.velocity / speed) : target_dir;

        // Blend look and move directions as vectors, not angles — prevents 180° flip artefacts
        // when a noisy near-zero velocity crosses an axis boundary.
        vec2 face_dir = mix(target_dir, move_dir, speed_trust);
        if (length(face_dir) < NEAR_ZERO_DIST)
            face_dir = target_dir;

        target_angle = atan(face_dir.x, face_dir.y);
    }

    float diff_angle = shortest_angle_diff(self.facing_angle, target_angle);

    // Dead-band: ignore tiny angle errors to prevent endless micro-rotation
    float dead_band = max(mix(ROT_DEADBAND_MOVING, ROT_DEADBAND_SETTLE, settle),
                          smooth_fall(VELOCITY_EPSILON, max_speed * 0.15, speed) * 0.1);
    if (abs(diff_angle) < dead_band)
        diff_angle = 0.0;

    // Rotation speed: scales with movement speed and blends down to a fixed base when settling
    float velocity_scaled_rot = rotation_speed * (ROT_SPEED_BIAS + ROT_SPEED_SCALE
                               * clamp(speed / (max_speed * ROT_SPEED_HALF), 0.0, 1.0));
    float rot_speed = mix(mix(ROT_SPEED_BASE, velocity_scaled_rot, speed_trust), ROT_SPEED_BASE, settle);

    // Rotate a fraction of the way toward the target this frame, then re-wrap
    // into [-PI, PI] via the (x + PI mod TAU) - PI idiom.
    self.facing_angle = mod(
        self.facing_angle + diff_angle * clamp(rot_speed * delta_time, 0.0, 1.0) + PI,
        TAU
    ) - PI;

    // =========================================================================
    // GRAVITY
    // =========================================================================
    if (self.height > y_offset) {
        self.vertical_velocity -= gravity * hog_gravity_scale * delta_time;
        self.height            += self.vertical_velocity * delta_time;
    }
    if (self.height <= y_offset) {
        self.height            = y_offset;
        self.vertical_velocity = 0.0;
    }

    // =========================================================================
    // BEHAVIOUR STATE  (bitwise flags — read back by C# via the instance buffer)
    // =========================================================================
    // Built fresh every frame, contagion bits included: those come from this body's live
    // contagion types (contagion_bits, above), so a type's bit clears on the frame it
    // lapses and nothing but this thread ever produces them. They used to sit in a shared
    // state word that neighbours set with atomics, which forced them to be sticky past
    // expiry. A type a neighbour hands us during this dispatch shows up next frame, as its
    // tint does.
    uint st = contagion_bits;
    if (self.health <= 0.0) {
        st |= STATE_DEAD;
    } else {
        if (is_falling)              st |= STATE_AIRBORNE;
        if (time < self.damaged_time) st |= STATE_DAMAGED;

        // Locomotion state — mutually exclusive, highest priority first.
        // Classified off speed_ema (eased), not the raw speed, so the reported state settles
        // smoothly through a threshold instead of flickering back and forth every frame.
        if (fear_factor > FEAR_THRESHOLD) {
            if (self.speed_ema > MAX_WALK_SPEED * 0.5)
                st |= STATE_FLEEING;
            else
                st |= STATE_IN_FEAR;
        } else if (self.speed_ema > SPRINT_SPEED_THRESHOLD) {
            st |= STATE_SPRINTING;
        // Raise the walk threshold when near the target so that residual micro-velocity
        // from packing forces does not flip the state back to WALKING every other frame.
        } else if (self.speed_ema > mix(VELOCITY_EPSILON, VELOCITY_EPSILON * 3.5, prox_settle)) {
            st |= STATE_WALKING;
        } else {
            st |= STATE_IDLE;
        }
    }

    // -------------------------------------------------------------------------
    // Field-by-field writeback.
    //
    // `bodies[id] = self` cannot be used here: it would also rewrite contagion_expiry_u[]
    // and contagion_dps_u[] from this thread's stale local copy, clobbering the atomic
    // writes neighbour threads make to them during this same dispatch. That is what made
    // fire and poison spread drop events at random.
    //
    // radius, mass, teleport_x, teleport_z, teleport_y and pad29 are omitted because
    // physics never modifies them, so this also moves less data than the struct store.
    // -------------------------------------------------------------------------
    bodies[id].position          = self.position;
    bodies[id].velocity          = self.velocity;
    bodies[id].height            = self.height;
    bodies[id].vertical_velocity = self.vertical_velocity;
    bodies[id].facing_angle      = self.facing_angle;
    bodies[id].health            = self.health;
    bodies[id].last_hit_time     = self.last_hit_time;
    bodies[id].bomb_origin_x     = self.bomb_origin_x;
    bodies[id].bomb_origin_y     = self.bomb_origin_y;
    bodies[id].damaged_time      = self.damaged_time;
    bodies[id].damage_accum      = self.damage_accum;
    bodies[id].body_flags        = self.body_flags;
    bodies[id].impulse_x         = self.impulse_x;
    bodies[id].impulse_z         = self.impulse_z;
    bodies[id].impulse_y         = self.impulse_y;
    bodies[id].speed_ema         = self.speed_ema;

    // =========================================================================
    // MULTIMESH INSTANCE DATA
    // =========================================================================
    // Formerly a separate transform_compute dispatch. Everything below comes from registers
    // this shader already holds, so merging removed a dispatch, a barrier, and a re-read of
    // every whole Body. `speed` was computed in the facing-angle section above and
    // is still current: the gravity block only touches vertical_velocity and height.

    // Y-axis rotation
    float cf = cos(self.facing_angle);
    float sf = sin(self.facing_angle);

    // --- Contagion tint, eased out over the contagion's final seconds ---
    // The highest-priority live type colours the hog — fire, then poison, then drunk — and
    // fades with that type's own remaining time, so a drunk hog set on fire glows red until
    // the fire lapses and then purple again. Uses the expiries as read at the top of main: a
    // hog infected by a NEIGHBOUR during this same dispatch tints one frame later. Projectile
    // hits are unaffected — those land in the previous dispatch. One frame at 60 Hz is not
    // observable, and avoiding a second read of the expiries per body is the point.
    //
    // The colours below leave the display range (see FIRE_GLOW and friends) — the pulse now
    // scales the whole colour rather than one channel, so it modulates the glow instead of
    // sliding the hue. The fade still lerps from white, so it doubles as a glow fade: a hop
    // late in its window sits near 1.0 and emits nothing, and only a freshly infected hog is
    // hot enough to bloom.
    vec3 tint = vec3(1.0);
    if (contagion_bits != 0u) {
        uint shown = (contagion_bits & STATE_ON_FIRE)  != 0u ? CONT_FIRE
                   : (contagion_bits & STATE_POISONED) != 0u ? CONT_POISON
                   :                                           CONT_DRUNK;
        vec3 contagion_tint;
        if (shown == CONT_FIRE) {
            float pulse = 0.8 + 0.2 * sin(time * 10.0 + float(id) * 0.7);
            contagion_tint = FIRE_TINT * (FIRE_GLOW * pulse);
        } else if (shown == CONT_POISON) {
            contagion_tint = POISON_TINT * POISON_GLOW;
        } else {
            float pulse = 0.7 + 0.3 * sin(time * 4.0 + float(id) * 1.3);
            contagion_tint = DRUNK_TINT * (DRUNK_GLOW * pulse);
        }
        float remaining = float(self.contagion_expiry_u[shown] - now_u) / CONT_TIME_SCALE;
        tint = mix(vec3(1.0), contagion_tint, clamp(remaining / CONTAGION_FADE_TIME, 0.0, 1.0));
    }

    // Godot MultiMesh row-major layout: rows 0-2 are [basis column | origin component].
    uint o = id * INSTANCE_VEC4S;
    instances[o + 0u] = vec4( cf, 0.0,  sf, self.position.x);
    instances[o + 1u] = vec4(0.0, 1.0, 0.0, self.height);
    instances[o + 2u] = vec4(-sf, 0.0,  cf, self.position.y);
    instances[o + 3u] = vec4(tint, 1.0);
    instances[o + 4u] = vec4(speed, self.health, uintBitsToFloat(st), time);
}
