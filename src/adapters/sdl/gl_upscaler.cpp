// SPDX-License-Identifier: MIT
// Copyright (c) 2026 OpenLF2 contributors

// xBRZ through SDL's OpenGL/GL ES renderers: draws the frame once more with a small GLSL program
// on the renderer's own context, then restores its cached GL state.
#include "openlf2/detail/sdl/frame_upscaler.hpp"
#include "openlf2/detail/sdl/xbrz_shader.hpp"
#include <array>
#include <cstddef>
#include <iostream>
#include <string>
#ifdef __EMSCRIPTEN__
#include <emscripten.h>
#endif

#ifdef __EMSCRIPTEN__
// Whether the browser draws without a graphics card (WebGL names the real one behind an extension): SwiftShader,
// llvmpipe or Windows' Basic Render Driver run the xBRZ program at a third of the frame rate or less.
EM_JS(int, openlf2_webgl_in_software, (), {
    var gl = GL.currentContext && GL.currentContext.GLctx;
    if (!gl) return 0;
    var info = gl.getExtension("WEBGL_debug_renderer_info");
    var name = String(gl.getParameter(info ? info.UNMASKED_RENDERER_WEBGL : gl.RENDERER) || "");
    return /swiftshader|llvmpipe|softpipe|software|basic render/i.test(name) ? 1 : 0;
});
#endif

