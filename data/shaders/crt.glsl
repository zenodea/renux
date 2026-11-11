// CRT: a slight curve to the glass, faint scanlines and edges a little darker. Gentle on
// purpose; raise the numbers below for more. Nothing moves, so it costs nothing between frames.

const float CURVE = 0.10;      // 0 to 0.4: how much the glass bulges
const float SCANLINES = 0.06;  // 0 to 0.5: how dark the scanlines get
const float VIGNETTE = 0.18;   // 0 to 0.25: how dark the edges get

vec2 curve(vec2 uv) {
    uv = uv * 2.0 - 1.0;
    vec2 bend = abs(uv.yx) * CURVE;
    uv = uv + uv * bend * bend;
    return uv * 0.5 + 0.5;
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = curve(fragCoord / iResolution.xy);
    if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
        fragColor = vec4(0.0);
        return;
    }
    vec4 c = texture(iChannel0, uv);
    float scan = 1.0 - SCANLINES * (0.5 + 0.5 * cos(fragCoord.y * 3.14159265 / 1.5));
    vec2 v = uv * (1.0 - uv.yx);
    float vignette = mix(1.0, clamp(pow(v.x * v.y * 16.0, 0.25), 0.0, 1.0), VIGNETTE * 4.0);
    fragColor = vec4(c.rgb * scan * vignette, c.a);
}
