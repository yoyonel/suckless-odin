package postfx

import gl "vendor:OpenGL"

import log "../../core/log"
import dbg "../../core/gl_debug"
import settings "../../core/settings"
import shader "../shader"
import gl_state "../../core/gl_state"

// Post-processing pipeline state — owns FBO, textures, UBO, and shader.
Pipeline :: struct {
	// GPU resources
	scene_fbo:       u32,
	scene_color_tex: u32,
	velocity_tex:    u32, // RG16F — MRT attachment 1 (per-pixel velocity)
	depth_tex:       u32,
	settings_ubo:    u32,
	quad:            Fullscreen_Quad,

	// Multi-pass effects
	bloom_fx:         Bloom_FX,
	dof_fx:           Dof_FX,
	auto_exposure_fx: Auto_Exposure_FX,
	motion_blur_fx:   Motion_Blur_FX,
	lut3d_fx:         LUT3D_FX,

	// FXAA pre-pass (used when both FXAA + Motion Blur are active)
	// Runs FXAA before MB to prevent edge detection on blur gradients.
	fxaa_fbo:     u32,
	fxaa_tex:     u32, // RGBA16F — same format as scene_color_tex
	fxaa_program: u32,

	// GPU profiling
	timers: Gpu_Timers,

	// Shader variant cache (optional optimization)
	shader_cache: Shader_Cache,

	// Shader
	composite_program: u32,

	sync_dummy_program: u32,
	needs_sync_barrier: bool,

	// Resolution
	width:  i32,
	height: i32,

	// Effect state
	active_effects: Effect_Flags,
	debug_split:     Effect_Flags, // Per-effect A/B split (right half bypasses effect)
	split_positions: [Post_Effect]f32, // Per-effect split line position (0.0-1.0)
	enabled:        bool,

	// Cached debug/split state — restored when parent effect is re-enabled
	cached_debug: Effect_Flags,
	cached_split: Effect_Flags,

	// Parameters
	vignette:      Vignette_Params,
	grain:         Grain_Params,
	exposure:      Exposure_Params,
	chrom_abbr:    Chrom_Aberration_Params,
	white_balance: White_Balance_Params,
	color_grading: Color_Grading_Params,
	tonemapper:    Tonemap_Params,
	bloom:         Bloom_Params,
	fxaa:          FXAA_Params,
	dof:           Dof_Params,
	banding:       Banding_Params,
	fog:           Fog_Params,
	motion_blur:   Motion_Blur_Params,
	lut3d:         LUT3D_Params,

	// Per-frame data
	time:      f32,
	dt:        f32,
	ubo_dirty: bool,

	// Per-frame camera data (for fog depth reconstruction)
	fog_cam_pos:       [4]f32,
	fog_inv_view_proj: [16]f32,

	// Previous frame view-projection (for velocity buffer generation)
	prev_view_proj: [16]f32,

	// Saved state for begin/end (restored framebuffer)
	prev_fbo:      i32,
	prev_viewport: [4]i32,
}

