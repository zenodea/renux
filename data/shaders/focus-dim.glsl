// Focus dim: panes without the keyboard fade a little and lose some color, so the one you're
// typing in stands out.

const float DIM = 0.25;        // 0 to 0.8: how much darker the other panes get
const float GREY = 0.5;        // 0 to 1: how much of their color goes

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    if (iFocus == 1) {
        fragColor = c;
        return;
    }
    float light = dot(c.rgb, vec3(0.299, 0.587, 0.114));
    vec3 rgb = mix(c.rgb, vec3(light), GREY) * (1.0 - DIM);
    fragColor = vec4(rgb, c.a);
}
