#include <metal_stdlib>
using namespace metal;

// Catmull-Rom reconstruction retains sharp text during magnification. Unlike
// a bilinear-only blur pass, each shutter sample retains its spatial detail.
static float4 cubicWeights(float t) {
    float t2 = t * t;
    float t3 = t2 * t;
    return float4(-0.5f*t + t2 - 0.5f*t3, 1.0f - 2.5f*t2 + 1.5f*t3,
                  0.5f*t + 2.0f*t2 - 1.5f*t3, -0.5f*t2 + 0.5f*t3);
}

static float lanczosWeight(float x) {
    x = abs(x);
    if (x < 0.00001f) return 1;
    if (x >= 2.0f) return 0;
    float a = M_PI_F * x;
    return sin(a) * sin(a * 0.5f) / (a * a * 0.5f);
}

static float4 reconstruct(texture2d<float, access::sample> image, float2 uv, float2 drawSize) {
    constexpr sampler pixelSampler(coord::pixel, address::clamp_to_edge, filter::nearest);
    float2 size = float2(image.get_width(), image.get_height());
    float2 p = uv * size - 0.5f;
    float2 scale = clamp(size / drawSize, 1.0f, 4.0f);
    if (scale.x > 1.0f || scale.y > 1.0f) {
        // Expand the reconstruction footprint when reducing Retina frames:
        // a fixed 4-tap magnification filter would alias one-pixel features.
        int2 low = int2(ceil(p - 2.0f * scale));
        int2 high = int2(floor(p + 2.0f * scale));
        // The Swift renderer bounds the scale to 4, hence at most 17 taps
        // per axis. Reuse horizontal weights instead of recomputing their
        // trigonometric functions for every row of the filter.
        float weightsX[17];
        float totalX = 0;
        for (int x = low.x; x <= high.x; ++x) {
            float weight = lanczosWeight((p.x - float(x)) / scale.x);
            weightsX[x - low.x] = weight;
            totalX += weight;
        }
        float4 color = 0;
        float totalY = 0;
        for (int y = low.y; y <= high.y; ++y) {
            float wy = lanczosWeight((p.y - float(y)) / scale.y);
            float4 row = 0;
            for (int x = low.x; x <= high.x; ++x) {
                row += image.sample(pixelSampler, float2(x, y) + 0.5f) * weightsX[x - low.x];
            }
            color += row * wy;
            totalY += wy;
        }
        return clamp(color / (totalX * totalY), 0.0f, 1.0f);
    }
    float2 origin = floor(p);
    float4 wx = cubicWeights(p.x - origin.x);
    float4 wy = cubicWeights(p.y - origin.y);
    float4 color = 0;
    for (int y = 0; y < 4; ++y) {
        for (int x = 0; x < 4; ++x) {
            color += image.sample(pixelSampler, origin + float2(x - 1, y - 1) + 0.5f) * wx[x] * wy[y];
        }
    }
    return clamp(color, 0.0f, 1.0f);
}

kernel void studioMotionBlur(texture2d<float, access::sample> source [[texture(0)]],
                             texture2d<float, access::read> backdrop [[texture(1)]],
                             texture2d<float, access::read> clip [[texture(2)]],
                             texture2d<float, access::write> output [[texture(3)]],
                             constant float4 *rects [[buffer(0)]],
                             constant uint &count [[buffer(1)]],
                             uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    float4 result = backdrop.read(pixel);
    float coverage = clip.read(pixel).a;
    float2 center = float2(pixel) + 0.5f;
    if (coverage > 0) {
        for (uint i = 0; i < count; ++i) {
            float4 rect = rects[i];
            float2 edge = clamp(min(center - rect.xy, rect.xy + rect.zw - center) + 0.5f, 0.0f, 1.0f);
            float opacity = coverage * edge.x * edge.y / float(i + 1);
            if (opacity == 0) continue;
            float4 value = reconstruct(source, (center - rect.xy) / rect.zw, rect.zw);
            // Match the existing premultiplied source-over running average
            // in encoded sRGB bytes, including 8-bit rounding after each draw.
            result = round(clamp(value * opacity + result * (1.0f - value.a * opacity), 0.0f, 1.0f) * 255.0f) / 255.0f;
        }
    }
    output.write(result, pixel);
}