// Initialize the post-processing pipeline.
pipeline_create :: proc(p: ^Pipeline, width, height: i32) -> (ok: bool) {
	defer if !ok { pipeline_destroy(p) }

	p.width = width
	p.height = height
	p.enabled = true
	p.ubo_dirty = true
	p.shader_cache.enabled = true

	// Set default parameters
	init_defaults(p)

	// Default active effects: exposure only (identity at 1.0)
	p.active_effects = {.Exposure}

	// Create fullscreen quad
	quad_create(&p.quad)

	// Create HDR framebuffer
	create_framebuffer(p) or_return

	// Create UBO
	gl.GenBuffers(1, &p.settings_ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, p.settings_ubo)
	gl.BufferData(gl.UNIFORM_BUFFER, size_of(Post_FX_UBO), nil, gl.DYNAMIC_DRAW)
	gl.BindBufferBase(gl.UNIFORM_BUFFER, 0, p.settings_ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	// Load composite shader
	p.composite_program = shader.load_program(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
	) or_return

	p.sync_dummy_program = shader.load_compute("shaders/postfx/sync_dummy.comp") or_return

	// Set sampler uniforms (fixed texture unit bindings)
	gl.UseProgram(p.composite_program)
	set_sampler_uniforms(p.composite_program)
	set_split_colors_uniform(p.composite_program)
	gl.UseProgram(0)

	// Validate UBO layout matches GPU expectations (std140 cross-check)
	if !validate_ubo_layout(p.composite_program) {
		log.log_error("suckless-odin.postfx", "UBO validation failed — aborting pipeline creation")
		return false
	}

	// Create FXAA pre-pass resources (FBO + texture + shader)
	fxaa_prepass_create(p) or_return

	// Create sub-effects
	bloom_create(&p.bloom_fx, width, height) or_return
	dof_create(&p.dof_fx, width, height) or_return
	auto_exposure_create(&p.auto_exposure_fx) or_return
	motion_blur_create(&p.motion_blur_fx, width, height) or_return

	// GPU timers for profiling
	gpu_timers_create(&p.timers)

	// Eagerly precompile canonical shader variants to avoid first-frame / preset switch stalls
	if p.shader_cache.enabled {
		log.log_info("suckless-odin.postfx", "Eagerly precompiling canonical shader preset variants...")
		pipeline_prewarm_presets(p)
	}

	log.log_info("suckless-odin.postfx", "Pipeline created (%dx%d)", width, height)
	return true
}

// Destroy all pipeline resources.
pipeline_destroy :: proc(p: ^Pipeline) {
	shader_cache_destroy(&p.shader_cache)
	gpu_timers_destroy(&p.timers)
	auto_exposure_destroy(&p.auto_exposure_fx)
	motion_blur_destroy(&p.motion_blur_fx)
	dof_destroy(&p.dof_fx)
	bloom_destroy(&p.bloom_fx)
	lut3d_destroy(&p.lut3d_fx)
	fxaa_prepass_destroy(p)
	delete_program(&p.composite_program)
	delete_program(&p.sync_dummy_program)
	destroy_framebuffer(p)
	delete_buffer(&p.settings_ubo)
	quad_destroy(&p.quad)
	log.log_info("suckless-odin.postfx", "Pipeline destroyed")
}

// Begin post-processing: bind scene FBO for rendering.
// Call this BEFORE rendering the scene.
pipeline_begin :: proc(p: ^Pipeline) {
	if !p.enabled {
		return
	}
	// Save current framebuffer and viewport (for correct restore in end)
	gl.GetIntegerv(gl.DRAW_FRAMEBUFFER_BINDING, &p.prev_fbo)
	gl.GetIntegerv(gl.VIEWPORT, raw_data(&p.prev_viewport))

	gl.BindFramebuffer(gl.FRAMEBUFFER, p.scene_fbo)
	gl.Viewport(0, 0, p.width, p.height)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
}

// End post-processing: run all effects and composite to the previously bound framebuffer.
// Call this AFTER rendering the scene.
@(private)
pipeline_run_passes :: proc(p: ^Pipeline) {
	// Upload UBO early so sub-passes (bloom prefilter) can read fog/effect state.
	upload_ubo(p)

	// Run bloom multi-pass if enabled
	gpu_timer_begin(&p.timers, .Bloom)
	if .Bloom in p.active_effects {
		dbg.push_group("PostFX_Bloom")
		bloom_render(&p.bloom_fx, &p.bloom, p.scene_color_tex, p.depth_tex, &p.quad)
		dbg.pop_group()
	}
	gpu_timer_end(&p.timers, .Bloom)

	// Run DoF pre-blur if enabled (reuses bloom shaders)
	gpu_timer_begin(&p.timers, .Dof)
	if .Dof in p.active_effects {
		dbg.push_group("PostFX_DepthOfField")
		dof_render(&p.dof_fx, &p.bloom_fx, &p.dof, p.scene_color_tex, &p.quad)
		dbg.pop_group()
	}
	gpu_timer_end(&p.timers, .Dof)

	// Run auto-exposure compute passes if enabled
	gpu_timer_begin(&p.timers, .Auto_Exposure)
	if .Auto_Exposure in p.active_effects {
		dbg.push_group("PostFX_AutoExposure")
		auto_exposure_render(&p.auto_exposure_fx, p.scene_color_tex, p.dt)
		dbg.pop_group()
	}
	gpu_timer_end(&p.timers, .Auto_Exposure)

	// GPU Execution Barrier & Compute Context Switch:
	// Force a hardware compute dispatch + L1/L2 VRAM cache drain before composite sampling
	// ONLY during active async IBL generation (progressive slices / baking).
	if p.needs_sync_barrier && p.sync_dummy_program != 0 {
		dbg.push_group("PostFX_SyncBarrier")
		gl.UseProgram(p.sync_dummy_program)
		gl.DispatchCompute(1, 1, 1)
		gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
		gl.UseProgram(0)
		dbg.pop_group()
	}

	// Run motion blur compute passes (tile-max + neighbor-max) if enabled
	// Also needed for debug modes (Motion_Blur_Debug, Vector_Field_Debug)
	gpu_timer_begin(&p.timers, .Motion_Blur)
	if .Motion_Blur in p.active_effects ||
	   .Motion_Blur_Debug in p.active_effects ||
	   .Vector_Field_Debug in p.active_effects {
		dbg.push_group("PostFX_MotionBlur_Compute")
		motion_blur_render(&p.motion_blur_fx, p.velocity_tex)
		dbg.pop_group()
	}
	gpu_timer_end(&p.timers, .Motion_Blur)
}

@(private)
pipeline_run_fxaa_prepass :: proc(p: ^Pipeline) -> bool {
	if .FXAA in p.active_effects && .Motion_Blur in p.active_effects && p.fxaa_program != 0 {
		dbg.push_group("PostFX_FXAA_Prepass")

		gl.BindFramebuffer(gl.FRAMEBUFFER, p.fxaa_fbo)
		gl.Viewport(0, 0, p.width, p.height)
		gl.Clear(gl.COLOR_BUFFER_BIT)

		gl.UseProgram(p.fxaa_program)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, p.scene_color_tex)
		quad_draw(&p.quad)
		gl.UseProgram(0)

		dbg.pop_group()
		return true
	}
	return false
}

