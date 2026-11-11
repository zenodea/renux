// Amber: everything in the warm orange of an old phosphor terminal, with faint scanlines.

const vec3 PHOSPHOR = vec3(1.0, 0.68, 0.24);   // try vec3(0.35, 1.0, 0.45) for green
const float SCANLINES = 0.07;  // 0 to 0.5: how dark the scanlines get

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    float light = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    float scan = 1.0 - SCANLINES * (0.5 + 0.5 * cos(fragCoord.y * 3.14159265 / 1.5));
    vec3 rgb = PHOSPHOR * light * 1.2 * scan;
    fragColor = vec4(min(rgb, vec3(c.a)), c.a);
}