// MARK: - Layout morphs
//
// While a layout morphs, the card and camera change shape every frame, so
// their clips and shadows can't be cached. Both are computed here from the
// shape instead of drawn by Core Graphics on the CPU at canvas size.

// Abramowitz & Stegun 7.1.26; Metal has no erf.
static float erfApprox(float x) {
    float s = sign(x);
    x = abs(x);
    float t = 1.0f / (1.0f + 0.3275911f * x);
    float y = 1.0f - (((((1.061405429f * t - 1.453152027f) * t) + 1.421413741f) * t - 0.284496736f) * t
                      + 0.254829592f) * t * exp(-x * x);
    return s * y;
}

// Signed distance to a rounded rect (x, y, width, height), negative inside.
static float roundedRectDistance(float2 p, float4 rect, float radius) {
    float2 halfSize = rect.zw * 0.5f;
    float r = min(radius, min(halfSize.x, halfSize.y));
    float2 q = abs(p - rect.xy - halfSize) - halfSize + r;
    return length(max(q, 0.0f)) + min(max(q.x, q.y), 0.0f) - r;
}

// Core Graphics' shadow blur is a Gaussian with sigma = blur / 2, cut off
// at about 1.05 x blur. `shadow` is (offsetDown, sigma, cutoff, alpha).
// The fraction of the kernel below x:
static float shadowCDF(float x, float sigma, float cutoff) {
    float scale = 1.0f / (sigma * M_SQRT2_F);
    return 0.5f + 0.5f * erfApprox(clamp(x, -cutoff, cutoff) * scale) / erfApprox(cutoff * scale);
}

// Alpha of a rounded rect's blurred shadow at p, before the shadow's own
// alpha: exact across each row, integrated numerically down the column
// (after Evan Wallace's rounded-box shadow).
static float roundedRectShadow(float2 p, float4 rect, float radius, float sigma, float cutoff) {
    float2 halfSize = rect.zw * 0.5f;
    float corner = min(radius, min(halfSize.x, halfSize.y));
    p -= rect.xy + halfSize;
    float start = clamp(-cutoff, p.y - halfSize.y, p.y + halfSize.y);
    float end = clamp(cutoff, p.y - halfSize.y, p.y + halfSize.y);
    if (end <= start) return 0;
    constexpr int steps = 16;
    float step = (end - start) / float(steps);
    float scale = 1.0f / (sigma * M_SQRT2_F);
    float norm = erfApprox(cutoff * scale) * sigma * sqrt(2.0f * M_PI_F);
    float value = 0;
    for (int i = 0; i < steps; ++i) {
        float y = start + (float(i) + 0.5f) * step;
        float row = p.y - y;
        float delta = min(halfSize.y - corner - abs(row), 0.0f);
        float curved = halfSize.x - corner + sqrt(max(0.0f, corner * corner - delta * delta));
        float across = shadowCDF(p.x + curved, sigma, cutoff) - shadowCDF(p.x - curved, sigma, cutoff);
        value += across * exp(-y * y / (2.0f * sigma * sigma));
    }
    return clamp(value * step / norm, 0.0f, 1.0f);
}

static float4 castShadow(float4 below, float2 center, float4 rect, float radius, float4 shadow) {
    if (shadow.w <= 0) return below;
    float alpha = shadow.w * roundedRectShadow(center - float2(0, shadow.x), rect, radius, shadow.y, shadow.z);
    return below * (1.0f - alpha);
}