@(private)
pipeline_bind_composite_textures :: proc(p: ^Pipeline, composite_source_tex: u32) {
	// Bind scene color texture (FXAA'd if pre-pass ran, raw otherwise)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_SCENE)
	gl.BindTexture(gl.TEXTURE_2D, composite_source_tex)

	// Bind bloom texture (result of multi-pass, or empty if disabled)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_BLOOM)
	gl.BindTexture(gl.TEXTURE_2D, bloom_get_texture(&p.bloom_fx))

	// Bind auto-exposure texture (1x1, read by uber-shader)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_EXPOSURE)
	gl.BindTexture(gl.TEXTURE_2D, auto_exposure_get_texture(&p.auto_exposure_fx))

	// Bind depth texture (for DoF CoC calculation)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_DEPTH)
	gl.BindTexture(gl.TEXTURE_2D, p.depth_tex)

	// Bind velocity texture (motion blur per-pixel velocity)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_VELOCITY)
	gl.BindTexture(gl.TEXTURE_2D, p.velocity_tex)

	// Bind neighbor-max velocity texture (motion blur dilated tiles)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_NEIGHBOR_MAX)
	gl.BindTexture(gl.TEXTURE_2D, motion_blur_get_neighbor_tex(&p.motion_blur_fx))

	// Bind tile-max velocity texture (motion blur debug)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_TILE_MAX)
	gl.BindTexture(gl.TEXTURE_2D, p.motion_blur_fx.tile_max_tex)

	// Bind DoF blur texture (1/4 res pre-blurred scene)
	gl.ActiveTexture(gl.TEXTURE0 + TEX_UNIT_DOF)
	gl.BindTexture(gl.TEXTURE_2D, dof_get_texture(&p.dof_fx))

	// Bind 3D LUT texture (unit 8, or 0 if not loaded)
	lut3d_bind(&p.lut3d_fx)
}

