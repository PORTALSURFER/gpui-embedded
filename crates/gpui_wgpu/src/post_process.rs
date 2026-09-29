//! Optional framebuffer refraction for embedded editors.
//!
//! The scene is rendered once into a reusable texture. Ordered effects then
//! alternate between two textures before resolving to the surface. Each shader
//! passes pixels outside its normalized region through unchanged.

use bytemuck::{Pod, Zeroable};

#[repr(C)]
#[derive(Clone, Copy, Debug, Default, Pod, Zeroable)]
pub struct WaterEffect {
    /// Effect rectangle in normalized window coordinates: left, top, right, bottom.
    pub region: [f32; 4],
    /// Pointer x/y, active flag, and elapsed seconds.
    pub hover: [f32; 4],
    /// Drop x/y, age in seconds, and active flag.
    pub impact: [f32; 4],
    /// Up to four moving wakes: x/y, age in seconds, and weight.
    pub wakes: [[f32; 4]; 4],
}

/// An ordered framebuffer effect. Each effect samples the preceding layer's output.
/// Regions are independent and may overlap.
#[derive(Clone, Copy, Debug)]
pub enum PostEffect {
    Water(WaterEffect),
    Signal(WaterEffect),
}

impl PostEffect {
    pub fn valid(&self) -> bool {
        let effect = match self {
            PostEffect::Water(effect) | PostEffect::Signal(effect) => effect,
        };
        effect
            .region
            .iter()
            .all(|value| (0.0..=1.0).contains(value))
            && effect.region[0] < effect.region[2]
            && effect.region[1] < effect.region[3]
            && effect.hover.iter().all(|value| value.is_finite())
            && effect.impact.iter().all(|value| value.is_finite())
            && effect.wakes.iter().flatten().all(|value| value.is_finite())
    }
}

pub(crate) struct PostProcessor {
    water_pipeline: wgpu::RenderPipeline,
    signal_pipeline: wgpu::RenderPipeline,
    layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    sources: Vec<wgpu::Texture>,
    source_views: Vec<wgpu::TextureView>,
    uniforms: Vec<wgpu::Buffer>,
    size: (u32, u32),
    format: wgpu::TextureFormat,
}

impl PostProcessor {
    pub(crate) fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("gpui_post_processor_layout"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
                    count: None,
                },
            ],
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("gpui_post_processor_pipeline_layout"),
            bind_group_layouts: &[Some(&layout)],
            immediate_size: 0,
        });
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("gpui_post_processor_shader"),
            source: wgpu::ShaderSource::Wgsl(include_str!("post_process.wgsl").into()),
        });
        let make_pipeline = |entry_point| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some("gpui_post_pipeline"),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_fullscreen"),
                    buffers: &[],
                    compilation_options: wgpu::PipelineCompilationOptions::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some(entry_point),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: None,
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                    compilation_options: wgpu::PipelineCompilationOptions::default(),
                }),
                primitive: wgpu::PrimitiveState::default(),
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview_mask: None,
                cache: None,
            })
        };
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("gpui_post_processor_sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });
        let water_pipeline = make_pipeline("fs_water");
        let signal_pipeline = make_pipeline("fs_signal");
        Self {
            water_pipeline,
            signal_pipeline,
            layout,
            sampler,
            sources: Vec::new(),
            source_views: Vec::new(),
            uniforms: Vec::new(),
            size: (0, 0),
            format,
        }
    }

    pub(crate) fn invalidate(&mut self) {
        self.source_views.clear();
        for source in self.sources.drain(..) {
            source.destroy();
        }
        self.size = (0, 0);
    }

    fn ensure_targets(&mut self, device: &wgpu::Device, width: u32, height: u32) {
        if self.size == (width, height) && self.source_views.len() == 2 {
            return;
        }
        self.invalidate();
        for _ in 0..2 {
            let source = device.create_texture(&wgpu::TextureDescriptor {
                label: Some("gpui_post_intermediate"),
                size: wgpu::Extent3d {
                    width,
                    height,
                    depth_or_array_layers: 1,
                },
                mip_level_count: 1,
                sample_count: 1,
                dimension: wgpu::TextureDimension::D2,
                format: self.format,
                usage: wgpu::TextureUsages::RENDER_ATTACHMENT
                    | wgpu::TextureUsages::TEXTURE_BINDING,
                view_formats: &[],
            });
            self.source_views
                .push(source.create_view(&wgpu::TextureViewDescriptor::default()));
            self.sources.push(source);
        }
        self.size = (width, height);
    }

    pub(crate) fn scene_view(
        &mut self,
        device: &wgpu::Device,
        width: u32,
        height: u32,
    ) -> &wgpu::TextureView {
        self.ensure_targets(device, width, height);
        &self.source_views[0]
    }

    pub(crate) fn composite_stack(
        &mut self,
        device: &wgpu::Device,
        encoder: &mut wgpu::CommandEncoder,
        queue: &wgpu::Queue,
        final_target: &wgpu::TextureView,
        effects: &[PostEffect],
    ) {
        for (index, post_effect) in effects.iter().enumerate() {
            let effect = match post_effect {
                PostEffect::Water(effect) | PostEffect::Signal(effect) => effect,
            };
            if self.uniforms.len() <= index {
                self.uniforms
                    .push(device.create_buffer(&wgpu::BufferDescriptor {
                        label: Some("gpui_post_layer_uniform"),
                        size: std::mem::size_of::<WaterEffect>() as u64,
                        usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                        mapped_at_creation: false,
                    }));
            }
            queue.write_buffer(&self.uniforms[index], 0, bytemuck::bytes_of(effect));
            let source = &self.source_views[index % 2];
            let target = if index + 1 == effects.len() {
                final_target
            } else {
                &self.source_views[(index + 1) % 2]
            };
            let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some("gpui_post_layer_bind_group"),
                layout: &self.layout,
                entries: &[
                    wgpu::BindGroupEntry {
                        binding: 0,
                        resource: wgpu::BindingResource::TextureView(source),
                    },
                    wgpu::BindGroupEntry {
                        binding: 1,
                        resource: wgpu::BindingResource::Sampler(&self.sampler),
                    },
                    wgpu::BindGroupEntry {
                        binding: 2,
                        resource: self.uniforms[index].as_entire_binding(),
                    },
                ],
            });
            let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("gpui_post_layer_pass"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: target,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                ..Default::default()
            });
            pass.set_pipeline(match post_effect {
                PostEffect::Water(_) => &self.water_pipeline,
                PostEffect::Signal(_) => &self.signal_pipeline,
            });
            pass.set_bind_group(0, &bind_group, &[]);
            pass.draw(0..3, 0..1);
        }
    }
}
