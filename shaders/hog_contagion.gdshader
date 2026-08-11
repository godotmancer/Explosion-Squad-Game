shader_type spatial;

// Hog material for SquadMultiMeshInstance3D.
//
// Replaces a StandardMaterial3D that had vertex_color_use_as_albedo enabled. That flag can
// only ever multiply ALBEDO, so an out-of-range instance colour just made a hog a brighter
// shade of its own albedo: still lighting-dependent (dim again the moment it walked into
// shadow) and then squashed by the AgX tonemapper. Here the instance colour written by
// physics_compute.glsl is split instead:
//
//   * the part inside the display range tints ALBEDO exactly as the old material did
//   * everything above 1.0 becomes EMISSION, which is unlit and so blooms through the
//     WorldEnvironment's HDR glow (glow_hdr_threshold) whatever the lighting on the hog
//
// The split renormalises by the largest channel instead of clamping per channel, so the
// albedo tint keeps the contagion's hue rather than drifting toward white as the HDR gain
// rises. A colour with every channel <= 1.0 — which is every healthy hog, at pure white —
// takes the same path as before: full albedo, zero emission.

uniform vec4 albedo : source_color = vec4(0.89081144, 0.5641828, 0.24339655, 1.0);
// Multiplier on the out-of-range remainder only. Tune the bloom here rather than in
// physics_compute.glsl: this is a uniform, those are compile-time constants in a compute
// shader that also has to keep its buffer layout in sync with three other files.
uniform float glow_energy : hint_range(0.0, 8.0) = 1.0;

void fragment() {
  vec3 c = COLOR.rgb;
  float peak = max(max(c.r, c.g), c.b);
  // For peak <= 1.0 this is c untouched, so nothing changes for uninfected hogs.
  vec3 in_range = peak > 1.0 ? c / peak : c;

  ALBEDO = albedo.rgb * in_range;
  // c - in_range == c * (1.0 - 1.0 / peak): the out-of-range remainder, same hue as the tint.
  EMISSION = max(c - in_range, vec3(0.0)) * glow_energy;
}
