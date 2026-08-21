package app

import "core:fmt"
import "core:time"
import "vendor:glfw"
import gl "vendor:OpenGL"
import session "../core/session"
import tracy "../core/tracy"

import log "../core/log"
import settings "../core/settings"
import perf_mode "../core/perf_mode"
import scene "../scene"
import gui "../gui"
import postfx "../rendering/postfx"
import rendering "../rendering"
import dbg "../core/gl_debug"
import gl_state "../core/gl_state"
import itt "../core/itt"
import renderdoc "../core/renderdoc"

@(private)
frame_zone_loc := tracy.Source_Location_Data{
	name     = "Total Frame",
	function = "run",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_FRAME_TOTAL,
}

@(private)
update_zone_loc := tracy.Source_Location_Data{
	name     = "Frame Scene Update",
	function = "scene_update",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_CPU_UPDATE,
}

@(private)
render_zone_loc := tracy.Source_Location_Data{
	name     = "Frame Scene Render",
	function = "scene_render",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_CPU_RENDER,
}

@(private)
poll_zone_loc := tracy.Source_Location_Data{
	name     = "Frame Acquire Swapchain / Poll",
	function = "glfw.PollEvents",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_CPU_ACQUIRE,
}

@(private)
swap_zone_loc := tracy.Source_Location_Data{
	name     = "Frame Queue Submit & Present",
	function = "glfw.SwapBuffers",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_CPU_PRESENT,
}

// Application state — top-level struct owning all subsystems.
// ISO port of App struct from suckless-ogl/include/app.h.
App :: struct {
	window:          glfw.WindowHandle,
	width:           i32,
	height:          i32,
	title:           cstring,

	// Timing
	last_frame_time: f64,
	delta_time:      f32,

	// Startup telemetry tracking
	start_tick:       time.Tick,
	init_time_ms:     f64,
	frame_durations:  [5]f64,
	frame_poll:       [5]f64,
	frame_update:     [5]f64,
	frame_render:     [5]f64,
	frame_swap:       [5]f64,
	frame_index:      int,

	// State
	running:         bool,
	is_fullscreen:   bool,
	camera_enabled:  bool,  // C key toggles mouse-driven camera
	saved_x:         i32,
	saved_y:         i32,
	saved_width:     i32,
	saved_height:    i32,
	total_frames:    u64,

	// Deferred resize state (ISO port of suckless-ogl Deferred Resize pattern)
	resize_pending:  bool,
	pending_width:   i32,
	pending_height:  i32,

	// Scene
	scene:           scene.Scene,

	// GUI (Dear ImGui)
	imgui:           gui.Gui,

	// Tracy frame capture (PBO ring-buffer for async screenshots)
	frame_image:     tracy.Frame_Image,

	// Performance mode (GameMode / SCHED_FIFO / Nice)
	perf:            perf_mode.Perf_Mode,

	// Gamepad / Controller input (DualShock 4 / DualSense / Logitech / XInput)
	gamepad:         Gamepad_State,
}

// Creates the application (allocates + creates window).
create :: proc(width, height: i32, title: cstring) -> ^App {
	application := new(App)
	application.width  = width
	application.height = height
	application.title  = title
	application.running = false
	application.start_tick = time.tick_now()
	return application
}