@(private)
pipeline_composite :: proc(p: ^Pipeline, composite_source_tex: u32, fxaa_prepass_ran: bool) {
	// Composite pass (uber-shader)
	gpu_timer_begin(&p.timers, .Composite)
	dbg.push_group("PostFX_Final_Composite")

	// Use cached optimized variant if available, otherwise fallback to dynamic
	active_program := shader_cache_find(&p.shader_cache, p.active_effects)
	if active_program == 0 && p.shader_cache.enabled {
		// Cache miss: automatically compile and cache the optimized variant!
		pipeline_compile_variant(p)
		active_program = shader_cache_find(&p.shader_cache, p.active_effects)
	}
	if active_program == 0 {
		active_program = p.composite_program
	}

	// Bind composite shader
	gl_state.use_program(active_program)

	// Bind all effect textures
	pipeline_bind_composite_textures(p, composite_source_tex)

	// Draw fullscreen quad (final composite)
	quad_draw(&p.quad)

	dbg.pop_group()
	gpu_timer_end(&p.timers, .Composite)
}

// End post-processing: run all effects and composite to the previously bound framebuffer.
// Call this AFTER rendering the scene.
pipeline_end :: proc(p: ^Pipeline) {
	if !p.enabled {
		return
	}

	dbg.push_group("Post_Processing")
	defer dbg.pop_group()

	// Collect previous frame's timer results (non-blocking)
	gpu_timers_collect(&p.timers, p.dt)

	// Run passes (Bloom, DoF, Auto-Exposure, Motion Blur)
	pipeline_run_passes(p)

	// --- FXAA Pre-pass (when both FXAA + Motion Blur are active) ---
	fxaa_prepass_ran := pipeline_run_fxaa_prepass(p)

	// Choose which texture the composite pass reads as "scene"
	composite_source_tex := fxaa_prepass_ran ? p.fxaa_tex : p.scene_color_tex

	// Restore the framebuffer that was active before begin
	dbg.push_group("PostFX_Composite_Setup")

	gl_state.bind_framebuffer(gl.FRAMEBUFFER, u32(p.prev_fbo))
	gl_state.set_viewport(p.prev_viewport[0], p.prev_viewport[1], p.prev_viewport[2], p.prev_viewport[3])
	gl.Clear(gl.COLOR_BUFFER_BIT)
	gl_state.disable(gl.DEPTH_TEST)

	// Generate mipmaps on the composite source for motion blur LOD sampling.
	if .Motion_Blur in p.active_effects {
		gl_state.bind_texture(gl.TEXTURE_2D, composite_source_tex)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
		gl.GenerateMipmap(gl.TEXTURE_2D)
	}

	// Upload UBO — if FXAA pre-pass ran, temporarily clear the FXAA bit so the
	// uber-shader doesn't run FXAA again.
	if fxaa_prepass_ran {
		p.active_effects -= {.FXAA}
	}
	upload_ubo(p)
	if fxaa_prepass_ran {
		p.active_effects += {.FXAA}
	}

	dbg.pop_group()

	// Final composite pass (uber-shader)
	pipeline_composite(p, composite_source_tex, fxaa_prepass_ran)

	// Restore mipmap filter to LINEAR after composite (texture completeness)
	if .Motion_Blur in p.active_effects {
		gl_state.bind_texture(gl.TEXTURE_2D, composite_source_tex)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	}

	// Restore state
	gl_state.enable(gl.DEPTH_TEST)
}

