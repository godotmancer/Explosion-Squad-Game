shader_type canvas_item;

// from: https://youtu.be/_2UFFFRKDqw?si=PCLdJuo3bxRxAY4Z
// I added screen texture for 3D processing using a ColorRect

uniform sampler2D screen_texture : hint_screen_texture, repeat_disable, filter_nearest;

uniform float noise_speed : hint_range(10.0, 10000.0, 1.0) = 1000.0;
uniform float noise_power : hint_range(0.0, 5.0, 0.01) = 1.0;
uniform float vertical_speed : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float vertical_shift : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float ghost_speed : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float ghost_power : hint_range(0.0, 1.0, 0.01) = 0.2;
uniform float chromatic_shift : hint_range(0.0, 1.0, 0.1) = 0.5;
uniform float chromatic_dist : hint_range(0.0, 10.0, 0.01) = 5.0;
uniform float vignette_radius : hint_range(0.0, 10.0, 0.01) = 2.0;
uniform float vignette_power : hint_range(0.0, 10.0, 0.01) = 5.0;

float hash12(vec2 x) {
  return fract(cos(mod(dot(x, vec2(13.9898, 8.141)), PI))*43758.5453)*2.0-1.0;
}

float noise(vec2 p) {
  vec2 i = floor(p);
  vec2 f = fract(p);
  vec2 u = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash12(i + vec2(0.0, 0.0)),
    hash12(i + vec2(1.0, 0.0)), u.x),
    mix(hash12(i + vec2(0.0, 1.0)),
    hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

void add_noise(vec2 uv, inout vec4 color) {
  float noise_x = (uv.y + TIME) * noise_speed;
  float noise_y = (uv.x + noise_speed) / uv.y * 20.0;
  float fluctuations = (sin(TIME) + 1.0) * 0.1 + 0.5;
  color += noise_power * noise(vec2(noise_x, noise_y)) * fluctuations;
}

void add_movement(inout vec2 uv) {
  float shift_noise = step(noise(vec2(TIME * 0.5, 0)) * 0.5 + 0.5, vertical_shift);
  uv.y += mix(0.0, sin(TIME * vertical_speed), shift_noise);
  uv.y = fract(uv.y);
}

void add_ghosts(inout vec2 uv) {
  float ghost_noise = step(hash12(vec2(uv.x + sin(TIME), uv.y)), ghost_power - 1.0);
  float ghost_cycle = sin(TIME * ghost_speed) * 0.5;
  uv.x += mix(0.0, ghost_cycle, ghost_noise);
  uv.y += mix(0.0, ghost_cycle * 0.2, ghost_noise);
}

void add_aberration(sampler2D tex, vec2 uv, inout vec4 color) {
  float chromatic = chromatic_shift * 0.01;
  color.r += texture(tex, uv + vec2(-chromatic, 0.0)).r;
  color.g += texture(tex, uv).g;
  color.b += texture(tex, uv + vec2(chromatic, 0.0)).b;
}

void add_distortion(vec2 uv, inout vec4 color) {
  color.rgb += dFdx(color.rgb) * vec3(-chromatic_dist, 0.0, chromatic_dist);
}

void add_vignette(vec2 uv, inout vec4 color) {
  float xx = 2.0 * uv.x - 1.0;
  float yy = 2.0 * uv.y - 1.0;
  float vignette = (xx * xx + yy * yy) / vignette_radius;
  color *= 1.0 - pow(vignette, vignette_power);
}

void fragment() {
  vec2 uv = SCREEN_UV;
  vec4 color = vec4(0.0);
  add_noise(uv, color);
  add_movement(uv);
  add_ghosts(uv);
  add_aberration(TEXTURE, uv, color);
  add_distortion(uv, color);
  add_vignette(uv, color);
  COLOR = color + textureLod(screen_texture, uv, 0.0);
}
