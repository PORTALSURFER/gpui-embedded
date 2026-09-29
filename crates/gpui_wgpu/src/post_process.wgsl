struct WaterEffect {
    region: vec4<f32>,
    hover: vec4<f32>,
    impact: vec4<f32>,
    wakes: array<vec4<f32>, 4>,
};

@group(0) @binding(0) var scene: texture_2d<f32>;
@group(0) @binding(1) var scene_sampler: sampler;
@group(0) @binding(2) var<uniform> effect: WaterEffect;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_fullscreen(@builtin(vertex_index) index: u32) -> VertexOut {
    let positions = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -1.0),
        vec2<f32>(3.0, -1.0),
        vec2<f32>(-1.0, 3.0),
    );
    var output: VertexOut;
    output.position = vec4<f32>(positions[index], 0.0, 1.0);
    output.uv = vec2<f32>((positions[index].x + 1.0) * 0.5, (1.0 - positions[index].y) * 0.5);
    return output;
}

fn add_wave(pixel: vec2<f32>, center: vec2<f32>, radius: f32, width: f32, power: f32) -> vec3<f32> {
    let delta = pixel - center;
    let distance = max(length(delta), 1.0);
    let envelope = exp(-pow((distance - radius) / width, 2.0)) * power;
    let displacement = cos((distance - radius) * 0.09) * envelope * 5.0;
    return vec3<f32>(delta / distance * displacement, envelope);
}

@fragment
fn fs_water(input: VertexOut) -> @location(0) vec4<f32> {
    let original = textureSampleLevel(scene, scene_sampler, input.uv, 0.0);
    if (input.uv.x < effect.region.x || input.uv.y < effect.region.y ||
        input.uv.x > effect.region.z || input.uv.y > effect.region.w) {
        return original;
    }

    let dimensions = vec2<f32>(textureDimensions(scene));
    let pixel = input.uv * dimensions;
    var displacement = vec2<f32>(0.0);
    var strength = 0.0;

    if (effect.hover.z > 0.5) {
        let radius = 28.0 + sin(effect.hover.w * 2.2) * 7.0;
        let wave = add_wave(pixel, effect.hover.xy * dimensions, radius, 55.0, 0.48);
        displacement += wave.xy;
        strength += wave.z;
    }
    for (var i = 0u; i < 4u; i += 1u) {
        let wake = effect.wakes[i];
        if (wake.w > 0.0 && wake.z < 1.2) {
            let power = pow(max(1.0 - wake.z / 1.2, 0.0), 2.0) * wake.w * 0.48;
            let wave = add_wave(pixel, wake.xy * dimensions, wake.z * 105.0, 38.0, power);
            displacement += wave.xy;
            strength += wave.z;
        }
    }
    if (effect.impact.w > 0.5 && effect.impact.z < 1.15) {
        let age = effect.impact.z;
        let power = pow(max(1.0 - age / 1.15, 0.0), 2.0) * 1.7;
        let wave = add_wave(pixel, effect.impact.xy * dimensions, age * 185.0, 34.0, power);
        displacement += wave.xy;
        strength += wave.z;
    }
    if (strength < 0.001) {
        return original;
    }

    let region_min = effect.region.xy * dimensions + vec2<f32>(1.0);
    let region_max = effect.region.zw * dimensions - vec2<f32>(1.0);
    let edge_distance = min(min(pixel.x - region_min.x, region_max.x - pixel.x),
                            min(pixel.y - region_min.y, region_max.y - pixel.y));
    let edge_fade = smoothstep(0.0, 12.0, edge_distance);
    let shifted = clamp(pixel - clamp(displacement, vec2<f32>(-7.0), vec2<f32>(7.0)) * edge_fade,
                        region_min, region_max);
    let direction = normalize(displacement + vec2<f32>(0.001, 0.001));
    let fringe = direction * min(strength, 1.0) * edge_fade * 1.4;
    let red = textureSampleLevel(scene, scene_sampler, clamp((shifted + fringe) / dimensions,
                                                         effect.region.xy, effect.region.zw), 0.0);
    let green = textureSampleLevel(scene, scene_sampler, shifted / dimensions, 0.0);
    let blue = textureSampleLevel(scene, scene_sampler, clamp((shifted - fringe) / dimensions,
                                                          effect.region.xy, effect.region.zw), 0.0);
    let refracted = vec4<f32>(red.r, green.g, blue.b, green.a);
    return mix(original, refracted, edge_fade);
}

// Stable screen-space nodes: the grid never translates. Each node grows near
// an active blob, then its brightness fades with the trailing wake.
fn signal_dots(pixel: vec2<f32>, center: vec2<f32>, reach: f32, weight: f32) -> f32 {
    let cell = floor(pixel / 16.0);
    let node = (cell + vec2<f32>(0.5)) * 16.0;
    let distance = length((node - center) * vec2<f32>(1.0, 1.15));
    let field = exp(-pow(distance / reach, 2.0));
    let radius = 0.75 + field * 5.0;
    let dot = 1.0 - smoothstep(radius - 0.7, radius + 0.7, length(pixel - node));
    return dot * field * weight;
}

// Soft, asymmetric lensing gives each influence the shape of a liquid blob.
fn liquid_blob(pixel: vec2<f32>, center: vec2<f32>, axes: vec2<f32>,
               weight: f32, phase: f32) -> vec3<f32> {
    let local = (pixel - center) / axes;
    let cloud = exp(-dot(local, local) * 1.45) * weight;
    let flow = vec2<f32>(local.x + sin(local.y * 2.0 + phase) * 0.24,
                         local.y + cos(local.x * 1.8 - phase) * 0.20);
    return vec3<f32>(flow * cloud * 11.0, cloud);
}