// Resize pipeline resources (call on window resize).
pipeline_resize :: proc(p: ^Pipeline, width, height: i32) {
	if width == p.width && height == p.height {
		return
	}
	p.width = width
	p.height = height

	destroy_framebuffer(p)
	create_framebuffer(p)
	fxaa_prepass_resize(p)
	bloom_resize(&p.bloom_fx, width, height)
	dof_resize(&p.dof_fx, width, height)
	motion_blur_resize(&p.motion_blur_fx, width, height)
	p.ubo_dirty = true

	log.log_info("suckless-odin.postfx", "Pipeline resized (%dx%d)", width, height)
}

// Update time accumulator (call each frame).
pipeline_update :: proc(p: ^Pipeline, dt: f32) {
	p.time += dt
	p.dt = dt
	p.ubo_dirty = true // time changes every frame
}

// Toggle an effect on/off.
pipeline_toggle :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects ~= {effect}
	if effect not_in p.active_effects {
		// Disabling: cache debug/split state, then clear
		p.cached_split += p.debug_split & {effect}
		p.debug_split -= {effect}
		#partial switch effect {
		case .Bloom:
			if .Bloom_Debug in p.active_effects { p.cached_debug += {.Bloom_Debug} }
			p.active_effects -= {.Bloom_Debug}
		case .FXAA:
			if .FXAA_Debug in p.active_effects { p.cached_debug += {.FXAA_Debug} }
			p.active_effects -= {.FXAA_Debug}
		case .Dof:
			if .Dof_Debug in p.active_effects { p.cached_debug += {.Dof_Debug} }
			p.active_effects -= {.Dof_Debug}
		case:
		}
	} else {
		// Re-enabling: restore cached debug/split state
		if effect in p.cached_split {
			p.debug_split += {effect}
			p.cached_split -= {effect}
		}
		#partial switch effect {
		case .Bloom:
			if .Bloom_Debug in p.cached_debug {
				p.active_effects += {.Bloom_Debug}
				p.cached_debug -= {.Bloom_Debug}
			}
		case .FXAA:
			if .FXAA_Debug in p.cached_debug {
				p.active_effects += {.FXAA_Debug}
				p.cached_debug -= {.FXAA_Debug}
			}
		case .Dof:
			if .Dof_Debug in p.cached_debug {
				p.active_effects += {.Dof_Debug}
				p.cached_debug -= {.Dof_Debug}
			}
		case:
		}
	}
	p.ubo_dirty = true
}

// Enable an effect.
pipeline_enable :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects += {effect}
	p.ubo_dirty = true
}

// Disable an effect.
pipeline_disable :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.active_effects -= {effect}
	p.debug_split -= {effect}
	p.ubo_dirty = true
}

// Toggle the A/B split-screen debug view for an effect.
// Left half shows the effect applied, right half bypasses it.
pipeline_toggle_split :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.debug_split ~= {effect}
	p.ubo_dirty = true
}

// Check if an effect is active.
pipeline_is_enabled :: proc(p: ^Pipeline, effect: Post_Effect) -> bool {
	return effect in p.active_effects
}

// Toggle the per-effect A/B split debug view (right half bypasses the effect).
pipeline_toggle_debug_split :: proc(p: ^Pipeline, effect: Post_Effect) {
	p.debug_split ~= {effect}
	p.ubo_dirty = true
}

// Set per-frame camera data needed by the fog shader.
// Call this BEFORE pipeline_end, once per frame.
pipeline_set_camera :: proc(p: ^Pipeline, cam_pos: [4]f32, inv_view_proj: [16]f32) {
	p.fog_cam_pos       = cam_pos
	p.fog_inv_view_proj = inv_view_proj
	p.ubo_dirty = true
}

// Load a 3D LUT from a .cube file. Replaces any previously loaded LUT.
// Returns true on success. Idempotent: safe to call while the pipeline is active.
pipeline_load_lut :: proc(p: ^Pipeline, path: string) -> bool {
	return lut3d_load(&p.lut3d_fx, path)
}

