package postfx

import gl "vendor:OpenGL"

import log "../../core/log"

// Depth of Field effect — gather-based with pre-blurred texture.
// Uses bloom's downsample (13-tap) shader directly in a single pass
// to produce a 1/4 resolution soft blurred version of the scene.
// The uber-shader mixes sharp/blurred based on CoC from depth.
Dof_FX :: struct {
	blur_fbo: u32,
	blur_tex: u32, // Final blurred result (1/4 res, R11F_G11F_B10F)
	width:    i32, // 1/4 resolution width
	height:   i32, // 1/4 resolution height
}

// Create DoF resources (texture + FBO). Width/height are full resolution.
dof_create :: proc(d: ^Dof_FX, width, height: i32) -> (ok: bool) {
	defer if !ok { dof_destroy(d) }

	d.width = max(width / 4, 1)
	d.height = max(height / 4, 1)

	// Blur texture (final result sampled by uber-shader)
	d.blur_tex = create_texture_2d(d.width, d.height, gl.R11F_G11F_B10F, gl.RGB)

	// Pre-attached FBO for single pass
	gl.GenFramebuffers(1, &d.blur_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, d.blur_fbo)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, d.blur_tex, 0)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	log.log_info("suckless-odin.postfx.dof", "DoF created (%dx%d quarter-res, single-pass)", d.width, d.height)
	return true
}

// Destroy DoF resources.
dof_destroy :: proc(d: ^Dof_FX) {
	delete_fbo(&d.blur_fbo)
	delete_texture(&d.blur_tex)
}

// Render DoF pre-blur pass in a single 13-tap wide downsampling pass.
// Produces a soft blurred version of the scene at 1/4 resolution.
// bloom_fx: provides the shared downsample shader program.
// src_texture: full-res HDR scene color.
dof_render :: proc(d: ^Dof_FX, bloom_fx: ^Bloom_FX, params: ^Dof_Params, src_texture: u32, quad: ^Fullscreen_Quad) {
	gl.Disable(gl.DEPTH_TEST)

	// Single Pass: 13-tap wide downsample scene → blur_tex (1/4 res)
	gl.BindFramebuffer(gl.FRAMEBUFFER, d.blur_fbo)
	gl.Viewport(0, 0, d.width, d.height)

	gl.UseProgram(bloom_fx.downsample_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, src_texture)

	// srcResolution = full scene resolution (4× our target)
	gl.Uniform2f(0, f32(d.width * 4), f32(d.height * 4))
	quad_draw(quad)

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// Resize DoF textures on window resize (width/height are full resolution).
dof_resize :: proc(d: ^Dof_FX, width, height: i32) {
	d.width = max(width / 4, 1)
	d.height = max(height / 4, 1)

	gl.BindTexture(gl.TEXTURE_2D, d.blur_tex)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.R11F_G11F_B10F, d.width, d.height, 0, gl.RGB, gl.FLOAT, nil)
	gl.BindTexture(gl.TEXTURE_2D, 0)
}

// Get the blurred texture for binding in the uber-shader.
dof_get_texture :: proc(d: ^Dof_FX) -> u32 {
	return d.blur_tex
}
