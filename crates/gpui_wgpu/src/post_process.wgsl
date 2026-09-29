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
fn signal_dots(pixel: vec2<f32>, center: vec2<f32>, reach: f32, weight: f32, age: f32, phase: f32) -> f32 {
    let cell = floor(pixel / 16.0);
    let node = (cell + vec2<f32>(0.5)) * 16.0;
    let distance = length((node - center) * vec2<f32>(1.0, 1.15));
    let field = exp(-pow(distance / reach, 2.0));
    // A damped spring settles behind the pointer. Spatial phase keeps adjacent
    // nodes coherent while avoiding a uniform, mechanical pulse.
    let bounce = 1.0 + 0.26 * exp(-age * 3.2) * sin(age * 18.0 - distance * 0.018 + phase);
    let radius = min(0.85 + field * 6.7 * bounce, 7.35);
    let dot = 1.0 - smoothstep(radius - 0.7, radius + 0.7, length(pixel - node));
    return dot * field * weight;
}

// The same fixed grid responds to one expanding drop wavefront. Only dot size
// and opacity change; their positions remain aligned with the hover grid.
fn signal_ring_dots(pixel: vec2<f32>, center: vec2<f32>,
                    radius: f32, width: f32, weight: f32) -> f32 {
    let cell = floor(pixel / 16.0);
    let node = (cell + vec2<f32>(0.5)) * 16.0;
    let distance = length((node - center) * vec2<f32>(1.0, 1.15));
    let field = exp(-pow((distance - radius) / width, 2.0));
    let dot_radius = 0.85 + field * 6.5;
    let dot = 1.0 - smoothstep(dot_radius - 0.7, dot_radius + 0.7, length(pixel - node));
    return dot * field * weight;
}

// Soft, asymmetric lensing gives each influence the shape of a liquid blob.
fn liquid_blob(pixel: vec2<f32>, center: vec2<f32>, axes: vec2<f32>,
               weight: f32, phase: f32) -> vec3<f32> {
    let local = (pixel - center) / axes;
    let cloud = exp(-dot(local, local) * 1.45) * weight;
    let flow = vec2<f32>(local.x + sin(local.y * 2.0 + phase) * 0.24,
                         local.y + cos(local.x * 1.8 - phase) * 0.20);
    return vec3<f32>(flow * cloud * 34.0, cloud);
}

fn liquid_ring(pixel: vec2<f32>, center: vec2<f32>,
               radius: f32, width: f32, weight: f32) -> vec3<f32> {
    let delta = pixel - center;
    let distance = length(delta * vec2<f32>(1.0, 1.15));
    let wavefront = exp(-pow((distance - radius) / width, 2.0)) * weight;
    let direction = delta / max(length(delta), 1.0);
    return vec3<f32>(direction * wavefront * 32.0, wavefront);
}

// Analytic capsules join recorded positions, including jumps spanning a whole
// frame. Their Gaussian cross-section has no separated stamp boundaries.
fn segment_fraction(pixel: vec2<f32>, start: vec2<f32>, end: vec2<f32>) -> f32 {
    let delta = end - start;
    return clamp(dot(pixel - start, delta) / max(dot(delta, delta), 0.001), 0.0, 1.0);
}

fn liquid_trail(pixel: vec2<f32>, start: vec2<f32>, end: vec2<f32>,
                start_age: f32, end_age: f32) -> vec3<f32> {
    let t = segment_fraction(pixel, start, end);
    let age = mix(start_age, end_age, t);
    let life = pow(max(1.0 - age / 1.2, 0.0), 2.0);
    return liquid_blob(pixel, mix(start, end, t),
                       vec2<f32>(210.0 + age * 70.0, 168.0 + age * 55.0),
                       life * 0.62, age * 1.2);
}