// The screen pass for a frame inside a morph: the plain background, the
// card's shadow, then the shutter samples clipped to the card.
// shape[0] is the card rect; shape[1] is (radius, opacity, -, -); shape[2]
// is its shadow.
kernel void studioMorphScreen(texture2d<float, access::sample> source [[texture(0)]],
                              texture2d<float, access::read> backdrop [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant float4 *rects [[buffer(0)]],
                              constant uint &count [[buffer(1)]],
                              constant float4 *shape [[buffer(2)]],
                              uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    float2 center = float2(pixel) + 0.5f;
    float4 card = shape[0];
    float radius = shape[1].x;
    float4 result = castShadow(backdrop.read(pixel), center, card, radius, shape[2]);
    float coverage = clamp(0.5f - roundedRectDistance(center, card, radius), 0.0f, 1.0f) * shape[1].y;
    if (coverage > 0) {
        for (uint i = 0; i < count; ++i) {
            float4 rect = rects[i];
            float2 edge = clamp(min(center - rect.xy, rect.xy + rect.zw - center) + 0.5f, 0.0f, 1.0f);
            float opacity = coverage * edge.x * edge.y / float(i + 1);
            if (opacity == 0) continue;
            float4 value = reconstruct(source, (center - rect.xy) / rect.zw, rect.zw);
            result = round(clamp(value * opacity + result * (1.0f - value.a * opacity), 0.0f, 1.0f) * 255.0f) / 255.0f;
        }
    }
    output.write(result, pixel);
}

// The camera inside a morph, over a copy of the finished frame beneath it:
// its shadow, the aspect-filled shutter samples clipped to the bubble, and
// the hairline border, over only the region at `shape[3].xy`.
// shape[0] is the bubble; shape[1] is (radius, opacity, borderWidth,
// borderAlpha); shape[2] its shadow; shape[3].xy the region's origin.
kernel void studioMorphCamera(texture2d<float, access::sample> camera [[texture(0)]],
                              texture2d<float, access::read> below [[texture(1)]],
                              texture2d<float, access::write> output [[texture(2)]],
                              constant float4 *rects [[buffer(0)]],
                              constant uint &count [[buffer(1)]],
                              constant float4 *shape [[buffer(2)]],
                              uint2 position [[thread_position_in_grid]]) {
    uint2 pixel = position + uint2(shape[3].xy);
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    float2 center = float2(pixel) + 0.5f;
    float4 bubble = shape[0];
    float radius = shape[1].x;
    float opacity = shape[1].y;
    float4 result = castShadow(below.read(pixel), center, bubble, radius, shape[2]);
    float coverage = clamp(0.5f - roundedRectDistance(center, bubble, radius), 0.0f, 1.0f);
    if (coverage > 0) {
        for (uint i = 0; i < count; ++i) {
            float4 rect = rects[i];
            float2 edge = clamp(min(center - rect.xy, rect.xy + rect.zw - center) + 0.5f, 0.0f, 1.0f);
            // Sample i at 1/(i+1) keeps the running average; the first
            // carries the fade.
            float alpha = coverage * edge.x * edge.y * (i == 0 ? opacity : 1.0f / float(i + 1));
            if (alpha == 0) continue;
            float4 value = reconstruct(camera, (center - rect.xy) / rect.zw, rect.zw);
            result = clamp(value * alpha + result * (1.0f - value.a * alpha), 0.0f, 1.0f);
        }
    }
    // A stroke centred on the bubble inset by halfSize a pixel.
    float width = shape[1].z;
    float4 inset = bubble + float4(0.5f, 0.5f, -1.0f, -1.0f);
    float border = clamp(width * 0.5f + 0.5f - abs(roundedRectDistance(center, inset, radius)), 0.0f, 1.0f)
        * shape[1].w;
    result = result * (1.0f - border) + float4(border);
    output.write(result, pixel);
}

// MARK: - Camera cutout
//
// The person, cut out of the camera's background by Vision's person
// segmentation. The matte is a few hundred pixels across, so it's sampled
// bilinearly and its soft edge pulled into a tight one here, at whatever
// size the camera is drawn: an upscaled matte stays crisp instead of
// growing a halo of the room behind.

constant float cutoutEdgeLow = 0.45f;
constant float cutoutEdgeHigh = 0.85f;

// Fades the picture out toward each edge that stands inside the canvas, so
// shoulders running off the camera's frame soften away instead of ending
// in a straight cut. `feather` is (left, right, top, bottom) as fractions of
// the picture; 0 leaves an edge the canvas already crops.
static float cutoutFeather(float2 uv, float4 feather) {
    float fade = 1.0f;
    if (feather.x > 0) fade *= smoothstep(0.0f, feather.x, uv.x);
    if (feather.y > 0) fade *= smoothstep(0.0f, feather.y, 1.0f - uv.x);
    if (feather.z > 0) fade *= smoothstep(0.0f, feather.z, uv.y);
    if (feather.w > 0) fade *= smoothstep(0.0f, feather.w, 1.0f - uv.y);
    return fade;
}

// The person's shadow source: the refined matte, resampled to the
// picture's own aspect (Vision's matte is 4:3 whatever the camera) so the
// blur that follows is round.
kernel void studioCutoutShadowSource(texture2d<float, access::sample> matte [[texture(0)]],
                                     texture2d<float, access::write> output [[texture(1)]],
                                     uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 uv = (float2(pixel) + 0.5f) / float2(output.get_width(), output.get_height());
    float person = smoothstep(cutoutEdgeLow, cutoutEdgeHigh, matte.sample(linear, uv).r);
    output.write(float4(person), pixel);
}

// The camera on its way to (or settled as) a cutout: `studioMorphCamera`
// with the background melting away by `cutout`, and the framed camera's
// shadow and border giving way to one the person casts.
// shape[0] is the bubble; shape[1] is (radius, opacity, borderWidth,
// borderAlpha); shape[2] the framed shadow; shape[3] is (regionX, regionY,
// cutout, hasBelow); shape[4] the feather; shape[5] is the person's shadow
// (offsetDown as a fraction of the picture, alpha, -, -); shape[6] the
// picture the shadow lands on, where the whole camera frame is drawn.
// Without `hasBelow` it draws over nothing, for the preview's own layer.
kernel void studioCutoutCamera(texture2d<float, access::sample> camera [[texture(0)]],
                               texture2d<float, access::read> below [[texture(1)]],
                               texture2d<float, access::write> output [[texture(2)]],
                               texture2d<float, access::sample> matte [[texture(3)]],
                               texture2d<float, access::sample> shadowMatte [[texture(4)]],
                               constant float4 *rects [[buffer(0)]],
                               constant uint &count [[buffer(1)]],
                               constant float4 *shape [[buffer(2)]],
                               uint2 position [[thread_position_in_grid]]) {
    uint2 pixel = position + uint2(shape[3].xy);
    if (pixel.x >= output.get_width() || pixel.y >= output.get_height()) return;
    constexpr sampler linear(coord::normalized, address::clamp_to_edge, filter::linear);
    float2 center = float2(pixel) + 0.5f;
    float4 bubble = shape[0];
    float radius = shape[1].x;
    float opacity = shape[1].y;
    float cutout = shape[3].z;
    float4 feather = shape[4];
    float4 result = shape[3].w > 0 ? below.read(pixel) : float4(0);
    result = castShadow(result, center, bubble, radius, shape[2]);
    if (shape[5].y > 0) {
        float4 picture = shape[6];
        float2 uv = (center - picture.xy) / picture.zw - float2(0, shape[5].x);
        float inside = all(uv >= 0.0f) && all(uv <= 1.0f) ? 1.0f : 0.0f;
        float cast = shape[5].y * shadowMatte.sample(linear, uv).r * cutoutFeather(uv, feather) * inside;
        // Black at `cast` over the frame: over an opaque frame the same as
        // darkening it, and it still shows over the preview's clear layer.
        result = result * (1.0f - cast) + float4(0, 0, 0, cast);
    }
    float coverage = clamp(0.5f - roundedRectDistance(center, bubble, radius), 0.0f, 1.0f);
    if (coverage > 0) {
        for (uint i = 0; i < count; ++i) {
            float4 rect = rects[i];
            float2 edge = clamp(min(center - rect.xy, rect.xy + rect.zw - center) + 0.5f, 0.0f, 1.0f);
            float2 uv = (center - rect.xy) / rect.zw;
            float person = cutout > 0
                ? smoothstep(cutoutEdgeLow, cutoutEdgeHigh, matte.sample(linear, uv).r) * cutoutFeather(uv, feather)
                : 1.0f;
            // Sample i at 1/(i+1) keeps the running average; the first
            // carries the fade.
            float alpha = coverage * edge.x * edge.y * mix(1.0f, person, cutout)
                * (i == 0 ? opacity : 1.0f / float(i + 1));
            if (alpha == 0) continue;
            float4 value = reconstruct(camera, uv, rect.zw);
            result = clamp(value * alpha + result * (1.0f - value.a * alpha), 0.0f, 1.0f);
        }
    }
    float width = shape[1].z;
    float4 inset = bubble + float4(0.5f, 0.5f, -1.0f, -1.0f);
    float border = clamp(width * 0.5f + 0.5f - abs(roundedRectDistance(center, inset, radius)), 0.0f, 1.0f)
        * shape[1].w;
    result = result * (1.0f - border) + float4(border);
    output.write(result, pixel);
}
