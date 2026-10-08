#version 440

// Oil-slick tint for the dark parts of the wallpaper.
// No pattern of its own: the hue comes from the picture's broad light and dark
// (a heavily blurred sample) plus a slow drift, so the colour follows the
// drawing. The ink keeps its own darkness; only its hue changes. The music
// sets how much colour there is, and onsets make it breathe.
// Output is premultiplied: the tinted ink at partial coverage.

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float hue;        // slow palette drift, nudged by the highs
    float bass;
    float mids;
    float level;
    float beat;       // 1 on an onset, decays
    float intensity;  // overall fade (presence * strength)
    float darkLo;     // luminance that gets the full effect
    float darkHi;     // dark/light split of this wallpaper
    vec2 cropScale;   // screen uv -> image uv (PreserveAspectCrop)
    vec2 cropOffset;
};

layout(binding = 1) uniform sampler2D wall;

const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);

vec3 rainbow(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (t + vec3(0.0, 0.33, 0.67)));
}

void main() {
    vec2 uv = qt_TexCoord0 * cropScale + cropOffset;
    float lum = dot(texture(wall, uv).rgb, LUMA);
    float broad = dot(textureLod(wall, uv, 6.0).rgb, LUMA);

    float span = max(darkHi - darkLo, 0.02);
    float mask = 1.0 - smoothstep(darkLo, darkHi + span * 0.25 * level, lum);

    float h = hue + broad * 2.5 + qt_TexCoord0.x * 0.35 + qt_TexCoord0.y * 0.15 + bass * 0.08;
    vec3 c = rainbow(h);
    vec3 tint = mix(vec3(dot(c, vec3(0.3333))), c, 0.55 + 0.4 * mids);
    vec3 inked = tint * (lum * 1.8 + 0.04);

    float amt = intensity * mask * (0.06 + 0.24 * level + 0.1 * beat);
    fragColor = vec4(inked * amt, amt) * qt_Opacity;
}
