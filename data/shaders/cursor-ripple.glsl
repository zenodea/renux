// Cursor ripple: when the cursor jumps, a ring in its color spreads out from where it landed
// and fades. Moves of a single character, as when typing, make no ripple.

const float DURATION = 0.4;    // seconds the ring lasts
const float SIZE = 2.5;        // how wide it grows, in cursor heights
const float OPACITY = 0.6;
const float MIN_JUMP = 1.5;    // in cursor heights; shorter moves make no ripple

vec4 over(vec4 base, vec3 color, float amount) {
    return vec4(color * amount + base.rgb * (1.0 - amount), amount + base.a * (1.0 - amount));
}

void mainImage(out vec4 fragColor, in vec2 fragCoord) {
    vec4 c = texture(iChannel0, fragCoord / iResolution.xy);
    float t = (iTime - iTimeCursorChange) / DURATION;
    if (iCursorVisible == 0 || t >= 1.0 || iCurrentCursor.w <= 0.0) {
        fragColor = c;
        return;
    }
    vec2 now = vec2(iCurrentCursor.x + iCurrentCursor.z * 0.5, iCurrentCursor.y - iCurrentCursor.w * 0.5);
    vec2 before = vec2(iPreviousCursor.x + iPreviousCursor.z * 0.5, iPreviousCursor.y - iPreviousCursor.w * 0.5);
    if (iPreviousCursor.w <= 0.0 || length(now - before) < iCurrentCursor.w * MIN_JUMP) {
        fragColor = c;
        return;
    }
    float ease = 1.0 - pow(1.0 - t, 2.0);
    float radius = ease * iCurrentCursor.w * SIZE;
    float ring = 1.0 - smoothstep(0.0, 2.0, abs(length(fragCoord - now) - radius));
    fragColor = over(c, iCurrentCursorColor.rgb, ring * (1.0 - t) * OPACITY);
}