// Reset a single effect's parameters to its Default preset values.
// Does NOT toggle the effect's on/off state.
pipeline_reset_effect :: proc(p: ^Pipeline, effect: Post_Effect) {
	d := PRESETS[.Default]
	switch effect {
	case .Vignette:          p.vignette = d.vignette
	case .Grain:             p.grain = d.grain
	case .Exposure:          p.exposure = d.exposure
	case .Chrom_Abbr:        p.chrom_abbr = d.chrom_abbr
	case .Bloom:             p.bloom = d.bloom
	case .Color_Grading:     p.color_grading = d.color_grading
	case .Dof:               p.dof = d.dof
	case .Auto_Exposure:
		p.auto_exposure_fx.params = {
			min_luminance = DEFAULT_AUTO_MIN_LUMINANCE,
			max_luminance = DEFAULT_AUTO_MAX_LUMINANCE,
			speed_up      = DEFAULT_AUTO_SPEED_UP,
			speed_down    = DEFAULT_AUTO_SPEED_DOWN,
			key_value     = DEFAULT_AUTO_KEY_VALUE,
		}
	case .Motion_Blur:       p.motion_blur = d.motion_blur
	case .FXAA:              p.fxaa = d.fxaa
	case .Tonemap:           p.tonemapper = d.tonemapper
	case .Banding:           p.banding = d.banding
	case .Fog:               p.fog = d.fog
	case .LUT3D:             p.lut3d = d.lut3d
	case .Dof_Debug, .Exposure_Debug, .Motion_Blur_Debug,
	     .FXAA_Debug, .Stencil_Debug, .Bloom_Debug, .Fog_Debug, .LUT3D_Debug,
	     .Vector_Field_Debug, .Luminance_Debug:
		// Debug views have no settings to reset.
	}
	p.ubo_dirty = true
}

// Prewarm canonical shader presets into the cache to eliminate runtime compilation stalls.
//
// Strategy & Rationale:
// - Eagerly precompiles the 5 canonical CLI/production presets (Default, Subtle, Cinematic, Vibrant, Clean)
//   at startup during pipeline_create() in ~11ms total.
// - Leaves 59 out of 64 slots free in the LRU cache for dynamic customizations.
// - Extended / stylized presets (Vintage, Matrix, Retro, etc.) are compiled on-demand in the LRU cache
//   upon first selection in the Dear ImGui interface, without cache contention.
pipeline_prewarm_presets :: proc(p: ^Pipeline) {
	if !p.shader_cache.enabled { return }

	// 1. Precompile current active effects
	if shader_cache_find(&p.shader_cache, p.active_effects) == 0 {
		shader_cache_compile(&p.shader_cache, p.active_effects)
	}

	// 2. Precompile major canonical presets
	canonical := [?]Preset_Id{.Default, .Subtle, .Cinematic, .Vibrant, .Clean}
	presets := PRESETS
	for preset_id in canonical {
		effects := presets[preset_id].effects
		if shader_cache_find(&p.shader_cache, effects) == 0 {
			shader_cache_compile(&p.shader_cache, effects)
		}
	}
}

// Compile an optimized shader variant for the current active effects.
// Returns true if a new variant was compiled, false if cache full or disabled.
pipeline_compile_variant :: proc(p: ^Pipeline) -> bool {
	if !p.shader_cache.enabled { return false }
	existing := shader_cache_find(&p.shader_cache, p.active_effects)
	if existing != 0 { return false } // already cached
	return shader_cache_compile(&p.shader_cache, p.active_effects) != 0
}

// --- Private helpers ---

