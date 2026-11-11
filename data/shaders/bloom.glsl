// Bloom: bright text gives off a soft glow, like a screen turned up a little too far.

const float STRENGTH = 0.55;   // how bright the glow is
const float RADIUS = 2.5;      // how far it spreads, in pixels per ring
const float THRESHOLD = 0.45;  // how bright something must be to glow

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 c = texture(iChannel0, uv);
    vec3 glow = vec3(0.0);
    float total = 0.0;
    for (int i = 0; i < 12; i++) {
        float a = float(i) * 0.52359878;
        vec2 dir = vec2(cos(a), sin(a));
        for (int r = 1; r <= 3; r++) {
            vec3 s = texture(iChannel0, uv + dir * float(r) * RADIUS / iResolution.xy).rgb;
            float w = 1.0 / float(r);
            glow += s * smoothstep(THRESHOLD, 1.0, max(s.r, max(s.g, s.b))) * w;
            total += w;
        }
    }
    vec3 rgb = c.rgb + glow / total * STRENGTH;
    float alpha = clamp(max(c.a, max(rgb.r, max(rgb.g, rgb.b))), 0.0, 1.0);
    fragColor = vec4(min(rgb, vec3(alpha)), alpha);
}