// Initializes the application: window, OpenGL context, callbacks.
init :: proc(
	application: ^App,
	vsync: bool = false,
	compute_profile: settings.Compute_Shader_Profile = .Legacy,
	capture_ibl: bool = false,
) -> bool {
	if application == nil { return false }

	log.set_callback(tracy_log_callback)

	// Probe Intel ITT and RenderDoc in-app APIs
	itt.init()
	renderdoc.init()

	// Try to load previous session
	session_state := session.Session_State{}
	has_session := session.load_session(&session_state)
	defer if has_session {
		session.session_free(&session_state)
	}
	
	if has_session && session_state.window_size[0] > 0 && session_state.window_size[1] > 0 {
		application.width = session_state.window_size[0]
		application.height = session_state.window_size[1]
	}

	// Set Mesa env vars BEFORE GL context if perf mode was active last session
	if has_session && session_state.perf_mode_active {
		perf_mode.setup_mesa_early()
	}

	application.window = window_create(
		application.width,
		application.height,
		application.title,
		vsync = vsync,
	)
	if application.window == nil {
		return false
	}
	
	if has_session {
		glfw.SetWindowPos(application.window, session_state.window_pos[0], session_state.window_pos[1])
		application.saved_x = session_state.window_pos[0]
		application.saved_y = session_state.window_pos[1]
		application.saved_width = session_state.window_size[0]
		application.saved_height = session_state.window_size[1]
	}

	// Register Escape key callback
	glfw.SetKeyCallback(application.window, key_callback)

	// Store app pointer for use in callbacks
	glfw.SetWindowUserPointer(application.window, application)

	// Basic OpenGL setup
	gl.Enable(gl.DEPTH_TEST)
	gl.ClearColor(0.1, 0.1, 0.1, 1.0)
	tracy.gpu_init()
	tracy.frame_image_init(&application.frame_image)

	// Framebuffer resize callback
	glfw.SetFramebufferSizeCallback(application.window, framebuffer_size_callback)

	// Mouse input for camera
	glfw.SetCursorPosCallback(application.window, mouse_callback)
	glfw.SetScrollCallback(application.window, scroll_callback)
	glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
	application.camera_enabled = true

	// Gamepad / Controller subsystem
	gamepad_init(&application.gamepad)

	// Load compute shader and slicing parameters from JSON file
	tuning_params := settings.load_compute_tuning_params(compute_profile)

	// Initialize scene
	if !scene.scene_create(&application.scene, application.width, application.height, tuning_params) {
		log.log_error("suckless-odin.app", "Failed to create scene")
		return false
	}
	application.scene.env_mgr.capture_ibl = capture_ibl

	// Initialize GUI (Dear ImGui)
	if !gui.init(&application.imgui, application.window) {
		log.log_error("suckless-odin.app", "Failed to initialize ImGui")
		return false
	}

	if has_session {
		restore_session_state(application, session_state)
	}

	// Initialize performance mode subsystem (probes backends)
	// Must be after restore so session state is available, but probe before activate.
	perf_mode.init(&application.perf)
	if has_session && session_state.perf_mode_active {
		perf_mode.activate(&application.perf, quiet = true)
		log.log_debug("PERF", "Performance mode restored from session (%s)", perf_mode.backend_label(&application.perf))
	}

	application.last_frame_time = glfw.GetTime()
	application.running = true

	log.log_info("suckless-odin.app", "Application initialized (%dx%d)", application.width, application.height)
	return true
}

