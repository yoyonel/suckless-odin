package postfx

import gl "vendor:OpenGL"

import log "../../core/log"
import shader "../shader"

// Auto-exposure effect — single-pass compute-shader luminance reduction with temporal adaptation.
Auto_Exposure_FX :: struct {
	// Single compute program (downsample + reduce + adapt in one dispatch)
	program: u32,

	// GPU textures
	exposure_tex: u32, // 1x1 RGBA32F (persistent exposure state)

	// Readback (for GUI display, async)
	current_exposure:     f32,
	current_scene_lum:    f32,
	current_target:       f32,
	readback_pbo:         [2]u32, // double-buffered PBO
	readback_frame:       u32,
	readback_sync:        [2]gl.sync_t, // double-buffered sync fences

	// Parameters
	params: Auto_Exposure_Params,
}

// Create auto-exposure resources.
auto_exposure_create :: proc(fx: ^Auto_Exposure_FX) -> (ok: bool) {
	defer if !ok { auto_exposure_destroy(fx) }

	// Load single-pass compute shader (downsample + reduce + adapt)
	fx.program = shader.load_compute("shaders/postfx/lum_single_pass.comp") or_return

	// Create 1x1 RGBA32F exposure texture (persistent across frames)
	initial_data := [4]f32{DEFAULT_AUTO_EXPOSURE_INITIAL, 0.0, 0.0, 0.0}
	fx.exposure_tex = create_texture_2d(
		1, 1,
		gl.RGBA32F, gl.RGBA,
		filter = .Nearest,
		data = &initial_data[0],
	)

	// Create PBOs for async readback
	gl.GenBuffers(2, raw_data(&fx.readback_pbo))
	for i in 0 ..< 2 {
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fx.readback_pbo[i])
		gl.BufferData(gl.PIXEL_PACK_BUFFER, size_of([4]f32), nil, gl.STREAM_READ)
	}
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)

	// Set default parameters
	fx.params = {
		min_luminance = DEFAULT_AUTO_MIN_LUMINANCE,
		max_luminance = DEFAULT_AUTO_MAX_LUMINANCE,
		speed_up      = DEFAULT_AUTO_SPEED_UP,
		speed_down    = DEFAULT_AUTO_SPEED_DOWN,
		key_value     = DEFAULT_AUTO_KEY_VALUE,
	}
	fx.current_exposure = DEFAULT_AUTO_EXPOSURE_INITIAL

	log.log_info("suckless-odin.postfx.auto_exposure", "Auto-exposure created")
	return true
}

// Destroy auto-exposure resources.
auto_exposure_destroy :: proc(fx: ^Auto_Exposure_FX) {
	delete_program(&fx.program)
	delete_texture(&fx.exposure_tex)
	if fx.readback_pbo[0] != 0 {
		gl.DeleteBuffers(2, raw_data(&fx.readback_pbo))
		fx.readback_pbo = {}
	}
	for i in 0 ..< 2 {
		if fx.readback_sync[i] != nil {
			gl.DeleteSync(fx.readback_sync[i])
			fx.readback_sync[i] = nil
		}
	}
}

// Run auto-exposure single-pass compute. Call before the composite uber-shader pass.
// scene_tex: the HDR scene color texture from the pipeline FBO.
auto_exposure_render :: proc(fx: ^Auto_Exposure_FX, scene_tex: u32, dt: f32) {
	gl.UseProgram(fx.program)

	// Bind scene as sampler, exposure image as read-write
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, scene_tex)
	gl.BindImageTexture(1, fx.exposure_tex, 0, gl.FALSE, 0, gl.READ_WRITE, gl.RGBA32F)

	// Upload uniforms
	set_uniform_f32(fx.program, "deltaTime", dt)
	set_uniform_f32(fx.program, "minLuminance", fx.params.min_luminance)
	set_uniform_f32(fx.program, "maxLuminance", fx.params.max_luminance)
	set_uniform_f32(fx.program, "speedUp", fx.params.speed_up)
	set_uniform_f32(fx.program, "speedDown", fx.params.speed_down)
	set_uniform_f32(fx.program, "keyValue", fx.params.key_value)

	// Single dispatch: 256 threads do everything (sample scene, reduce, adapt)
	gl.DispatchCompute(1, 1, 1)
	gl.MemoryBarrier(gl.SHADER_IMAGE_ACCESS_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)
	gl.UseProgram(0)

	// Async readback for GUI (non-blocking, 2-frame latency)
	auto_exposure_readback(fx)
}

// Get the exposure texture to bind in the uber-shader.
auto_exposure_get_texture :: proc(fx: ^Auto_Exposure_FX) -> u32 {
	return fx.exposure_tex
}

// --- Private ---

@(private)
auto_exposure_readback :: proc(fx: ^Auto_Exposure_FX) {
	// Readback is purely telemetry for Dear ImGui debug sliders.
	// Throttle to 10 Hz (every 10 frames) to eliminate per-frame FenceSync/MapBuffer stalls.
	if fx.readback_frame % 10 != 0 {
		fx.readback_frame += 1
		return
	}

	write_idx := fx.readback_frame % 2
	read_idx := (fx.readback_frame + 1) % 2

	// Initiate async readback for current frame
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fx.readback_pbo[write_idx])
	gl.BindTexture(gl.TEXTURE_2D, fx.exposure_tex)
	gl.GetTexImage(gl.TEXTURE_2D, 0, gl.RGBA, gl.FLOAT, nil) // PBO async
	gl.BindTexture(gl.TEXTURE_2D, 0)

	if fx.readback_sync[write_idx] != nil {
		gl.DeleteSync(fx.readback_sync[write_idx])
	}
	fx.readback_sync[write_idx] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)

	// Read previous frame's result (should be ready by now)
	if fx.readback_frame >= 2 {
		sync := fx.readback_sync[read_idx]
		if sync != nil {
			res := gl.ClientWaitSync(sync, 0, 0) // non-blocking check
			if res == gl.ALREADY_SIGNALED || res == gl.CONDITION_SATISFIED {
				gl.BindBuffer(gl.PIXEL_PACK_BUFFER, fx.readback_pbo[read_idx])
				data := cast(^[4]f32)gl.MapBuffer(gl.PIXEL_PACK_BUFFER, gl.READ_ONLY)
				if data != nil {
					fx.current_exposure = data[0]
					fx.current_scene_lum = data[1]
					fx.current_target = data[2]
					gl.UnmapBuffer(gl.PIXEL_PACK_BUFFER)
				}
				gl.DeleteSync(sync)
				fx.readback_sync[read_idx] = nil
			}
		}
	}

	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
	fx.readback_frame += 1
}
