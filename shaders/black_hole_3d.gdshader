shader_type spatial;
render_mode unshaded;
uniform float radius;
uniform sampler2D noise : filter_nearest;
uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

uniform float spin : hint_range(0.0, 1.0) = 0.4;
uniform float shadow_asymmetry : hint_range(0.0, 1.0) = 0.5;
uniform float shadow_oblateness : hint_range(0.0, 1.0) = 0.5;
uniform float frame_drag_strength : hint_range(0.0, 1.0) = 0.5;
uniform float doppler_beaming = 0.5;
uniform float warp_falloff : hint_range(0.5, 8.0) = 2.5;
uniform float warp_strength : hint_range(0.0, 2.0) = 1.0;
uniform float warp_inner_edge : hint_range(0.0, 0.9) = 0.3;

uniform vec3 color_core : source_color = vec3(0.88, 0.96, 1.00);
uniform float brightness_core : hint_range(0.0, 40.0) = 22.0;
uniform vec3 color_hot : source_color = vec3(0.20, 0.60, 1.00);
uniform float brightness_hot : hint_range(0.0, 20.0) = 10.0;
uniform vec3 color_mid : source_color = vec3(0.05, 0.35, 1.00);
uniform float brightness_mid : hint_range(0.0, 15.0) = 6.5;
uniform vec3 color_cool : source_color = vec3(0.10, 0.45, 0.95);
uniform float brightness_cool : hint_range(0.0, 10.0) = 4.0;
uniform vec3 color_outer : source_color = vec3(0.95, 0.55, 0.15);
uniform float brightness_outer : hint_range(0.0, 10.0) = 2.2;
uniform vec3 color_edge : source_color = vec3(0.7, 0.08, 0.02);
uniform float brightness_edge : hint_range(0.0, 5.0) = 1.1;

uniform float gradient_stop0 : hint_range(0.0, 1.0) = 0.08;
uniform float gradient_stop1 : hint_range(0.0, 1.0) = 0.25;
uniform float gradient_stop2 : hint_range(0.0, 1.0) = 0.55;
uniform float gradient_stop3 : hint_range(0.0, 1.0) = 0.80;
uniform float color_saturation : hint_range(0.0, 3.0) = 1.5;

uniform float grav_redshift_strength : hint_range(0.0, 2.0) = 0.85;
uniform float turbulence_strength : hint_range(0.0, 1.0) = 0.28;
uniform float turbulence_scale : hint_range(0.5, 8.0) = 2.5;
uniform float turbulence_speed : hint_range(0.0, 2.0) = 0.35;
uniform float density_heat_strength : hint_range(0.0, 1.0) = 0.55;
uniform float density_heat_power : hint_range(0.1, 1.0) = 0.3;

uniform float rs : hint_range(0.1, 3.0) = 0.7;

#define fade 0.15
#define R 7.0
#define R0 1.75
#define R_INV 0.18868
#define SPIN_AXIS vec3(0.0, 1.0, 0.0)

float accretion_density(float l, float ang, float y) {
    float n = texture(noise, vec2(0.5 * ang / PI + TIME * 0.2, log(l) * 1.5)).r;
    float d0 = pow(max(1.0 - l / R, 0.0) * clamp((l - R0) / fade + 1.0, 0.0, 1.0), 1.5);
    return d0 * exp(-y * y * 400.0) * 13.0 * (n + max(0.0, n - 0.65) * 1.5);
}