fn trail_dots(pixel: vec2<f32>, start: vec2<f32>, end: vec2<f32>,
              start_age: f32, end_age: f32) -> f32 {
    let node = (floor(pixel / 16.0) + vec2<f32>(0.5)) * 16.0;
    let t = segment_fraction(node, start, end);
    let age = mix(start_age, end_age, t);
    let life = pow(max(1.0 - age / 1.2, 0.0), 2.0);
    return signal_dots(pixel, mix(start, end, t), 185.0 + age * 55.0, life * 0.40, age, 0.0);
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
        let primary = liquid_blob(pixel, center, vec2<f32>(225.0, 180.0), 0.95, effect.hover.w * 0.7);
        let satellite = liquid_blob(pixel, center + vec2<f32>(38.0, -28.0),
                                    vec2<f32>(165.0, 205.0), 0.34, effect.hover.w * 0.5 + 1.6);
        offset += primary.xy + satellite.xy;
        energy += primary.z + satellite.z;
        dots = max(dots, signal_dots(pixel, center, 190.0, 0.58, 0.0, effect.hover.w * 2.4));
    }
    var previous = effect.hover.xy * dimensions;
    var previous_age = 0.0;
    var previous_valid = effect.hover.z > 0.5;
    for (var i = 0u; i < 4u; i += 1u) {
        let wake = effect.wakes[i];
        if (wake.w > 0.0 && wake.z < 1.2) {
            let center = wake.xy * dimensions;
            if (!previous_valid) {
                previous = center;
                previous_age = wake.z;
                previous_valid = true;
            }
            let blob = liquid_trail(pixel, previous, center, previous_age, wake.z);
            offset += blob.xy;
            energy += blob.z;
            dots = max(dots, trail_dots(pixel, previous, center, previous_age, wake.z));
            previous = center;
            previous_age = wake.z;
        }
    }
    if (effect.impact.w > 0.5 && effect.impact.z < 1.45) {
        let age = effect.impact.z;
        let life = pow(max(1.0 - age / 1.45, 0.0), 1.5);
        let center = effect.impact.xy * dimensions;
        let radius = age * 500.0;
        let width = 92.0 + age * 38.0;
        let blob = liquid_blob(pixel, center,
                               vec2<f32>(110.0 + age * 105.0, 90.0 + age * 78.0),
                               life * 0.55, age * 2.4);
        let ring = liquid_ring(pixel, center, radius, width, life * 1.15);
        offset += blob.xy + ring.xy;
        energy += blob.z + ring.z;
        dots = max(dots, signal_dots(pixel, center, 90.0 + age * 80.0, life * 0.16, age, 0.0));
        dots = max(dots, signal_ring_dots(pixel, center, radius, width, life * 0.68));
    }
    if (energy < 0.001 && dots < 0.001) { return original; }

    let lower = effect.region.xy * dimensions + vec2<f32>(1.0);
    let upper = effect.region.zw * dimensions - vec2<f32>(1.0);
    let edge_distance = min(min(pixel.x - lower.x, upper.x - pixel.x),
                            min(pixel.y - lower.y, upper.y - pixel.y));
    let fade = smoothstep(0.0, 16.0, edge_distance);
    let shifted = clamp(pixel - clamp(offset / max(energy, 1.0), vec2<f32>(-38.0), vec2<f32>(38.0)) * fade,
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
    let fringe = normalize(offset + vec2<f32>(0.001)) * min(energy, 1.0) * fade * 14.0;
    let red = textureSampleLevel(scene, scene_sampler,
                                 clamp((shifted + fringe) / dimensions, uv_min, uv_max), 0.0);
    let blue = textureSampleLevel(scene, scene_sampler,
                                  clamp((shifted - fringe) / dimensions, uv_min, uv_max), 0.0);
    let liquid = vec4<f32>(mix(red.r, softened.r, 0.22), softened.g,
                           mix(blue.b, softened.b, 0.22), softened.a);
    let refracted = mix(original, liquid, fade);
    let dot_color = vec3<f32>(0.36, 0.40, 0.41);
    return vec4<f32>(mix(refracted.rgb, dot_color, min(dots * fade * 0.8, 0.36)), refracted.a);
}
