#version 440
// Cassette Futurism CRT pass.
//
// Everything the plot draws -- grid, trails, HUD, text -- is rendered into one
// texture, then pushed through this: barrel distortion, scanlines that follow
// the curve of the tube, an optional shadow mask, edge vignette, and a little
// chromatic fringing that grows toward the edges as it does on real glass.
//
// Rebuild after editing:
//   /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 -o crt.frag.qsb crt.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    float curvature;      // barrel strength, same meaning as crt.curvature
    float scanAlpha;      // 0 = no scanlines
    float scanPitch;      // logical px between scanlines
    float maskAlpha;      // 0 = no shadow mask
    float vignetteAlpha;
    float vignetteSpread; // fraction of the screen the falloff covers
    float aberration;     // logical px of R/B split at the very edge
    vec2 resolution;      // item size in logical px
};

layout(binding = 1) uniform sampler2D source;

// Output -> source. The plot convention pushes content OUTWARD by
// (1 + k r^2), so to find what lands on an output pixel we invert that,
// by fixed-point iteration; four rounds is plenty at these strengths.
vec2 unwarp(vec2 o) {
    vec2 n = o;
    for (int i = 0; i < 4; i++) {
        n = o / (1.0 + curvature * dot(n, n));
    }
    return n;
}

void main() {
    vec2 o = qt_TexCoord0 * 2.0 - 1.0;
    vec2 s = unwarp(o);
    vec2 uv = s * 0.5 + 0.5;

    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0);
        return;
    }

    // Radial R/B split, zero at the centre.
    vec2 split = s * aberration / resolution;
    vec4 c = texture(source, uv);
    c.r = texture(source, uv + split).r;
    c.b = texture(source, uv - split).b;

    // Scanlines in SOURCE space, so they bend with the tube. A narrowed
    // cosine rather than a hard 1px step: a hard edge resampled through the
    // warp aliases into moire bands.
    float PI2 = 6.2831853;
    float sy = uv.y * resolution.y;
    float scan = smoothstep(0.35, 1.0, 0.5 + 0.5 * cos(PI2 * sy / scanPitch));
    float sx = uv.x * resolution.x;
    float mask = smoothstep(0.35, 1.0, 0.5 + 0.5 * cos(PI2 * sx / scanPitch));
    float lum = (1.0 - scanAlpha * scan) * (1.0 - maskAlpha * mask);

    // Edge falloff, compounding in the corners like a tube does.
    vec2 e = min(uv, 1.0 - uv);
    float v = smoothstep(0.0, vignetteSpread * 0.8, e.x) * smoothstep(0.0, vignetteSpread, e.y);
    lum *= mix(1.0 - vignetteAlpha, 1.0, v);

    // Premultiplied: scale the whole pixel so it darkens over the black
    // ground instead of turning translucent.
    fragColor = c * lum * qt_Opacity;
}