@(private)
init_defaults :: proc(p: ^Pipeline) {
	p.vignette = {
		intensity  = DEFAULT_VIGNETTE_INTENSITY,
		smoothness = DEFAULT_VIGNETTE_SMOOTHNESS,
		roundness  = DEFAULT_VIGNETTE_ROUNDNESS,
	}
	p.grain = {
		intensity            = DEFAULT_GRAIN_INTENSITY,
		intensity_shadows    = 1.0,
		intensity_midtones   = 1.0,
		intensity_highlights = 1.0,
		shadows_max          = DEFAULT_GRAIN_SHADOWS_MAX,
		highlights_min       = DEFAULT_GRAIN_HIGHLIGHTS_MIN,
		texel_size           = DEFAULT_GRAIN_TEXEL_SIZE,
	}
	p.exposure = {exposure = DEFAULT_EXPOSURE}
	p.chrom_abbr = {strength = DEFAULT_CHROM_ABBR_STRENGTH}
	p.white_balance = {temperature = DEFAULT_WB_TEMP, tint = DEFAULT_WB_TINT}
	p.color_grading = {
		saturation = 1.0,
		contrast   = 1.0,
		gamma      = 1.0,
		gain       = 1.0,
		offset     = 0.0,
		lift       = 0.0,
	}
	p.tonemapper = {
		slope      = DEFAULT_TONEMAP_SLOPE,
		toe        = DEFAULT_TONEMAP_TOE,
		shoulder   = DEFAULT_TONEMAP_SHOULDER,
		black_clip = DEFAULT_TONEMAP_BLACK_CLIP,
		white_clip = DEFAULT_TONEMAP_WHITE_CLIP,
	}
	p.bloom = {
		intensity      = DEFAULT_BLOOM_INTENSITY,
		threshold      = DEFAULT_BLOOM_THRESHOLD,
		soft_threshold = DEFAULT_BLOOM_SOFT_THRESHOLD,
		radius         = DEFAULT_BLOOM_RADIUS,
	}
	p.fxaa = {
		subpix             = DEFAULT_FXAA_SUBPIX,
		edge_threshold     = DEFAULT_FXAA_EDGE_THRESHOLD,
		edge_threshold_min = DEFAULT_FXAA_EDGE_THRESHOLD_MIN,
	}
	p.dof = DEFAULT_DOF_PARAMS
	for &pos in p.split_positions {
		pos = 0.5
	}
}

@(private)
create_framebuffer :: proc(p: ^Pipeline) -> (ok: bool) {
	gl.GenFramebuffers(1, &p.scene_fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, p.scene_fbo)

	// HDR color texture (RGBA16F)
	p.scene_color_tex = create_texture_2d(p.width, p.height, gl.RGBA16F, gl.RGBA)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, p.scene_color_tex, 0)

	// Velocity buffer (RG16F) — MRT attachment 1 for motion blur
	p.velocity_tex = create_texture_2d(p.width, p.height, gl.RG16F, gl.RG, filter = .Nearest)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT1, gl.TEXTURE_2D, p.velocity_tex, 0)

	// Enable MRT: draw to both color and velocity
	draw_buffers := [2]u32{gl.COLOR_ATTACHMENT0, gl.COLOR_ATTACHMENT1}
	gl.DrawBuffers(2, raw_data(&draw_buffers))

	// Depth texture (D32F for precision)
	p.depth_tex = create_texture_2d(
		p.width, p.height,
		gl.DEPTH_COMPONENT32F, gl.DEPTH_COMPONENT,
		filter = .Nearest,
	)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.TEXTURE_2D, p.depth_tex, 0)

	// Check completeness
	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	if status != gl.FRAMEBUFFER_COMPLETE {
		log.log_error("suckless-odin.postfx", "Framebuffer incomplete: 0x%X", status)
		return false
	}

	dbg.object_label(gl.FRAMEBUFFER, p.scene_fbo, "PostFX_SceneFBO")
	dbg.object_label(gl.TEXTURE, p.scene_color_tex, "PostFX_SceneColor_HDR")
	dbg.object_label(gl.TEXTURE, p.velocity_tex, "PostFX_Velocity_RG16F")
	dbg.object_label(gl.TEXTURE, p.depth_tex, "PostFX_Depth")

	return true
}

@(private)
destroy_framebuffer :: proc(p: ^Pipeline) {
	delete_texture(&p.scene_color_tex)
	delete_texture(&p.velocity_tex)
	delete_texture(&p.depth_tex)
	delete_fbo(&p.scene_fbo)
}