// The signal shader blurs and refracts the framebuffer under broad, fading
// liquid lenses. The regular dot grid is composited afterward and stays sharp.
@fragment
fn fs_signal(input: VertexOut) -> @location(0) vec4<f32> {
    let original = textureSampleLevel(scene, scene_sampler, input.uv, 0.0);
    if (input.uv.x < effect.region.x || input.uv.y < effect.region.y ||
        input.uv.x > effect.region.z || input.uv.y > effect.region.w) {
        return original;
    }
    let dimensions = vec2<f32>(textureDimensions(scene));
    let pixel = input.uv * dimensions;
    var offset = vec2<f32>(0.0);
    var energy = 0.0;
    var dots = 0.0;
    if (effect.hover.z > 0.5) {
        let center = effect.hover.xy * dimensions;
        let primary = liquid_blob(pixel, center, vec2<f32>(150.0, 118.0), 0.95, effect.hover.w * 0.7);
        let satellite = liquid_blob(pixel, center + vec2<f32>(38.0, -28.0),
                                    vec2<f32>(105.0, 140.0), 0.34, effect.hover.w * 0.5 + 1.6);
        offset += primary.xy + satellite.xy;
        energy += primary.z + satellite.z;
        dots = max(dots, signal_dots(pixel, center, 125.0, 0.58));
    }
    for (var i = 0u; i < 4u; i += 1u) {
        let wake = effect.wakes[i];
        if (wake.w > 0.0 && wake.z < 1.2) {
            let life = pow(max(1.0 - wake.z / 1.2, 0.0), 2.0) * wake.w;
            let center = wake.xy * dimensions;
            let blob = liquid_blob(pixel, center,
                                   vec2<f32>(122.0 + wake.z * 42.0, 92.0 + wake.z * 34.0),
                                   life * 0.67, wake.z * 1.7);
            offset += blob.xy;
            energy += blob.z;
            dots = max(dots, signal_dots(pixel, center, 108.0 + wake.z * 42.0, life * 0.46));
        }
    }
    if (effect.impact.w > 0.5 && effect.impact.z < 1.15) {
        let age = effect.impact.z;
        let life = pow(max(1.0 - age / 1.15, 0.0), 2.0);
        let center = effect.impact.xy * dimensions;
        let blob = liquid_blob(pixel, center,
                               vec2<f32>(110.0 + age * 105.0, 90.0 + age * 78.0),
                               life * 1.2, age * 2.4);
        offset += blob.xy;
        energy += blob.z;
        dots = max(dots, signal_dots(pixel, center, 90.0 + age * 180.0, life * 0.62));
    }
    if (energy < 0.001 && dots < 0.001) { return original; }

    let lower = effect.region.xy * dimensions + vec2<f32>(1.0);
    let upper = effect.region.zw * dimensions - vec2<f32>(1.0);
    let edge_distance = min(min(pixel.x - lower.x, upper.x - pixel.x),
                            min(pixel.y - lower.y, upper.y - pixel.y));
    let fade = smoothstep(0.0, 16.0, edge_distance);
    let shifted = clamp(pixel - clamp(offset, vec2<f32>(-12.0), vec2<f32>(12.0)) * fade,
                        lower, upper);
    let blur = min(energy, 1.0) * fade * 8.0;
    let uv_min = effect.region.xy;
    let uv_max = effect.region.zw;
    let base = textureSampleLevel(scene, scene_sampler, shifted / dimensions, 0.0);
    let tap_x1 = textureSampleLevel(scene, scene_sampler,
                                   clamp((shifted + vec2<f32>(blur, 0.0)) / dimensions, uv_min, uv_max), 0.0);
    let tap_x2 = textureSampleLevel(scene, scene_sampler,
                                   clamp((shifted - vec2<f32>(blur, 0.0)) / dimensions, uv_min, uv_max), 0.0);
    let tap_y1 = textureSampleLevel(scene, scene_sampler,
                                   clamp((shifted + vec2<f32>(0.0, blur)) / dimensions, uv_min, uv_max), 0.0);
    let tap_y2 = textureSampleLevel(scene, scene_sampler,
                                   clamp((shifted - vec2<f32>(0.0, blur)) / dimensions, uv_min, uv_max), 0.0);
    let softened = base * 0.24 + (tap_x1 + tap_x2 + tap_y1 + tap_y2) * 0.19;
    let fringe = normalize(offset + vec2<f32>(0.001)) * min(energy, 1.0) * fade * 1.25;
    let red = textureSampleLevel(scene, scene_sampler,
                                 clamp((shifted + fringe) / dimensions, uv_min, uv_max), 0.0);
    let blue = textureSampleLevel(scene, scene_sampler,
                                  clamp((shifted - fringe) / dimensions, uv_min, uv_max), 0.0);
    let liquid = vec4<f32>(mix(red.r, softened.r, 0.65), softened.g,
                           mix(blue.b, softened.b, 0.65), softened.a);
    let refracted = mix(original, liquid, fade);
    let dot_color = vec3<f32>(0.67, 0.75, 0.80);
    return vec4<f32>(mix(refracted.rgb, dot_color, min(dots * fade, 0.52)), refracted.a);
}