vec3 temperature_color(float l, float r, float d, float ang) {
    float turb_x = 0.5 * ang / PI + TIME * turbulence_speed;
    float turb_y = log(max(l, 0.01)) * turbulence_scale;
    float n1 = texture(noise, vec2(turb_x * 0.7 + 0.3, turb_y * 0.5)).r;
    float n2 = texture(noise, vec2(turb_x * 1.3 + 0.6, turb_y * 1.1 + 0.4)).r;
    float t = clamp((l - R0) * R_INV + (n1 * 0.6 + n2 * 0.4 - 0.5) * turbulence_strength, 0.0, 1.0);

    vec3 c0 = color_core  * brightness_core;
    vec3 c1 = color_hot   * brightness_hot;
    vec3 c2 = color_mid   * brightness_mid;
    vec3 c3 = color_cool  * brightness_cool;
    vec3 c4 = color_outer * brightness_outer;
    vec3 c5 = color_edge  * brightness_edge;

    float s0 = gradient_stop0;
    float s1 = gradient_stop1;
    float s2 = gradient_stop2;
    float s3 = gradient_stop3;

    vec3 col = t < s0 ? mix(c0, c1, t / max(s0, 0.001)) :
               t < s1 ? mix(c1, c2, (t - s0) / max(s1 - s0, 0.001)) :
               t < s2 ? mix(c2, c3, (t - s1) / max(s2 - s1, 0.001)) :
               t < s3 ? mix(c3, c4, (t - s2) / max(s3 - s2, 0.001)) :
                        mix(c4, c5, (t - s3) / max(1.0 - s3, 0.001));

    col *= 1.0 + density_heat_strength * pow(clamp(d * 0.125, 0.0, 1.0), density_heat_power);

    float redshift_t = 1.0 - 1.0 / (1.0 + grav_redshift_strength * rs / (2.0 * max(r, rs * 0.6)));
    col *= vec3(1.0 + redshift_t * 0.9, 1.0 - redshift_t * 0.4, 1.0 - redshift_t * 0.8);

    float lum = dot(col, vec3(0.2126, 0.7152, 0.0722));
    return mix(vec3(lum), col, color_saturation);
}

void fragment() {
    mat4 inv_view_model = inverse(MODEL_MATRIX) * INV_VIEW_MATRIX;
    vec3 campos = (inv_view_model * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
    vec3 ld = -normalize((inv_view_model * vec4(VIEW, 0.0)).xyz);
    vec3 ld_orig = ld;
    vec3 lp = (inv_view_model * vec4(VERTEX, 1.0)).xyz;
    vec3 cam_dir = normalize(campos);

    vec3 normal_local = normalize((inv_view_model * vec4(NORMAL, 0.0)).xyz);
    float face_amount = clamp(dot(normal_local, normalize(campos - lp)), 0.0, 1.0);
    float warp_weight = pow(face_amount, warp_falloff) * smoothstep(0.0, warp_inner_edge, face_amount);

    vec3 prograde = normalize(cross(SPIN_AXIS, cam_dir));
    float spin_rs = spin * rs;
    float rs_oblate_base = rs * (1.0 - spin * shadow_oblateness * 0.12);

    bool in_bounds = false, prev_in_bounds = false;
    float step_size = 0.05;
    float T = 1.0;
    vec3 L = vec3(0.0);

    for (int i = 0; i < 200; i++) {
        step_size *= 1.005;
        lp += ld * step_size;

        float r = length(lp);
        float r2 = r * r;
        float l = length(lp.xz);

        vec3 lp_n = lp / r;
        float ld_dot = dot(lp_n, ld);
        float r_clamp = clamp(2.0 - 0.5 * r, 0.0, 1.0);
        vec3 la = (-1.5 * rs * pow(1.0 + ld_dot, 3.0) * r_clamp * r_clamp) / (r2 * r2) * lp;
        ld = normalize(ld + (la + frame_drag_strength * spin_rs * cross(SPIN_AXIS, lp) / (max(r, rs) * max(r2, rs * rs))) * step_size);

        float ang = atan(lp.z, lp.x);
        float d = accretion_density(l, ang, lp.y);

        float polar_proj = dot(lp_n, SPIN_AXIS);
        float effective_rs = rs_oblate_base * (1.0 + spin * shadow_asymmetry * 0.18 * dot(lp_n, prograde))
                           + spin * shadow_oblateness * 0.12 * rs * polar_proj * polar_proj;
        T *= exp(-(d + 10.0 * clamp((effective_rs - r) * 2.0 + 1.0, 0.0, 1.0)) * step_size);

        float beta = clamp(sqrt(rs / max(l, rs)) * 0.7, 0.0, 0.85) * doppler_beaming;
        float beaming = pow(max(1.0 + beta * dot(normalize(vec3(-lp.z, 0.0, lp.x)), -cam_dir), 0.01), 4.0);
        L += T * d * temperature_color(l, r, d, ang) * beaming * step_size;

        in_bounds = r < radius;
        if (T <= 0.005 || (!in_bounds && prev_in_bounds)) break;
        prev_in_bounds = in_bounds;
    }

    vec2 deflection = ((INV_VIEW_MATRIX * vec4(ld, 0.0)).xyz - (INV_VIEW_MATRIX * vec4(ld_orig, 0.0)).xyz).xy * 0.5;
    vec2 final_uv = clamp(SCREEN_UV + deflection * warp_weight * warp_strength, vec2(0.001), vec2(0.999));
    ALBEDO = L + T * texture(SCREEN_TEXTURE, final_uv).rgb;
}