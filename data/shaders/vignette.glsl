// Vignette: the pane's edges fade a little darker, which draws the eye to the middle.

const float STRENGTH = 0.35;   // 0 to 1: how dark the corners get
const float SOFTNESS = 0.55;   // 0.2 to 1.2: how far in the fade starts

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec2 uv = fragCoord / iResolution.xy;
    vec4 c = texture(iChannel0, uv);
    vec2 d = (uv - 0.5) * vec2(iResolution.x / iResolution.y, 1.0);
    float fade = 1.0 - STRENGTH * smoothstep(SOFTNESS * 0.5, SOFTNESS * 1.3, length(d));
    fragColor = vec4(c.rgb * fade, c.a);
}