// Main loop — polls events, clears screen, swaps buffers.
// ISO port of app_run() from suckless-ogl/src/app.c.
run :: proc(application: ^App) {
	if application == nil { return }

	log.log_info("suckless-odin.app", "Entering main loop (Escape to quit)")

	tracy.set_thread_name("Main thread")
	tracy.plot_config("FPS", .Number, step = false, fill = true, color = tracy.COLOR_CPU_UPDATE)
	tracy.plot_config("Frame Time (ms)", .Number, step = false, fill = true, color = tracy.COLOR_FRAME_TOTAL)
	tracy.plot_config("IBL Slices Done", .Number, step = true, fill = false, color = tracy.COLOR_GPU_COMPUTE)

	if application.frame_index == 0 {
		application.init_time_ms = time.duration_milliseconds(time.tick_since(application.start_tick))
	}

	for application.running && !glfw.WindowShouldClose(application.window) {
		tracy.frame_mark()
		frame_zone := tracy.zone_begin(&frame_zone_loc)

		frame_start := time.tick_now()

		// Timing
		current_time := glfw.GetTime()
		application.delta_time = f32(current_time - application.last_frame_time)
		application.last_frame_time = current_time

		// Real-time plots for Tracy
		frame_time_ms := f64(application.delta_time * 1000.0)
		fps := f64(1.0 / application.delta_time) if application.delta_time > 0.00001 else 0.0
		tracy.plot("FPS", fps)
		tracy.plot("Frame Time (ms)", frame_time_ms)

		poll_start := time.tick_now()
		// Input
		poll_zone := tracy.zone_begin(&poll_zone_loc)
		glfw.PollEvents()
		tracy.zone_end(poll_zone)
		poll_dur := time.duration_milliseconds(time.tick_since(poll_start))

		// Deferred resize processing outside of GLFW callback context
		if application.resize_pending {
			scene.scene_resize(&application.scene, application.pending_width, application.pending_height)
			application.resize_pending = false
		}

		if !gui.wants_keyboard(&application.imgui) {
			process_keyboard(application)
		}

		gamepad_poll(application, &application.gamepad, application.delta_time)

		update_start := time.tick_now()
		// Update scene (camera physics, etc.)
		update_zone := tracy.zone_begin(&update_zone_loc)
		scene.scene_update(&application.scene, application.delta_time)
		tracy.zone_end(update_zone)
		update_dur := time.duration_milliseconds(time.tick_since(update_start))

		render_start := time.tick_now()
		// Render
		dbg.push_group("Render_Frame")

		w, h := glfw.GetFramebufferSize(application.window)
		gl.ClearColor(0.1, 0.1, 0.1, 1.0)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		render_zone := tracy.zone_begin(&render_zone_loc)
		scene.scene_render(&application.scene, w, h)
		tracy.zone_end(render_zone)

		// During first load: override with beautiful Nord slate screen and centered splash.
		// scene_render MUST still run (ISO C11: rendering between compute dispatch
		// frames maintains GL state coherency required by Intel Mesa driver).
		if application.scene.env_mgr.is_first_load {
			gl.ClearColor(0.043, 0.059, 0.098, 1.0)
			gl.Clear(gl.COLOR_BUFFER_BIT)

			status := "Loading..."
			#partial switch application.scene.env_mgr.ibl_state {
			case .Idle:
				status = "Decoding HDR Environment..."
			case .Upload_Texture:
				status = "Uploading HDR Texture..."
			case .Upload_Progressive:
				slice := application.scene.env_mgr.ibl_current_slice + 1
				total := application.scene.env_mgr.ibl_total_slices
				status = fmt.tprintf("Uploading HDR Texture... (%d/%d)", slice, total)
			case .Generate_Mipmaps:
				status = "Generating Mipmaps..."
			case .Luminance:
				status = "Analyzing Luminance..."
			case .Specular_Init:
				status = "Initializing Specular Map..."
			case .Specular_Mips:
				mip := application.scene.env_mgr.ibl_current_mip
				slice := application.scene.env_mgr.ibl_current_slice + 1
				total := application.scene.env_mgr.ibl_total_slices
				status = fmt.tprintf("Prefiltering Specular... (Mip %d, Slice %d/%d)", mip, slice, total)
			case .Irradiance:
				slice := application.scene.env_mgr.ibl_current_slice + 1
				total := application.scene.env_mgr.ibl_total_slices
				status = fmt.tprintf("Integrating Irradiance... (Slice %d/%d)", slice, total)
			case .Done:
				status = "Finalizing..."
			}

			// Add pulsing dots to the status text
			time_sec := glfw.GetTime()
			dots: string
			switch int(time_sec * 3.0) % 4 {
			case 0: dots = ""
			case 1: dots = "."
			case 2: dots = ".."
			case 3: dots = "..."
			}
			status_with_dots := fmt.tprintf("%s%s", status, dots)

			rendering.overlay_render_splash(&application.scene.overlay, w, h, "SUCKLESS-ODIN", status_with_dots)
		}

		// GUI (Dear ImGui) — render on top of scene
		if application.imgui.visible && !application.scene.env_mgr.is_first_load {
			dbg.push_group("GUI_ImGui")
			gui.new_frame(&application.imgui)
			gui.update(&application.imgui, gui.Scene_State{
				camera              = &application.scene.camera,
				skybox_visible      = &application.scene.skybox_visible,
				wireframe_enabled   = &application.scene.wireframe_enabled,
				exposure            = &application.scene.exposure,
				skybox_blur_lod     = &application.scene.skybox.blur_lod,
				skybox_mode         = &application.scene.skybox.mode,
				mipmap_mode         = &application.scene.skybox.mipmap_mode,
				blur_source         = &application.scene.skybox.blur_source,
				cubemap_dirty       = &application.scene.skybox.cubemap_dirty,
				show_mipmap_diff    = &application.scene.skybox.show_diff,
				diff_gain           = &application.scene.skybox.diff_gain,
				sort_mode           = &application.scene.sort_mode,
				edge_aa_enabled     = &application.scene.edge_aa_enabled,
				edge_aa_debug       = &application.scene.edge_aa_debug,
				specular_aa_enabled = &application.scene.specular_aa_enabled,
				specular_aa_mode    = &application.scene.specular_aa_mode,
				specular_aa_debug_mode = &application.scene.specular_aa_debug_mode,
				specular_aa_split_enabled  = &application.scene.specular_aa_split_enabled,
				specular_aa_split_position = &application.scene.specular_aa_split_position,
				ibl_irradiance_map  = application.scene.ibl.irradiance_map,
				ibl_prefilter_map   = application.scene.ibl.prefilter_map,
				ibl_brdf_lut        = application.scene.ibl.brdf_lut,
				env_texture_id      = application.scene.env_texture.id,
				env_texture_width   = application.scene.env_texture.width,
				env_texture_height  = application.scene.env_texture.height,
				postfx              = &application.scene.postfx_pipeline,
				perf                = &application.perf,
				frame_time_ms       = application.scene.overlay.frame_time_display,
				live_compute_tuning = &application.scene.env_mgr.compute_tuning,
				apply_compute_tuning = apply_compute_tuning_callback,
				scene_ptr           = &application.scene,
			})
			gui.render(&application.imgui)
			gl_state.reset()
			dbg.pop_group()
		}

		// Regenerate cubemap on-demand (lazy: only when mode == .Cubemap)
		if (application.scene.skybox.cubemap_dirty || application.scene.skybox.gen_state.in_progress) && application.scene.skybox.mode == .Cubemap {
			rendering.skybox_ensure_cubemap(&application.scene.skybox)
		}

		dbg.pop_group()
		render_dur := time.duration_milliseconds(time.tick_since(render_start))

		// Frame image capture for Tracy (async PBO readback)
		dbg.push_gpu_zone_only("Frame_Image_Capture")
		tracy.frame_image_update(&application.frame_image, w, h)
		dbg.pop_gpu_zone_only()

		tracy.zone_end(frame_zone)

		swap_start := time.tick_now()
		// Swap
		swap_zone := tracy.zone_begin(&swap_zone_loc)
		dbg.push_gpu_zone_only("Swap_Buffers")
		glfw.SwapBuffers(application.window)
		dbg.pop_gpu_zone_only()
		tracy.zone_end(swap_zone)
		swap_dur := time.duration_milliseconds(time.tick_since(swap_start))

		// GPU collect AFTER swap (captures all GPU work including swap fence)
		tracy.gpu_collect()

		// Telemetry recording
		if application.frame_index < 5 {
			idx := application.frame_index
			application.frame_durations[idx] = time.duration_milliseconds(time.tick_since(frame_start))
			application.frame_poll[idx] = poll_dur
			application.frame_update[idx] = update_dur
			application.frame_render[idx] = render_dur
			application.frame_swap[idx] = swap_dur
			application.frame_index += 1

			if application.frame_index == 5 {
				write_startup_telemetry(application)
			}
		}

		application.total_frames += 1
	}

	log.log_info("suckless-odin.app", "Total frames rendered during this run: %v", application.total_frames)
	log.log_info("suckless-odin.app", "Main loop exited")
}

// Cleans up all resources.
destroy :: proc(application: ^App) {
	if application == nil { return }

	// Save session state BEFORE cleanup (perf_mode.cleanup sets active=false)
	state := extract_session_state(application)
	session.save_session(&state)

	// Deactivate performance mode
	perf_mode.cleanup(&application.perf)

	gui.destroy(&application.imgui)
	scene.scene_destroy(&application.scene)
	tracy.frame_image_destroy(&application.frame_image)
	tracy.gpu_shutdown()
	window_destroy(application.window)
	free(application)

	log.log_info("suckless-odin.app", "Application destroyed")
}

// Apply CLI postfx options (preset, enable/disable).
apply_postfx_options :: proc(application: ^App, enabled: bool, preset: Maybe(postfx.Preset_Id)) {
	application.scene.postfx_pipeline.enabled = enabled
	if id, ok := preset.?; ok {
		postfx.pipeline_apply_preset(&application.scene.postfx_pipeline, id)
	}
}


