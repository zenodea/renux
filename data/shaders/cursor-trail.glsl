// Cursor trail: when the cursor jumps, a smear in its color follows it from where it was and
// fades. Moves of a single character, as when typing, leave no trail.

const float DURATION = 0.22;   // seconds the trail takes to fade
const float OPACITY = 0.6;
const float MIN_JUMP = 1.5;    // in cursor heights; shorter moves leave no trail

float segment(vec2 p, vec2 a, vec2 b) {
    vec2 pa = p - a;
    vec2 ba = b - a;
    float h = clamp(dot(pa, ba) / max(dot(ba, ba), 0.0001), 0.0, 1.0);
    return length(pa - ba * h);
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
    vec2 now = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5, iCurrentCursor.y - iCurrentCursor.w * 0.5);
    vec2 before = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5, iPreviousCursor.y - iPreviousCursor.w * 0.5);
    if (length(now - before) < iCurrentCursor.w * MIN_JUMP) {
        fragColor = c;
        return;
    }
    // The tail catches up with the head, quickly at first.
    float ease = 1.0 - pow(1.0 - t, 3.0);
    vec2 tail = mix(before, now, ease);
    float thickness = iCurrentCursor.w * 0.4;
    float d = segment(fragCoord, tail, now);
    float amount = (1.0 - smoothstep(thickness - 1.0, thickness + 1.0, d)) * (1.0 - t) * OPACITY;
    fragColor = over(c, iCurrentCursorColor.rgb, amount);
}