namespace openlf2 {
namespace {
using GLenum = unsigned int;
using GLuint = unsigned int;
using GLint = int;
using GLsizei = int;
using GLboolean = unsigned char;
using GLfloat = float;
using GLchar = char;
using GLsizeiptr = std::ptrdiff_t;

constexpr GLenum gl_false = 0, gl_triangle_strip = 5, gl_texture_2d = 0x0DE1, gl_blend = 0x0BE2,
    gl_scissor_test = 0x0C11, gl_depth_test = 0x0B71, gl_cull_face = 0x0B44, gl_viewport = 0x0BA2,
    gl_fragment_shader = 0x8B30, gl_vertex_shader = 0x8B31, gl_compile_status = 0x8B81, gl_link_status = 0x8B82,
    gl_info_log_length = 0x8B84, gl_array_buffer = 0x8892, gl_static_draw = 0x88E4, gl_float = 0x1406,
    gl_texture0 = 0x84C0, gl_current_program = 0x8B8D, gl_array_buffer_binding = 0x8894,
    gl_active_texture = 0x84E0, gl_texture_binding_2d = 0x8069, gl_framebuffer = 0x8D40,
    gl_framebuffer_binding = 0x8CA6, gl_vertex_attrib_array_enabled = 0x8622, gl_vertex_array = 0x8074,
    gl_texture_mag_filter = 0x2800, gl_texture_min_filter = 0x2801, gl_texture_wrap_s = 0x2802,
    gl_texture_wrap_t = 0x2803, gl_nearest = 0x2600, gl_clamp_to_edge = 0x812F,
    gl_no_error = 0;

struct Functions {
    void (*viewport)(GLint, GLint, GLsizei, GLsizei) = nullptr;
    void (*get_integerv)(GLenum, GLint*) = nullptr;
    GLenum (*get_error)() = nullptr;
    GLboolean (*is_enabled)(GLenum) = nullptr;
    void (*enable)(GLenum) = nullptr;
    void (*disable)(GLenum) = nullptr;
    GLuint (*create_shader)(GLenum) = nullptr;
    void (*shader_source)(GLuint, GLsizei, const GLchar* const*, const GLint*) = nullptr;
    void (*compile_shader)(GLuint) = nullptr;
    void (*get_shaderiv)(GLuint, GLenum, GLint*) = nullptr;
    void (*get_shader_info_log)(GLuint, GLsizei, GLsizei*, GLchar*) = nullptr;
    void (*delete_shader)(GLuint) = nullptr;
    GLuint (*create_program)() = nullptr;
    void (*attach_shader)(GLuint, GLuint) = nullptr;
    void (*bind_attrib_location)(GLuint, GLuint, const GLchar*) = nullptr;
    void (*link_program)(GLuint) = nullptr;
    void (*get_programiv)(GLuint, GLenum, GLint*) = nullptr;
    void (*get_program_info_log)(GLuint, GLsizei, GLsizei*, GLchar*) = nullptr;
    void (*delete_program)(GLuint) = nullptr;
    void (*use_program)(GLuint) = nullptr;
    GLint (*get_uniform_location)(GLuint, const GLchar*) = nullptr;
    void (*uniform1i)(GLint, GLint) = nullptr;
    void (*uniform4f)(GLint, GLfloat, GLfloat, GLfloat, GLfloat) = nullptr;
    void (*gen_buffers)(GLsizei, GLuint*) = nullptr;
    void (*delete_buffers)(GLsizei, const GLuint*) = nullptr;
    void (*bind_buffer)(GLenum, GLuint) = nullptr;
    void (*buffer_data)(GLenum, GLsizeiptr, const void*, GLenum) = nullptr;
    void (*enable_vertex_attrib_array)(GLuint) = nullptr;
    void (*disable_vertex_attrib_array)(GLuint) = nullptr;
    void (*vertex_attrib_pointer)(GLuint, GLint, GLenum, GLboolean, GLsizei, const void*) = nullptr;
    void (*get_vertex_attribiv)(GLuint, GLenum, GLint*) = nullptr;
    void (*draw_arrays)(GLenum, GLint, GLsizei) = nullptr;
    void (*active_texture)(GLenum) = nullptr;
    void (*bind_texture)(GLenum, GLuint) = nullptr;
    void (*bind_framebuffer)(GLenum, GLuint) = nullptr;
    void (*tex_parameteri)(GLenum, GLenum, GLint) = nullptr;
};

template <typename Pointer> bool load(Pointer& target, const char* name) {
    target = reinterpret_cast<Pointer>(SDL_GL_GetProcAddress(name));
    return target != nullptr;
}
bool load_functions(Functions& gl) {
    return load(gl.viewport, "glViewport") && load(gl.get_integerv, "glGetIntegerv") && load(gl.get_error, "glGetError") &&
           load(gl.is_enabled, "glIsEnabled") && load(gl.enable, "glEnable") && load(gl.disable, "glDisable") &&
           load(gl.create_shader, "glCreateShader") && load(gl.shader_source, "glShaderSource") &&
           load(gl.compile_shader, "glCompileShader") && load(gl.get_shaderiv, "glGetShaderiv") &&
           load(gl.get_shader_info_log, "glGetShaderInfoLog") && load(gl.delete_shader, "glDeleteShader") &&
           load(gl.create_program, "glCreateProgram") && load(gl.attach_shader, "glAttachShader") &&
           load(gl.bind_attrib_location, "glBindAttribLocation") && load(gl.link_program, "glLinkProgram") &&
           load(gl.get_programiv, "glGetProgramiv") && load(gl.get_program_info_log, "glGetProgramInfoLog") &&
           load(gl.delete_program, "glDeleteProgram") && load(gl.use_program, "glUseProgram") &&
           load(gl.get_uniform_location, "glGetUniformLocation") && load(gl.uniform1i, "glUniform1i") &&
           load(gl.uniform4f, "glUniform4f") && load(gl.gen_buffers, "glGenBuffers") &&
           load(gl.delete_buffers, "glDeleteBuffers") && load(gl.bind_buffer, "glBindBuffer") &&
           load(gl.buffer_data, "glBufferData") && load(gl.enable_vertex_attrib_array, "glEnableVertexAttribArray") &&
           load(gl.disable_vertex_attrib_array, "glDisableVertexAttribArray") &&
           load(gl.vertex_attrib_pointer, "glVertexAttribPointer") && load(gl.get_vertex_attribiv, "glGetVertexAttribiv") &&
           load(gl.draw_arrays, "glDrawArrays") && load(gl.active_texture, "glActiveTexture") &&
           load(gl.bind_texture, "glBindTexture") && load(gl.bind_framebuffer, "glBindFramebuffer") &&
           load(gl.tex_parameteri, "glTexParameteri");
}

// GLSL 1.10 for desktop OpenGL (the renderer's 2.1 context), GLSL ES 1.00 for OpenGL ES 2.
std::string fragment_source(bool es) {
    std::string text = es ? "#ifdef GL_FRAGMENT_PRECISION_HIGH\nprecision highp float;\n#else\nprecision mediump float;\n#endif\n" : "";
    text += "varying vec2 v_uv;\nvarying vec4 v_color;\nuniform sampler2D u_texture;\nuniform vec4 u_params;\nvoid main() {\n    vec4 xbrz_out;\n";
    for (const auto part : xbrz_shader::glsl_body) text += part;
    text += "    gl_FragColor = xbrz_out;\n}\n";
    return text;
}
std::string vertex_source() {
    return "attribute vec2 a_position;\nvarying vec2 v_uv;\nvarying vec4 v_color;\nvoid main() {\n"
           "    gl_Position = vec4(a_position, 0.0, 1.0);\n"
           "    v_uv = vec2(a_position.x * 0.5 + 0.5, 0.5 - a_position.y * 0.5);\n"
           "    v_color = vec4(1.0, 1.0, 1.0, 1.0);\n}\n";
}

class GlUpscaler final : public FrameUpscaler {
public:
    GlUpscaler(const Functions& gl, GLuint program, GLuint buffer, GLint params, GLint texture, bool es)
        : gl_(gl), program_(program), buffer_(buffer), params_(params), texture_(texture), es_(es) {}
    ~GlUpscaler() override {
        // The context belongs to the renderer, which outlives this object.
        if (SDL_GL_GetCurrentContext() == nullptr) return;
        gl_.delete_program(program_);
        gl_.delete_buffers(1, &buffer_);
    }
    bool draw(SDL_Renderer& renderer, SDL_Texture& source,
              const SDL_FRect* destination) override {
        const auto properties = SDL_GetTextureProperties(&source);
        const auto number = SDL_GetNumberProperty(properties,
            es_ ? SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_NUMBER : SDL_PROP_TEXTURE_OPENGL_TEXTURE_NUMBER, 0);
        const auto target = SDL_GetNumberProperty(properties,
            es_ ? SDL_PROP_TEXTURE_OPENGLES2_TEXTURE_TARGET_NUMBER : SDL_PROP_TEXTURE_OPENGL_TEXTURE_TARGET_NUMBER, 0);
        if (number == 0 || target != gl_texture_2d) return SDL_SetError("xBRZ: the frame is not a plain 2D GL texture");
        SDL_FRect area{};
        int output_height = 0;
        if (!SDL_GetRenderLogicalPresentationRect(&renderer, &area) || !SDL_GetRenderOutputSize(&renderer, nullptr, &output_height)) {
            return false;
        }
        if (destination) area = *destination;
        // Everything the renderer queued must reach the window before this draw, and the renderer
        // must be told nothing about it: the GL state it caches is restored below.
        if (!SDL_FlushRenderer(&renderer)) return false;

        std::array<GLint, 4> viewport{};
        while (gl_.get_error() != gl_no_error) {} // errors of earlier draws are not ours
        gl_.get_integerv(gl_viewport, viewport.data());
        GLint program = 0, buffer = 0, active = 0, texture = 0, framebuffer = 0;
        gl_.get_integerv(gl_current_program, &program);
        gl_.get_integerv(gl_array_buffer_binding, &buffer);
        gl_.get_integerv(gl_active_texture, &active);
        gl_.get_integerv(gl_framebuffer_binding, &framebuffer);
        gl_.active_texture(gl_texture0);
        gl_.get_integerv(gl_texture_binding_2d, &texture);
        const bool scissor = gl_.is_enabled(gl_scissor_test), blend = gl_.is_enabled(gl_blend),
                   depth = gl_.is_enabled(gl_depth_test), cull = gl_.is_enabled(gl_cull_face);
        // Attribute 0 doubles as the fixed-function vertex array on compatibility contexts.
        GLint attribute_enabled = 0, vertex_array = 0;
        gl_.get_vertex_attribiv(0, gl_vertex_attrib_array_enabled, &attribute_enabled);
        if (!es_) vertex_array = gl_.is_enabled(gl_vertex_array);

        gl_.bind_framebuffer(gl_framebuffer, 0);
        gl_.viewport(static_cast<GLint>(SDL_lroundf(area.x)),
                     output_height - static_cast<GLint>(SDL_lroundf(area.y + area.h)),
                     static_cast<GLsizei>(SDL_lroundf(area.w)), static_cast<GLsizei>(SDL_lroundf(area.h)));
        gl_.disable(gl_scissor_test);
        gl_.disable(gl_blend);
        gl_.disable(gl_depth_test);
        gl_.disable(gl_cull_face);
        gl_.use_program(program_);
        gl_.bind_texture(gl_texture_2d, static_cast<GLuint>(number));
        // The frame texture is not power-of-two (the game's own resolution), and this draw
        // samples it directly instead of through SDL's own renderer, which never applies its
        // scale mode here. Left at the GL default (a mipmap min filter, GL_REPEAT wrap), WebGL
        // treats a non-power-of-two texture as incomplete and samples it as solid black; desktop
        // GL and most GLES drivers tolerate the default silently, so this only showed up there.
        gl_.tex_parameteri(gl_texture_2d, gl_texture_min_filter, static_cast<GLint>(gl_nearest));
        gl_.tex_parameteri(gl_texture_2d, gl_texture_mag_filter, static_cast<GLint>(gl_nearest));
        gl_.tex_parameteri(gl_texture_2d, gl_texture_wrap_s, static_cast<GLint>(gl_clamp_to_edge));
        gl_.tex_parameteri(gl_texture_2d, gl_texture_wrap_t, static_cast<GLint>(gl_clamp_to_edge));
        gl_.uniform1i(texture_, 0);
        gl_.uniform4f(params_, static_cast<float>(source.w), static_cast<float>(source.h),
                      destination ? static_cast<float>(source.w) / destination->w
                                  : 1.0f / presentation_scale(renderer, source), 0.0f);
        gl_.bind_buffer(gl_array_buffer, buffer_);
        gl_.vertex_attrib_pointer(0, 2, gl_float, gl_false, 0, nullptr);
        gl_.enable_vertex_attrib_array(0);
        gl_.draw_arrays(gl_triangle_strip, 0, 4);
        const bool drawn = gl_.get_error() == gl_no_error;

        if (attribute_enabled == 0) gl_.disable_vertex_attrib_array(0);
        if (!es_ && vertex_array == 0) gl_.disable(gl_vertex_array);
        gl_.bind_buffer(gl_array_buffer, static_cast<GLuint>(buffer));
        gl_.bind_texture(gl_texture_2d, static_cast<GLuint>(texture));
        gl_.active_texture(static_cast<GLenum>(active));
        gl_.use_program(static_cast<GLuint>(program));
        gl_.bind_framebuffer(gl_framebuffer, static_cast<GLuint>(framebuffer));
        gl_.viewport(viewport[0], viewport[1], viewport[2], viewport[3]);
        if (scissor) gl_.enable(gl_scissor_test);
        if (blend) gl_.enable(gl_blend);
        if (depth) gl_.enable(gl_depth_test);
        if (cull) gl_.enable(gl_cull_face);
        return drawn || SDL_SetError("xBRZ: the GL draw failed");
    }

private:
    Functions gl_;
    GLuint program_;
    GLuint buffer_;
    GLint params_;
    GLint texture_;
    bool es_;
};

GLuint compile(const Functions& gl, GLenum type, const std::string& source) {
    const GLuint shader = gl.create_shader(type);
    const GLchar* text = source.c_str();
    gl.shader_source(shader, 1, &text, nullptr);
    gl.compile_shader(shader);
    GLint status = 0;
    gl.get_shaderiv(shader, gl_compile_status, &status);
    if (status != 0) return shader;
    GLint length = 0;
    gl.get_shaderiv(shader, gl_info_log_length, &length);
    std::string log(static_cast<std::size_t>(length > 1 ? length : 1), '\0');
    gl.get_shader_info_log(shader, length, nullptr, log.data());
    std::cerr << "xBRZ: the GL shader did not compile: " << log.c_str() << '\n';
    gl.delete_shader(shader);
    return 0;
}
}

std::unique_ptr<FrameUpscaler> make_gl_upscaler(SDL_Renderer& renderer) {
    const std::string name = SDL_GetRendererName(&renderer) != nullptr ? SDL_GetRendererName(&renderer) : "";
    const bool es = name == "opengles2";
    if (!es && name != "opengl") return nullptr;
    if (SDL_GL_GetCurrentContext() == nullptr) return nullptr;
#ifdef __EMSCRIPTEN__
    if (openlf2_webgl_in_software() != 0) {
        std::cerr << "xBRZ: off, this browser draws without a graphics card (too slow for it)\n";
        return nullptr;
    }
#endif
    Functions gl;
    if (!load_functions(gl)) return nullptr;
    while (gl.get_error() != gl_no_error) {} // leave the renderer's error state clean
    const GLuint vertex = compile(gl, gl_vertex_shader, vertex_source());
    const GLuint fragment = vertex != 0 ? compile(gl, gl_fragment_shader, fragment_source(es)) : 0;
    if (vertex == 0 || fragment == 0) {
        if (vertex != 0) gl.delete_shader(vertex);
        return nullptr;
    }
    const GLuint program = gl.create_program();
    gl.attach_shader(program, vertex);
    gl.attach_shader(program, fragment);
    gl.bind_attrib_location(program, 0, "a_position");
    gl.link_program(program);
    gl.delete_shader(vertex);
    gl.delete_shader(fragment);
    GLint linked = 0;
    gl.get_programiv(program, gl_link_status, &linked);
    if (linked == 0) {
        GLint length = 0;
        gl.get_programiv(program, gl_info_log_length, &length);
        std::string log(static_cast<std::size_t>(length > 1 ? length : 1), '\0');
        gl.get_program_info_log(program, length, nullptr, log.data());
        std::cerr << "xBRZ: the GL program did not link: " << log.c_str() << '\n';
        gl.delete_program(program);
        return nullptr;
    }
    // One quad as a triangle strip in clip space.
    constexpr std::array<GLfloat, 8> corners{-1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f};
    GLuint buffer = 0;
    GLint previous = 0;
    gl.get_integerv(gl_array_buffer_binding, &previous);
    gl.gen_buffers(1, &buffer);
    gl.bind_buffer(gl_array_buffer, buffer);
    gl.buffer_data(gl_array_buffer, sizeof corners, corners.data(), gl_static_draw);
    gl.bind_buffer(gl_array_buffer, static_cast<GLuint>(previous));
    const GLint params = gl.get_uniform_location(program, "u_params");
    const GLint texture = gl.get_uniform_location(program, "u_texture");
    if (gl.get_error() != gl_no_error || params < 0 || texture < 0) {
        gl.delete_program(program);
        gl.delete_buffers(1, &buffer);
        return nullptr;
    }
    return std::make_unique<GlUpscaler>(gl, program, buffer, params, texture, es);
}
}
