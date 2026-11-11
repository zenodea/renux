// Scanlines: faint dark lines across the pane, as on an old monitor, and nothing else.

const float STRENGTH = 0.08;   // 0 to 0.6: how dark the lines get
const float SPACING = 3.0;     // 2 to 8: pixels from one line to the next

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    float line = 0.5 + 0.5 * cos(fragCoord.y * 6.28318531 / SPACING);
    fragColor = vec4(c.rgb * (1.0 - STRENGTH * line), c.a);
}
