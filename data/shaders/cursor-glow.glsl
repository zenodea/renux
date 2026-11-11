// Cursor glow: a soft halo in the cursor's own color, and nothing else changes. It doesn't
// move, so it costs nothing between frames.

const float STRENGTH = 0.35;   // how bright the halo is
const float SIZE = 1.0;        // how far it reaches, in cursor heights

vec4 addLight(vec4 base, vec3 color, float amount) {
    float alpha = base.a + amount * (1.0 - base.a);
    return vec4(min(base.rgb + color * amount, vec3(alpha)), alpha);
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    if (iCursorVisible == 0 || iCurrentCursor.w <= 0.0) {
        fragColor = c;
        return;
    }
    vec2 extent = iCurrentCursor.zw * 0.5;
    vec2 center = vec2(iCurrentCursor.x + extent.x, iCurrentCursor.y - extent.y);
    float dist = length(max(abs(fragCoord - center) - extent, 0.0));
    float reach = iCurrentCursor.w * SIZE;
    float glow = dist > 0.0 ? exp(-(dist * dist) / (reach * reach * 0.3)) * STRENGTH : 0.0;
    fragColor = addLight(c, iCurrentCursorColor.rgb, glow);
}
