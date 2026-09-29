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

// Screen-space interference nodes. A stable grid keeps the trail legible while
// its local size and brightness respond to the moving distortion field.
fn signal_dots(pixel: vec2<f32>, center: vec2<f32>, reach: f32, weight: f32) -> f32 {
    let cell = floor(pixel / 15.0);
    let node = (cell + vec2<f32>(0.5)) * 15.0
        + vec2<f32>(sin(cell.y * 1.73 + cell.x * 0.31),
                    cos(cell.x * 1.29 - cell.y * 0.47)) * 1.2;
    let distance = length((node - center) * vec2<f32>(1.0, 1.2));
    let field = exp(-pow(distance / reach, 2.0));
    let radius = 1.6 + field * 2.5;
    let dot = 1.0 - smoothstep(radius - 0.65, radius + 0.65, length(pixel - node));
    return dot * field * weight;
}

// Digital fluid: directional interference breaks the circles into irregular
// facets, while the frame remains intact outside the nominated region.
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
        let delta = pixel - effect.hover.xy * dimensions;
        let warped_radius = length(delta * vec2<f32>(1.0, 1.34))
            + sin(delta.y * 0.066 + effect.hover.w * 2.0) * 5.0
            + sin(delta.x * 0.039 - delta.y * 0.027) * 3.0;
        let pulse = exp(-pow((warped_radius - 42.0 - sin(effect.hover.w * 2.1) * 9.0) / 68.0, 2.0));
        offset += vec2<f32>(sin(warped_radius * 0.18 + delta.y * 0.04),
                            cos(warped_radius * 0.14 - delta.x * 0.035)) * pulse * 3.0;
        energy += pulse * 0.55;
        dots = max(dots, signal_dots(pixel, effect.hover.xy * dimensions, 108.0, 0.52));
    }
    for (var i = 0u; i < 4u; i += 1u) {
        let wake = effect.wakes[i];
        if (wake.w > 0.0 && wake.z < 1.2) {
            let delta = pixel - wake.xy * dimensions;
            let radius = length(delta * vec2<f32>(1.0, 1.26))
                + sin(delta.x * 0.042 + delta.y * 0.075) * 6.0;
            let life = pow(max(1.0 - wake.z / 1.2, 0.0), 2.0);
            let pulse = exp(-pow((radius - wake.z * 132.0) / 44.0, 2.0)) * life * wake.w;
            offset += vec2<f32>(sin(radius * 0.17 + delta.y * 0.05),
                                cos(radius * 0.14 - delta.x * 0.03)) * pulse * 5.2;
            energy += pulse;
            dots = max(dots, signal_dots(pixel, wake.xy * dimensions,
                                        92.0 + wake.z * 44.0, life * wake.w * 0.42));
        }
    }
    if (effect.impact.w > 0.5 && effect.impact.z < 1.15) {
        let age = effect.impact.z;
        let delta = pixel - effect.impact.xy * dimensions;
        let radius = length(delta * vec2<f32>(1.0, 1.18))
            + sin(delta.x * 0.055 - delta.y * 0.08) * 8.0;
        let life = pow(max(1.0 - age / 1.15, 0.0), 2.0);
        let pulse = exp(-pow((radius - age * 225.0) / 38.0, 2.0)) * life;
        offset += vec2<f32>(sin(radius * 0.23 + delta.y * 0.06),
                            cos(radius * 0.21 - delta.x * 0.04)) * pulse * 7.0;
        energy += pulse * 1.6;
        dots = max(dots, signal_dots(pixel, effect.impact.xy * dimensions,
                                    82.0 + age * 185.0, life * 0.58));
    }
    if (energy < 0.001 && dots < 0.001) { return original; }
    let lower = effect.region.xy * dimensions + vec2<f32>(1.0);
    let upper = effect.region.zw * dimensions - vec2<f32>(1.0);
    let edge_distance = min(min(pixel.x - lower.x, upper.x - pixel.x),
                            min(pixel.y - lower.y, upper.y - pixel.y));
    let fade = smoothstep(0.0, 12.0, edge_distance);
    let shifted = clamp(pixel - clamp(offset, vec2<f32>(-10.0), vec2<f32>(10.0)) * fade,
                        lower, upper);
    let fringe = normalize(offset + vec2<f32>(0.001)) * min(energy, 1.0) * fade * 1.5;
    let r = textureSampleLevel(scene, scene_sampler, (shifted + fringe) / dimensions, 0.0);
    let g = textureSampleLevel(scene, scene_sampler, shifted / dimensions, 0.0);
    let b = textureSampleLevel(scene, scene_sampler, (shifted - fringe) / dimensions, 0.0);
    let refracted = mix(original, vec4<f32>(r.r, g.g, b.b, g.a), fade);
    let dot_color = vec3<f32>(0.67, 0.75, 0.80);
    return vec4<f32>(mix(refracted.rgb, dot_color, min(dots * fade, 0.48)), refracted.a);
}
