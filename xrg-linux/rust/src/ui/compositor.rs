// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Stephen de la Vega.
//! Fade the completed dashboard once, rather than each overlapping graph shape.
use eframe::{
    egui,
    glow::{self, HasContext},
};
use std::sync::{Arc, Mutex};
#[derive(Default)]
pub(super) struct Compositor {
    state: Option<State>,
    pub error: Option<String>,
}
struct State {
    program: glow::Program,
    texture: glow::Texture,
    buffer: glow::Buffer,
    vao: Option<glow::VertexArray>,
    position: u32,
    opacity: glow::UniformLocation,
    sampler: glow::UniformLocation,
    size: [u32; 2],
}
fn shader(gl: &glow::Context, kind: u32, source: &str) -> Result<glow::Shader, String> {
    // Called only from a paint callback with a current, live GL context.
    unsafe {
        let shader = gl.create_shader(kind)?;
        gl.shader_source(shader, source);
        gl.compile_shader(shader);
        if !gl.get_shader_compile_status(shader) {
            let error = gl.get_shader_info_log(shader);
            gl.delete_shader(shader);
            return Err(error);
        }
        Ok(shader)
    }
}
impl State {
    fn new(gl: &glow::Context) -> Result<Self, String> {
        let version = eframe::egui_glow::ShaderVersion::get(gl);
        let declaration = version.version_declaration();
        let modern = version.is_new_shader_interface();
        let attribute = if modern { "in" } else { "attribute" };
        let vertex_out = if modern { "out" } else { "varying" };
        let fragment_in = if modern { "in" } else { "varying" };
        let output = if modern { "out vec4 output_color;" } else { "" };
        let output_name = if modern {
            "output_color"
        } else {
            "gl_FragColor"
        };
        let sample = if modern { "texture" } else { "texture2D" };
        let precision = if version.is_embedded() {
            "precision mediump float;"
        } else {
            ""
        };
        let vertex = shader(
            gl,
            glow::VERTEX_SHADER,
            &format!(
                "{declaration}{precision}\n{attribute} vec2 position; {vertex_out} vec2 uv; void main(){{ uv=position*0.5+0.5;gl_Position=vec4(position,0.0,1.0); }}"
            ),
        )?;
        let fragment = match shader(
            gl,
            glow::FRAGMENT_SHADER,
            &format!(
                "{declaration}{precision}\n{fragment_in} vec2 uv; uniform sampler2D image; uniform float opacity; {output} void main(){{ {output_name}={sample}(image,uv)*opacity; }}"
            ),
        ) {
            Ok(shader) => shader,
            Err(e) => {
                unsafe { gl.delete_shader(vertex) };
                return Err(e);
            }
        };
        // Resource creation and cleanup are confined to the active paint context.
        unsafe {
            let program = match gl.create_program() {
                Ok(p) => p,
                Err(e) => {
                    gl.delete_shader(vertex);
                    gl.delete_shader(fragment);
                    return Err(e);
                }
            };
            gl.attach_shader(program, vertex);
            gl.attach_shader(program, fragment);
            gl.link_program(program);
            gl.detach_shader(program, vertex);
            gl.detach_shader(program, fragment);
            gl.delete_shader(vertex);
            gl.delete_shader(fragment);
            if !gl.get_program_link_status(program) {
                let error = gl.get_program_info_log(program);
                gl.delete_program(program);
                return Err(error);
            }
            let (Some(position), Some(opacity), Some(sampler)) = (
                gl.get_attrib_location(program, "position"),
                gl.get_uniform_location(program, "opacity"),
                gl.get_uniform_location(program, "image"),
            ) else {
                gl.delete_program(program);
                return Err("Missing opacity shader inputs".into());
            };
            let texture = match gl.create_texture() {
                Ok(t) => t,
                Err(e) => {
                    gl.delete_program(program);
                    return Err(e);
                }
            };
            let buffer = match gl.create_buffer() {
                Ok(b) => b,
                Err(e) => {
                    gl.delete_texture(texture);
                    gl.delete_program(program);
                    return Err(e);
                }
            };
            let vao = if gl.version().major >= 3 {
                match gl.create_vertex_array() {
                    Ok(v) => Some(v),
                    Err(e) => {
                        gl.delete_buffer(buffer);
                        gl.delete_texture(texture);
                        gl.delete_program(program);
                        return Err(e);
                    }
                }
            } else {
                None
            };
            if let Some(vao) = vao {
                gl.bind_vertex_array(Some(vao));
            }
            gl.bind_buffer(glow::ARRAY_BUFFER, Some(buffer));
            let vertices: [f32; 12] = [-1., -1., 1., -1., 1., 1., -1., -1., 1., 1., -1., 1.];
            // The array remains alive and has exactly 12 initialized f32 values.
            let bytes = std::slice::from_raw_parts(
                vertices.as_ptr().cast::<u8>(),
                std::mem::size_of_val(&vertices),
            );
            gl.buffer_data_u8_slice(glow::ARRAY_BUFFER, bytes, glow::STATIC_DRAW);
            gl.enable_vertex_attrib_array(position);
            gl.vertex_attrib_pointer_f32(position, 2, glow::FLOAT, false, 8, 0);
            gl.bind_texture(glow::TEXTURE_2D, Some(texture));
            for parameter in [glow::TEXTURE_MIN_FILTER, glow::TEXTURE_MAG_FILTER] {
                gl.tex_parameter_i32(glow::TEXTURE_2D, parameter, glow::NEAREST as i32);
            }
            for parameter in [glow::TEXTURE_WRAP_S, glow::TEXTURE_WRAP_T] {
                gl.tex_parameter_i32(glow::TEXTURE_2D, parameter, glow::CLAMP_TO_EDGE as i32);
            }
            Ok(Self {
                program,
                texture,
                buffer,
                vao,
                position,
                opacity,
                sampler,
                size: [0; 2],
            })
        }
    }
    fn paint(&mut self, gl: &glow::Context, size: [u32; 2], opacity: f32) -> Result<(), String> {
        unsafe {
            let maximum = gl.get_parameter_i32(glow::MAX_TEXTURE_SIZE) as u32;
            if size.contains(&0) || size.iter().any(|v| *v > maximum) {
                return Err("Dashboard exceeds the graphics driver's texture limit".into());
            }
            gl.active_texture(glow::TEXTURE0);
            gl.bind_texture(glow::TEXTURE_2D, Some(self.texture));
            if self.size != size {
                gl.copy_tex_image_2d(
                    glow::TEXTURE_2D,
                    0,
                    glow::RGBA,
                    0,
                    0,
                    size[0] as i32,
                    size[1] as i32,
                    0,
                );
                self.size = size;
            } else {
                gl.copy_tex_sub_image_2d(
                    glow::TEXTURE_2D,
                    0,
                    0,
                    0,
                    0,
                    0,
                    size[0] as i32,
                    size[1] as i32,
                );
            }
            gl.disable(glow::SCISSOR_TEST);
            gl.disable(glow::DEPTH_TEST);
            gl.disable(glow::CULL_FACE);
            gl.disable(glow::BLEND);
            gl.viewport(0, 0, size[0] as i32, size[1] as i32);
            gl.clear_color(0., 0., 0., 0.);
            gl.clear(glow::COLOR_BUFFER_BIT);
            gl.use_program(Some(self.program));
            gl.uniform_1_i32(Some(&self.sampler), 0);
            gl.uniform_1_f32(Some(&self.opacity), opacity);
            if let Some(vao) = self.vao {
                gl.bind_vertex_array(Some(vao));
            }
            gl.bind_buffer(glow::ARRAY_BUFFER, Some(self.buffer));
            gl.enable_vertex_attrib_array(self.position);
            gl.vertex_attrib_pointer_f32(self.position, 2, glow::FLOAT, false, 8, 0);
            gl.draw_arrays(glow::TRIANGLES, 0, 6);
            gl.enable(glow::BLEND);
            gl.enable(glow::SCISSOR_TEST);
        }
        Ok(())
    }
    fn destroy(self, gl: &glow::Context) {
        unsafe {
            if let Some(vao) = self.vao {
                gl.delete_vertex_array(vao);
            }
            gl.delete_buffer(self.buffer);
            gl.delete_texture(self.texture);
            gl.delete_program(self.program);
        }
    }
}
impl Compositor {
    pub fn enqueue(owner: &Arc<Mutex<Self>>, ui: &egui::Ui, opacity: f64) {
        if opacity >= 1. {
            return;
        }
        let owner = owner.clone();
        let callback = eframe::egui_glow::CallbackFn::new(move |info, painter| {
            let mut compositor = owner.lock().unwrap();
            if compositor.error.is_some() {
                return;
            }
            if compositor.state.is_none() {
                match State::new(painter.gl()) {
                    Ok(state) => compositor.state = Some(state),
                    Err(e) => {
                        compositor.error = Some(e);
                        return;
                    }
                }
            }
            if let Err(e) = compositor.state.as_mut().unwrap().paint(
                painter.gl(),
                info.screen_size_px,
                opacity as f32,
            ) {
                compositor.error = Some(e);
            }
        });
        // Debug is above foreground menus and tooltips: fade the completed frame.
        ui.ctx()
            .layer_painter(egui::LayerId::new(
                egui::Order::Debug,
                egui::Id::unique("xrg-opacity"),
            ))
            .add(egui::epaint::PaintCallback {
                rect: ui.max_rect(),
                callback: Arc::new(callback),
            });
    }
    pub fn destroy(&mut self, gl: &glow::Context) {
        if let Some(state) = self.state.take() {
            state.destroy(gl);
        }
    }
}