@(private)
build_split_positions :: proc(p: ^Pipeline) -> [20]f32 {
	result: [20]f32
	for effect in Post_Effect {
		idx := u32(effect)
		if idx < 20 {
			result[idx] = p.split_positions[effect]
		}
	}
	return result
}

@(private)
upload_ubo :: proc(p: ^Pipeline) {
	ubo := Post_FX_UBO{
		active_effects     = transmute(u32)p.active_effects,
		time               = p.time,
		screen_texel_size  = {1.0 / f32(p.width), 1.0 / f32(p.height)},

		vignette_intensity  = p.vignette.intensity,
		vignette_smoothness = p.vignette.smoothness,
		vignette_roundness  = p.vignette.roundness,

		grain_intensity            = p.grain.intensity,
		grain_intensity_shadows    = p.grain.intensity_shadows,
		grain_intensity_midtones   = p.grain.intensity_midtones,
		grain_intensity_highlights = p.grain.intensity_highlights,
		grain_shadows_max          = p.grain.shadows_max,
		grain_highlights_min       = p.grain.highlights_min,
		grain_texel_size           = p.grain.texel_size,

		exposure_manual = p.exposure.exposure,

		chrom_abbr_strength = p.chrom_abbr.strength,

		wb_temperature = p.white_balance.temperature,
		wb_tint        = p.white_balance.tint,

		grading_saturation = p.color_grading.saturation,
		grading_contrast   = p.color_grading.contrast,
		grading_gamma      = p.color_grading.gamma,
		grading_gain       = p.color_grading.gain,
		grading_offset     = p.color_grading.offset,
		grading_lift       = p.color_grading.lift,

		tonemap_slope      = p.tonemapper.slope,
		tonemap_toe        = p.tonemapper.toe,
		tonemap_shoulder   = p.tonemapper.shoulder,
		tonemap_black_clip = p.tonemapper.black_clip,
		tonemap_white_clip = p.tonemapper.white_clip,

		bloom_intensity      = p.bloom.intensity,
		bloom_threshold      = p.bloom.threshold,
		bloom_soft_threshold = p.bloom.soft_threshold,
		bloom_radius         = p.bloom.radius,

		fxaa_subpix             = p.fxaa.subpix,
		fxaa_edge_threshold     = p.fxaa.edge_threshold,
		fxaa_edge_threshold_min = p.fxaa.edge_threshold_min,

		dof_focal_distance   = p.dof.focal_distance,
		dof_focal_range      = p.dof.focal_range,
		dof_bokeh_scale      = p.dof.bokeh_scale,
		dof_anamorphic_ratio = p.dof.anamorphic_ratio,

		z_near = settings.NEAR_PLANE,
		z_far  = settings.FAR_PLANE,

		mb_intensity    = p.motion_blur.intensity,
		mb_max_velocity = p.motion_blur.max_velocity,
		mb_samples      = p.motion_blur.samples,
		mb_debug_mode   = p.motion_blur.debug_mode,

		banding_mode             = i32(p.banding.mode),
		banding_levels           = p.banding.levels,
		banding_dither_strength  = p.banding.dither_strength,
		banding_perceptual_gamma = p.banding.perceptual_gamma,
		banding_channel_levels   = p.banding.channel_levels,

		fog_density        = p.fog.density,
		fog_start          = p.fog.start,
		fog_height_falloff = p.fog.height_falloff,
		fog_max_opacity    = p.fog.max_opacity,
		fog_color          = p.fog.color,
		fog_cam_pos        = p.fog_cam_pos,
		fog_inv_view_proj  = p.fog_inv_view_proj,

		lut3d_intensity = p.lut3d.intensity,

		debug_split_mask = transmute(u32)p.debug_split,
		split_positions  = build_split_positions(p),
	}

	gl.BindBuffer(gl.UNIFORM_BUFFER, p.settings_ubo)
	gl.BufferSubData(gl.UNIFORM_BUFFER, 0, size_of(Post_FX_UBO), &ubo)
	gl.BindBuffer(gl.UNIFORM_BUFFER, 0)

	p.ubo_dirty = false
}
