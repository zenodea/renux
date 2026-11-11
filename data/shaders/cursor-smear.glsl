// Cursor smear: when the cursor moves, its own box stretches from where it was to where it
// is, and the tail snaps in behind it, as in Neovide. Moving to another pane smears across.

const float DURATION = 0.12;   // 0.03 to 0.5: seconds the tail takes to catch up
const float OPACITY = 0.85;    // 0 to 1: how solid the smear is
const float MIN_JUMP = 0.0;    // 0 to 5: in cursor heights; shorter moves don't smear

float box(vec2 p, vec2 extent) {
    vec2 d = abs(p) - extent;
    return length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);
}

// Distance to the cursor's box swept from a to b: the nearest it comes along the way. It only
// falls then rises along the way, so narrowing in from both ends finds it.
float swept(vec2 p, vec2 a, vec2 b, vec2 extent) {
    float lo = 0.0;
    float hi = 1.0;
    for (int i = 0; i < 16; i++) {
        float m1 = lo + (hi - lo) / 3.0;
        float m2 = hi - (hi - lo) / 3.0;
        if (box(p - mix(a, b, m1), extent) < box(p - mix(a, b, m2), extent)) hi = m2; else lo = m1;
    }
    return box(p - mix(a, b, (lo + hi) * 0.5), extent);
}

vec4 over(vec4 base, vec3 color, float amount) {
    return vec4(color * amount + base.rgb * (1.0 - amount), amount + base.a * (1.0 - amount));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    float t = (iTime - iTimeCursorChange) / DURATION;
    if (iCursorVisible == 0 || t >= 1.0 || iPreviousCursor.w <= 0.0 || iCurrentCursor.w <= 0.0) {
        fragColor = c;
        return;
    }
    vec2 extent = iCurrentCursor.zw * 0.5;
    vec2 now = vec2(iCurrentCursor.x, iCurrentCursor.y) + vec2(extent.x, -extent.y);
    vec2 before = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5, iPreviousCursor.y - iPreviousCursor.w * 0.5);
    if (length(now - before) < iCurrentCursor.w * MIN_JUMP) {
        fragColor = c;
        return;
    }
    // The tail catches up with the head, quickly at first.
    float ease = 1.0 - pow(1.0 - t, 3.0);
    vec2 tail = mix(before, now, ease);
    float d = swept(fragCoord, tail, now, extent);
    // Over the cursor's own box too, so the smear and the cursor are one shape while it moves
    // rather than two that meet at an edge each drew on its own.
    float amount = (1.0 - smoothstep(-0.5, 0.5, d)) * OPACITY;
    fragColor = over(c, iCurrentCursorColor.rgb, amount);
}
