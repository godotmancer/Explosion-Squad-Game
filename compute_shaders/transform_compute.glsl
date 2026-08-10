#[compute]
#version 450

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

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
    uint  contagion_expiry_u; // absolute contagion expiry time × 256
    uint  dps_rate_u;
    uint  body_flags;
    float teleport_x;
    float teleport_z;
    int   impulse_x;
    int   impulse_z;
    int   impulse_y;
    float teleport_y;
    float speed_ema;
    float pad3;
};

const uint STATE_ON_FIRE  = 256u;   // bit 8
const uint STATE_POISONED = 512u;   // bit 9
const uint STATE_DRUNK    = 1024u;  // bit 10

const float CONT_TIME_SCALE = 256.0; // must match physics_compute.glsl

// Seconds of remaining contagion over which the tint fades back to white. Because a spread
// hop only inherits a fraction of its infector's remaining time, hops far from the origin
// start out already inside this window and therefore render faint — the outbreak visibly
// weakens as it travels, rather than every infected hog looking equally lit until it snaps
// back to white.
const float CONTAGION_FADE_TIME = 1.5;

layout(set = 0, binding = 0, std430) restrict readonly buffer BodiesBuffer {
    Body bodies[];
};

layout(set = 0, binding = 1, std430) restrict writeonly buffer TransformBuffer {
    float data[];
};

layout(push_constant, std430) uniform Params {
    int num_bodies;
    float _pad0;
    float time;
    float _pad1;
};

void main() {
    uint id = gl_GlobalInvocationID.x;
    if (id >= num_bodies) return;

    Body b = bodies[id];
    float speed = length(b.velocity);
    float angle = b.facing_angle;

    // Y-axis rotation matrix components
    float c = cos(angle);
    float s = sin(angle);

    uint offset = id * 20;

    // Rotation around Y axis:
    // Row 0: basis X
    data[offset + 0]  = c;              // basis.x.x
    data[offset + 1]  = 0.0;            // basis.x.y
    data[offset + 2]  = s;              // basis.x.z
    data[offset + 3]  = b.position.x;   // origin.x

    // Row 1: basis Y
    data[offset + 4]  = 0.0;            // basis.y.x
    data[offset + 5]  = 1.0;            // basis.y.y
    data[offset + 6]  = 0.0;            // basis.y.z
    data[offset + 7]  = b.height;       // origin.y

    // Row 2: basis Z
    data[offset + 8]  = -s;             // basis.z.x
    data[offset + 9]  = 0.0;            // basis.z.y
    data[offset + 10] = c;              // basis.z.z
    data[offset + 11] = b.position.y;   // origin.z

    // --- Instance color — contagion visual feedback ---
    // contagion_expiry_u is an absolute timestamp in 1/256 s units, so "infected" is
    // simply expiry > now, compared in fixed point.
    vec3 tint = vec3(1.0);
    uint now_u = uint(time * CONT_TIME_SCALE);
    if (b.contagion_expiry_u > now_u) {
        vec3 contagion_tint = vec3(1.0);
        if ((b.state & STATE_ON_FIRE) != 0u) {
            float pulse = 0.8 + 0.2 * sin(time * 10.0 + float(id) * 0.7);
            contagion_tint = vec3(pulse, 0.25, 0.0);
        } else if ((b.state & STATE_POISONED) != 0u) {
            contagion_tint = vec3(0.15, 0.9, 0.1);
        } else if ((b.state & STATE_DRUNK) != 0u) {
            float pulse = 0.7 + 0.3 * sin(time * 4.0 + float(id) * 1.3);
            contagion_tint = vec3(0.6 * pulse, 0.05, 0.9);
        }

        // Ease the tint out over the contagion's last CONTAGION_FADE_TIME seconds. Guarded
        // by the branch above, so this subtraction cannot wrap.
        float remaining = float(b.contagion_expiry_u - now_u) / CONT_TIME_SCALE;
        float intensity = clamp(remaining / CONTAGION_FADE_TIME, 0.0, 1.0);
        tint = mix(vec3(1.0), contagion_tint, intensity);
    }
    data[offset + 12] = tint.r;
    data[offset + 13] = tint.g;
    data[offset + 14] = tint.b;
    data[offset + 15] = 1.0;

    // --- Custom Data ---
    data[offset + 16] = speed;                     // INSTANCE_CUSTOM.r
    data[offset + 17] = b.health;                  // INSTANCE_CUSTOM.g
    data[offset + 18] = uintBitsToFloat(b.state);  // INSTANCE_CUSTOM.b  (bitwise state flags)
    data[offset + 19] = time;                      // INSTANCE_CUSTOM.a
}
