package scene

// Environment Manager — orchestrates async HDR loading, IBL generation, and transitions.
// ISO C11: env_manager.c state machine + transition logic.
//
// State machine flow:
//   IDLE → (request) → LOADING → UPLOAD_TEXTURE → GENERATE_MIPMAPS →
//   SPECULAR_INIT → SPECULAR_MIPS → IRRADIANCE → DONE → (transition) → IDLE
//
// Transition modes (ISO: EnvTransitionMode):
//   - Black_Screen: fade to black → swap → fade from black
//   - Crossfade: capture snapshot → swap → blend snapshot over new

import "base:intrinsics"
import "core:fmt"
import "core:c/libc"
import "core:mem"
import "core:time"

import gl "vendor:OpenGL"

import dbg "../core/gl_debug"
import log "../core/log"
import "../rendering"
import settings "../core/settings"
import tracy "../core/tracy"
import itt "../core/itt"
import renderdoc "../core/renderdoc"

// --- Transition mode (ISO: EnvTransitionMode enum) ---

Transition_Mode :: enum {
	Crossfade,
	Black_Screen,
}

// --- Transition state & IBL progressive state ---
// Note: Transition_State and IBL_State are now automatically generated in env_manager_states.gen.odin.


// --- Constants ---

DEFAULT_TRANSITION_DURATION :: 0.25 // seconds (ISO: DEFAULT_ENV_TRANSITION_DURATION)
DEFAULT_CLAMP_MULTIPLIER :: 3.0   // ISO: threshold = mean_luminance * multiplier
IBL_THRESHOLD_FALLBACK_MIN :: 1.0 // ISO: ibl_coordinator.c — reject threshold < this

// Tracy message color for IBL pipeline (cyan/teal — matches Nord frost palette)
IBL_TRACY_COLOR :: 0x88C0D0
DEFAULT_AUTO_THRESHOLD   :: 5.0   // ISO: fallback if luminance computation fails

// Persistent Ring-Buffer PBO for Zero-Stall HDR streaming (OPT-06-PBO)
UPLOAD_PBO_SLOTS      :: 3
UPLOAD_MAX_WIDTH      :: 4096
UPLOAD_ROWS_PER_FRAME :: 256
UPLOAD_SLOT_BYTES     :: int(UPLOAD_ROWS_PER_FRAME) * int(UPLOAD_MAX_WIDTH) * 4 * size_of(u16)
UPLOAD_TOTAL_BYTES    :: UPLOAD_PBO_SLOTS * UPLOAD_SLOT_BYTES

// --- Env Manager struct (ISO: EnvManager) ---

Env_Manager :: struct {
	// Async loader (background thread)
	loader:           Async_Loader,

	// Current async request result (transferred from loader)
	async_result:     Async_Request,
	has_result:       bool,

	// Transition state machine
	transition_state: Transition_State,
	transition_mode:  Transition_Mode,
	transition_alpha: f32,
	transition_duration: f32,
	is_first_load:    bool,

	// IBL progressive state machine
	ibl_state:        IBL_State,
	ibl_current_mip:  i32,
	ibl_total_mips:   i32,
	ibl_current_slice: i32,
	ibl_total_slices: i32,

	// Adaptive HDR clamp threshold (ISO: computed from mean luminance)
	ibl_clamp_threshold: f32,

	// Pending GPU textures (being assembled before swap)
	pending_hdr_tex:  u32,
	pending_spec_tex: u32,
	pending_irr_tex:  u32,
	luminance_pbo:    u32,

	// Persistent Triple-Buffered Ring-Buffer Upload PBO (OPT-06-PBO)
	upload_pbo:       u32,
	upload_pbo_ptr:   rawptr,
	upload_ring_slot: int,
	upload_fences:    [UPLOAD_PBO_SLOTS]gl.sync_t,

	// Immutable IBL Texture Pools (OPT-04: zero runtime allocation/deallocation on env switch)
	specular_pool:    [2]u32,
	irradiance_pool:  [2]u32,
	pool_active_idx:  int,
	pool_initialized: bool,

	// Overlay and Transition resources
	debug_program:           u32,
	overlay_vao:             u32,
	transition_snapshot_tex: u32,
	recycled_hdr_tex:        u32,

	// Dynamic compute shader & slicing parameters from JSON config
	compute_tuning:          settings.Compute_Tuning_Params,

	// State machine tracking & diagnostics
	transition_prev_state:   Transition_State,
	transition_elapsed:      f32,
	ibl_prev_state:          IBL_State,
	ibl_elapsed:             f32,
	load_start_tick:         time.Tick,

	// Diagnostics & programmatic capture
	capture_ibl:             bool,
}

// --- Public API ---

env_manager_set_transition_state :: proc(mgr: ^Env_Manager, new_state: Transition_State) {
	if mgr.transition_state == new_state do return

	when ODIN_DEBUG {
		assert(env_manager_validate_transition(mgr.transition_state, new_state), "Viol d'automate : transition transition_state illégale")
		env_manager_validate_invariants(new_state, mgr.ibl_state)
	}

	log.log_info("suckless-odin.env", "Transition state: %v -> %v (previous duration: %.3fs)",
		mgr.transition_state, new_state, mgr.transition_elapsed)
	mgr.transition_prev_state = mgr.transition_state
	mgr.transition_state = new_state
	mgr.transition_elapsed = 0.0
}

env_manager_set_ibl_state :: proc(mgr: ^Env_Manager, new_state: IBL_State) {
	if mgr.ibl_state == new_state do return

	when ODIN_DEBUG {
		assert(env_manager_validate_ibl(mgr.ibl_state, new_state), "Viol d'automate : transition ibl_state illégale")
		env_manager_validate_invariants(mgr.transition_state, new_state)
	}

	log.log_info("suckless-odin.env", "IBL state: %v -> %v (previous duration: %.3fs)",
		mgr.ibl_state, new_state, mgr.ibl_elapsed)
	mgr.ibl_prev_state = mgr.ibl_state
	mgr.ibl_state = new_state
	mgr.ibl_elapsed = 0.0
}

env_manager_create :: proc(mgr: ^Env_Manager, tuning := settings.DEFAULT_COMPUTE_TUNING) -> bool {
	mgr.compute_tuning = tuning
	mgr.transition_state = .Wait_IBL
	mgr.transition_prev_state = .Idle
	mgr.transition_elapsed = 0.0
	mgr.transition_alpha = 1.0
	mgr.transition_duration = DEFAULT_TRANSITION_DURATION
	mgr.transition_mode = .Crossfade
	mgr.is_first_load = true
	mgr.ibl_state = .Idle
	mgr.ibl_prev_state = .Idle
	mgr.ibl_elapsed = 0.0
	mgr.load_start_tick = time.tick_now()

	mgr.debug_program = 0
	mgr.overlay_vao = 0
	mgr.transition_snapshot_tex = 0
	mgr.recycled_hdr_tex = 0

	if !async_loader_create(&mgr.loader) {
		return false
	}

	// Load transition shader
	program, ok := load_shader("shaders/debug_tex.vert", "shaders/debug_tex.frag")
	if !ok {
		async_loader_destroy(&mgr.loader)
		return false
	}
	mgr.debug_program = program

	// Generate empty VAO for procedural full-screen rendering
	gl.GenVertexArrays(1, &mgr.overlay_vao)

	// Initialize Immutable Double-Buffered IBL Texture Pools (OPT-04)
	for i in 0 ..< 2 {
		gl.GenTextures(1, &mgr.specular_pool[i])
		gl.BindTexture(gl.TEXTURE_2D, mgr.specular_pool[i])
		gl.TexStorage2D(
			gl.TEXTURE_2D,
			rendering.PREFILTER_MIP_LEVELS,
			gl.RGBA16F,
			rendering.PREFILTER_SIZE,
			rendering.PREFILTER_SIZE,
		)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		dbg.object_label(gl.TEXTURE, mgr.specular_pool[i], fmt.ctprintf("IBL_Prefiltered_Specular_Pool_%d", i))

		gl.GenTextures(1, &mgr.irradiance_pool[i])
		gl.BindTexture(gl.TEXTURE_2D, mgr.irradiance_pool[i])
		gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, rendering.IRRADIANCE_SIZE, rendering.IRRADIANCE_SIZE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		dbg.object_label(gl.TEXTURE, mgr.irradiance_pool[i], fmt.ctprintf("IBL_Irradiance_Map_Pool_%d", i))
	}
	gl.BindTexture(gl.TEXTURE_2D, 0)
	mgr.pool_active_idx = 0
	mgr.pool_initialized = true

	// Initialize Persistent Triple-Buffered Ring Upload PBO (OPT-06-PBO)
	gl.GenBuffers(1, &mgr.upload_pbo)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, mgr.upload_pbo)
	flags: u32 = gl.MAP_WRITE_BIT | gl.MAP_PERSISTENT_BIT | gl.MAP_COHERENT_BIT
	gl.BufferStorage(gl.PIXEL_UNPACK_BUFFER, UPLOAD_TOTAL_BYTES, nil, flags | gl.DYNAMIC_STORAGE_BIT)
	mgr.upload_pbo_ptr = gl.MapBufferRange(gl.PIXEL_UNPACK_BUFFER, 0, UPLOAD_TOTAL_BYTES, flags)
	gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, 0)
	dbg.object_label(gl.BUFFER, mgr.upload_pbo, "IBL_Persistent_Upload_PBO")
	mgr.upload_ring_slot = 0
	for &fence in mgr.upload_fences {
		fence = nil
	}

	log.log_info("suckless-odin.env", "Env manager created (Immutable IBL Pools & Persistent Ring PBO initialized)")
	return true
}

env_manager_destroy :: proc(mgr: ^Env_Manager) {
	async_loader_destroy(&mgr.loader)

	// Clean up IBL immutable texture pools (OPT-04)
	if mgr.pool_initialized {
		for i in 0 ..< 2 {
			if mgr.specular_pool[i] != 0 { gl.DeleteTextures(1, &mgr.specular_pool[i]); mgr.specular_pool[i] = 0 }
			if mgr.irradiance_pool[i] != 0 { gl.DeleteTextures(1, &mgr.irradiance_pool[i]); mgr.irradiance_pool[i] = 0 }
		}
		mgr.pool_initialized = false
	}

	// Clean up persistent upload PBO and fences (OPT-06-PBO)
	if mgr.upload_pbo != 0 {
		gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, mgr.upload_pbo)
		if mgr.upload_pbo_ptr != nil {
			gl.UnmapBuffer(gl.PIXEL_UNPACK_BUFFER)
			mgr.upload_pbo_ptr = nil
		}
		gl.DeleteBuffers(1, &mgr.upload_pbo)
		mgr.upload_pbo = 0
	}
	for &fence in mgr.upload_fences {
		if fence != nil {
			gl.DeleteSync(fence)
			fence = nil
		}
	}

	// Clean up any pending textures and buffers
	if mgr.pending_hdr_tex != 0 { gl.DeleteTextures(1, &mgr.pending_hdr_tex); mgr.pending_hdr_tex = 0 }
	mgr.pending_spec_tex = 0
	mgr.pending_irr_tex = 0

	// Clean up transition and overlay resources
	if mgr.debug_program != 0 { gl.DeleteProgram(mgr.debug_program) }
	if mgr.overlay_vao != 0 { gl.DeleteVertexArrays(1, &mgr.overlay_vao) }
	if mgr.transition_snapshot_tex != 0 { gl.DeleteTextures(1, &mgr.transition_snapshot_tex) }
	if mgr.recycled_hdr_tex != 0 { gl.DeleteTextures(1, &mgr.recycled_hdr_tex) }
	if mgr.luminance_pbo != 0 {
		gl.DeleteBuffers(1, &mgr.luminance_pbo)
		mgr.luminance_pbo = 0
	}

	// Free any unconsumed progressive upload data
	if mgr.async_result.data != nil {
		libc.free(mgr.async_result.data)
		mgr.async_result.data = nil
	}

	log.log_info("suckless-odin.env", "Env manager destroyed")
}

// Trigger an environment map change (async load + transition).
// ISO: env_manager_trigger_transition
env_manager_trigger_transition :: proc(mgr: ^Env_Manager, path: string) -> bool {
	// Don't trigger if already transitioning
	if mgr.transition_state != .Idle {
		log.log_warning("suckless-odin.env",
			"Transition already in progress, ignoring. (Current transition state: %v elapsed %.3fs [prev: %v], IBL state: %v elapsed %.3fs [prev: %v])",
			mgr.transition_state, mgr.transition_elapsed, mgr.transition_prev_state,
			mgr.ibl_state, mgr.ibl_elapsed, mgr.ibl_prev_state)
		return false
	}

	mgr.load_start_tick = time.tick_now()
	env_manager_set_transition_state(mgr, .Loading)
	mgr.transition_alpha = 0.0

	if !async_loader_request(&mgr.loader, path) {
		env_manager_set_transition_state(mgr, .Idle)
		return false
	}

	log.log_info("suckless-odin.env", "Transition triggered: %s", path)
	return true
}

// Trigger the initial environment load at startup.
// The env_manager starts in Wait_IBL state, which swaps textures on completion.
env_manager_trigger_initial :: proc(mgr: ^Env_Manager, path: string) {
	// transition_state is already .Wait_IBL from env_manager_create
	mgr.load_start_tick = time.tick_now()
	async_loader_request(&mgr.loader, path)
	log.log_info("suckless-odin.env", "Initial env load triggered: %s", path)
}

// Must be called each frame from the main thread.
// Polls async loader, advances IBL state machine, updates transition.
// ISO: one step per frame — poll and advance never both act on the same frame.
env_manager_update :: proc(mgr: ^Env_Manager, scene: ^Scene, dt: f32) {
	// 0. Update elapsed timers for instrumentation & diagnostic
	if mgr.transition_state != .Idle {
		mgr.transition_elapsed += dt
	}
	if mgr.ibl_state != .Idle {
		mgr.ibl_elapsed += dt
	}

	when ODIN_DEBUG {
		// Invariant 1: If transition is Idle, IBL must be Idle
		if mgr.transition_state == .Idle {
			assert(mgr.ibl_state == .Idle, "Invariant Violated: IBL active during transition Idle state")
		}
		// Invariant 2: If transition is Loading, either loader is active or IBL is active
		if mgr.transition_state == .Loading {
			assert(mgr.loader.request.state != .Idle || mgr.ibl_state != .Idle,
				"Invariant Violated: Transition is Loading but loader is Idle and IBL is Idle")
		}
	}

	// Stuck diagnostics warning (> 5.0s) to catch Wayland/Nvidia driver hangs
	if mgr.transition_state != .Idle && mgr.transition_elapsed > 5.0 {
		// Log warning every ~2 seconds (based on frames)
		if int(mgr.transition_elapsed * 10) % 20 == 0 {
			log.log_warning("suckless-odin.env",
				"STUCK TRANSITION WARNING: Transition state %v active for %.2fs (prev: %v). IBL state %v active for %.2fs (prev: %v).",
				mgr.transition_state, mgr.transition_elapsed, mgr.transition_prev_state,
				mgr.ibl_state, mgr.ibl_elapsed, mgr.ibl_prev_state)
		}
	}

	// 1. Poll async loader for completed results
	prev_ibl_state := mgr.ibl_state
	env_manager_poll_loader(mgr)

	// 2. Advance IBL state machine (one step per frame)
	// If poll just kicked off the IBL pipeline this frame, skip advance
	// to give each state one frame of visibility (ISO legacy: one step per frame).
	if !(prev_ibl_state == .Idle && mgr.ibl_state != .Idle) {
		env_manager_advance_ibl(mgr, scene)
	}

	// 3. Update transition alpha (fade in/out)
	env_manager_update_transition(mgr, scene, dt)
}
// Returns current transition alpha for overlay rendering.
env_manager_get_overlay_alpha :: proc(mgr: ^Env_Manager) -> f32 {
	if mgr.transition_state == .Idle {
		return 0.0
	}
	return mgr.transition_alpha
}

// Returns true if a transition overlay should be rendered.
env_manager_is_transitioning :: proc(mgr: ^Env_Manager) -> bool {
	return mgr.transition_state != .Idle
}

// --- Internal: poll async loader ---

@(private)
env_manager_poll_loader :: proc(mgr: ^Env_Manager) {
	if mgr.has_result {
		return // Already have data waiting, IBL will consume it
	}

	result: Async_Request
	poll_res := async_loader_poll(&mgr.loader, &result)
	switch poll_res {
	case .Ready:
		mgr.async_result = result
		mgr.has_result = true
		env_manager_set_transition_state(mgr, .Wait_IBL)
		env_manager_set_ibl_state(mgr, .Upload_Texture)
		log.log_info("suckless-odin.env", "Async load complete, starting IBL pipeline")

		itt.resume()
		itt.task_begin("IBL_Progressive_Pipeline")
		if mgr.capture_ibl && !renderdoc.is_capturing() {
			renderdoc.start_capture()
		}
	case .Failed:
		env_manager_set_transition_state(mgr, .Idle)
		log.log_error("suckless-odin.env", "Async load failed, transition aborted to prevent state machine deadlock")
	case .Busy:
		// Do nothing, still loading
	}
}

// --- Internal: IBL state machine (progressive, one step per frame) ---

@(private)
env_manager_ibl_upload_texture :: proc(mgr: ^Env_Manager, scene: ^Scene) {
	if mgr.async_result.data == nil {
		env_manager_set_ibl_state(mgr, .Idle)
		env_manager_set_transition_state(mgr, .Idle)
		return
	}

	dbg.push_group("IBL: Upload_HDR_Texture")
	defer dbg.pop_group()
	tracy.message_c(fmt.tprintf("IBL: Upload HDR %dx%d", mgr.async_result.width, mgr.async_result.height), IBL_TRACY_COLOR)

	// Calculate total mip levels for the HDR texture to allocate it immutably
	w := mgr.async_result.width
	h := mgr.async_result.height
	max_dim := max(w, h)
	mips: i32 = 1
	for d := max_dim; d > 1; d >>= 1 {
		mips += 1
	}

	reused := false
	if mgr.recycled_hdr_tex != 0 {
		gl.BindTexture(gl.TEXTURE_2D, mgr.recycled_hdr_tex)
		rec_w, rec_h: i32
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_WIDTH, &rec_w)
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, &rec_h)
		gl.BindTexture(gl.TEXTURE_2D, 0)

		if rec_w == w && rec_h == h {
			mgr.pending_hdr_tex = mgr.recycled_hdr_tex
			mgr.recycled_hdr_tex = 0
			gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
			log.log_info("suckless-odin.env", "IBL: Reusing recycled environment texture (%dx%d)", w, h)
			reused = true
		}
	}

	if !reused && mgr.is_first_load && scene.env_texture.id != 0 {
		if scene.env_texture.width == w && scene.env_texture.height == h {
			mgr.pending_hdr_tex = scene.env_texture.id
			scene.env_texture.id = 0
			gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
			log.log_info("suckless-odin.env", "IBL: Eagerly took initial scene environment texture (%dx%d)", w, h)
			reused = true
		}
	}

	if !reused {
		gl.GenTextures(1, &mgr.pending_hdr_tex)
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
		gl.TexStorage2D(gl.TEXTURE_2D, mips, gl.RGBA16F, w, h)
		log.log_info("suckless-odin.env", "IBL: Allocated new environment texture (%dx%d)", w, h)
	}

	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.REPEAT)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR_MIPMAP_LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	dbg.object_label(gl.TEXTURE, mgr.pending_hdr_tex, "IBL_HDR_Environment")

	gl.BindTexture(gl.TEXTURE_2D, 0)

	// Setup progressive slice count: 256 rows per frame
	mgr.ibl_current_slice = 0
	mgr.ibl_total_slices = (h + UPLOAD_ROWS_PER_FRAME - 1) / UPLOAD_ROWS_PER_FRAME
	mgr.upload_ring_slot = 0

	env_manager_set_ibl_state(mgr, .Upload_Progressive)

	log.log_info("suckless-odin.env", "IBL: Texture progressive upload started (%dx%d, Persistent Ring PBO DMA active)", w, h)
}

// Fast Non-Temporal AVX2 Streaming Copy for Write-Combining PBO memory (OPT-06-PBO-NT)
// Unrolls 8x 256-bit SIMD registers (256 bytes per iteration) with L1 prefetching to saturate memory bus.
Vec256 :: #simd[4]u64

@(private)
copy_non_temporal_avx2 :: proc "contextless" (dst: rawptr, src: rawptr, byte_count: int) {
	d := cast([^]Vec256)dst
	s := cast([^]Vec256)src
	num_vecs := byte_count / size_of(Vec256)

	i := 0
	for ; i + 8 <= num_vecs; i += 8 {
		intrinsics.prefetch_read_data(&s[i + 16], 3)
		intrinsics.prefetch_read_data(&s[i + 20], 3)

		v0 := s[i + 0]
		v1 := s[i + 1]
		v2 := s[i + 2]
		v3 := s[i + 3]
		v4 := s[i + 4]
		v5 := s[i + 5]
		v6 := s[i + 6]
		v7 := s[i + 7]

		intrinsics.non_temporal_store(&d[i + 0], v0)
		intrinsics.non_temporal_store(&d[i + 1], v1)
		intrinsics.non_temporal_store(&d[i + 2], v2)
		intrinsics.non_temporal_store(&d[i + 3], v3)
		intrinsics.non_temporal_store(&d[i + 4], v4)
		intrinsics.non_temporal_store(&d[i + 5], v5)
		intrinsics.non_temporal_store(&d[i + 6], v6)
		intrinsics.non_temporal_store(&d[i + 7], v7)
	}

	for ; i < num_vecs; i += 1 {
		intrinsics.non_temporal_store(&d[i], s[i])
	}
}

@(private)
env_manager_ibl_upload_progressive :: proc(mgr: ^Env_Manager) {
	if mgr.async_result.data == nil {
		env_manager_set_ibl_state(mgr, .Idle)
		env_manager_set_transition_state(mgr, .Idle)
		return
	}

	dbg.push_group("IBL: Upload_HDR_Texture_Slice")
	defer dbg.pop_group()

	w := mgr.async_result.width
	h := mgr.async_result.height
	y_offset := mgr.ibl_current_slice * UPLOAD_ROWS_PER_FRAME
	slice_h := min(UPLOAD_ROWS_PER_FRAME, h - y_offset)

	tracy.message_c(fmt.tprintf("IBL: Upload slice %d/%d (rows %d-%d)", mgr.ibl_current_slice + 1, mgr.ibl_total_slices, y_offset, y_offset + slice_h), IBL_TRACY_COLOR)

	// Upload slice asynchronously via Persistent Triple-Buffered Ring PBO (OPT-06-PBO)
	data_offset := int(y_offset) * int(w) * 4
	slice_data := &mgr.async_result.data[data_offset]
	slice_bytes := int(slice_h) * int(w) * 4 * size_of(u16)

	if mgr.upload_pbo_ptr != nil {
		slot := mgr.upload_ring_slot
		slot_offset := slot * UPLOAD_SLOT_BYTES

		// If slot has a pending GPU fence, wait (non-blocking first, max 50ms fallback)
		if mgr.upload_fences[slot] != nil {
			res := gl.ClientWaitSync(mgr.upload_fences[slot], 0, 0)
			if res != gl.ALREADY_SIGNALED && res != gl.CONDITION_SATISFIED {
				gl.ClientWaitSync(mgr.upload_fences[slot], gl.SYNC_FLUSH_COMMANDS_BIT, 50_000_000)
			}
			gl.DeleteSync(mgr.upload_fences[slot])
			mgr.upload_fences[slot] = nil
		}

		// Direct zero-driver-overhead non-temporal streaming copy into coherent mapped VRAM/GTT pointer
		dest_ptr := rawptr(uintptr(mgr.upload_pbo_ptr) + uintptr(slot_offset))
		copy_non_temporal_avx2(dest_ptr, slice_data, slice_bytes)

		// Trigger asynchronous DMA copy from PBO slot to texture
		gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, mgr.upload_pbo)
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
		gl.TexSubImage2D(
			gl.TEXTURE_2D, 0, 0, y_offset,
			w, slice_h,
			gl.RGBA, gl.HALF_FLOAT, rawptr(uintptr(slot_offset)),
		)
		gl.BindTexture(gl.TEXTURE_2D, 0)
		gl.BindBuffer(gl.PIXEL_UNPACK_BUFFER, 0)

		// Place fence to protect slot until GPU DMA completes
		mgr.upload_fences[slot] = gl.FenceSync(gl.SYNC_GPU_COMMANDS_COMPLETE, 0)

		// Advance ring slot
		mgr.upload_ring_slot = (slot + 1) % UPLOAD_PBO_SLOTS
	} else {
		// Fallback path without persistent PBO
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
		gl.TexSubImage2D(
			gl.TEXTURE_2D, 0, 0, y_offset,
			w, slice_h,
			gl.RGBA, gl.HALF_FLOAT, slice_data,
		)
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}

	mgr.ibl_current_slice += 1
	if mgr.ibl_current_slice >= mgr.ibl_total_slices {
		// Free CPU data (FP16 buffer allocated via libc.malloc on worker thread)
		libc.free(mgr.async_result.data)
		mgr.async_result.data = nil
		mgr.has_result = false

		env_manager_set_ibl_state(mgr, .Generate_Mipmaps)
		mgr.ibl_current_slice = 0
		log.log_info("suckless-odin.env", "IBL: Progressive upload complete, proceeding to Generate_Mipmaps")
	}
}

@(private)
env_manager_ibl_generate_mipmaps :: proc(mgr: ^Env_Manager) {
	dbg.push_group("IBL: Generate_Mipmaps")
	defer dbg.pop_group()
	tracy.message_c("IBL: Generating mipmaps", IBL_TRACY_COLOR)

	gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
	gl.GenerateMipmap(gl.TEXTURE_2D)
	gl.MemoryBarrier(gl.PIXEL_BUFFER_BARRIER_BIT | gl.TEXTURE_FETCH_BARRIER_BIT)

	// Calculate highest mip level: log2(max(w, h))
	w := mgr.async_result.width
	h := mgr.async_result.height
	max_dim := max(w, h)
	max_mip: i32 = 0
	for d := max_dim; d > 1; d >>= 1 {
		max_mip += 1
	}

	// Setup pack PBO for asynchronous GPU-to-CPU readback
	gl.GenBuffers(1, &mgr.luminance_pbo)
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, mgr.luminance_pbo)
	gl.BufferData(gl.PIXEL_PACK_BUFFER, 16, nil, gl.STREAM_READ)

	// Trigger asynchronous top mip level readback to the PBO
	gl.GetTexImage(gl.TEXTURE_2D, max_mip, gl.RGBA, gl.FLOAT, nil)

	gl.BindTexture(gl.TEXTURE_2D, 0)
	gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)

	env_manager_set_ibl_state(mgr, .Luminance)
	log.log_info("suckless-odin.env", "IBL: Mipmaps generated, async luminance readback triggered")
}

@(private)
env_manager_ibl_luminance :: proc(mgr: ^Env_Manager) {
	dbg.push_group("IBL: Luminance_Reduction")
	defer dbg.pop_group()

	perf_zone := tracy.hybrid_perf_zone_begin(&tracy.SRCLOC_HYBRID_LUMINANCE)
	defer tracy.hybrid_perf_zone_end(perf_zone)

	tracy.message_c("IBL: Computing luminance threshold", tracy.COLOR_IBL_LUMINANCE)

	pixels: [4]f32
	mapped := false

	if mgr.luminance_pbo != 0 {
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, mgr.luminance_pbo)
		ptr := gl.MapBuffer(gl.PIXEL_PACK_BUFFER, gl.READ_ONLY)
		if ptr != nil {
			mem.copy(&pixels[0], ptr, size_of(pixels))
			gl.UnmapBuffer(gl.PIXEL_PACK_BUFFER)
			mapped = true
		} else {
			log.log_error("suckless-odin.env", "Failed to map pack PBO for luminance readback, using fallback")
		}
		gl.BindBuffer(gl.PIXEL_PACK_BUFFER, 0)
		gl.DeleteBuffers(1, &mgr.luminance_pbo)
		mgr.luminance_pbo = 0
	}

	if !mapped {
		// CPU Fallback if PBO mapping fails (e.g. driver limitation)
		w := mgr.async_result.width
		h := mgr.async_result.height
		max_dim := max(w, h)
		max_mip: i32 = 0
		for d := max_dim; d > 1; d >>= 1 {
			max_mip += 1
		}
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
		gl.GetTexImage(gl.TEXTURE_2D, max_mip, gl.RGBA, gl.FLOAT, &pixels[0])
		gl.BindTexture(gl.TEXTURE_2D, 0)
	}

	// Compute luminance (ITU-R BT.709)
	mean_lum := 0.2126 * pixels[0] + 0.7152 * pixels[1] + 0.0722 * pixels[2]

	// ISO C11: threshold = mean_luminance * DEFAULT_CLAMP_MULTIPLIER
	// Guard: Inf/NaN from HDR hot pixels propagated through GenerateMipmap
	// → fallback to DEFAULT_AUTO_THRESHOLD (removes energy instead of saturating)
	raw_threshold := mean_lum * DEFAULT_CLAMP_MULTIPLIER
	if raw_threshold < IBL_THRESHOLD_FALLBACK_MIN || raw_threshold != raw_threshold || raw_threshold > 1e30 {
		// NaN check: x != x is true only for NaN. Inf check: > 1e30 catches ±Inf.
		mgr.ibl_clamp_threshold = DEFAULT_AUTO_THRESHOLD
	} else {
		mgr.ibl_clamp_threshold = max(raw_threshold, DEFAULT_AUTO_THRESHOLD)
	}

	env_manager_set_ibl_state(mgr, .Specular_Init)
	tracy.message_c(fmt.tprintf("IBL: Luminance threshold = %.2f", mgr.ibl_clamp_threshold), IBL_TRACY_COLOR)
	log.log_info("suckless-odin.env", "IBL: Luminance threshold = %.2f", mgr.ibl_clamp_threshold)
}

@(private)
env_manager_ibl_specular_init :: proc(mgr: ^Env_Manager) {
	dbg.push_group("IBL: Specular_Init")
	defer dbg.pop_group()
	tracy.message_c(fmt.tprintf("IBL: Specular init %dx%d, %d mips (pooled)",
		rendering.PREFILTER_SIZE, rendering.PREFILTER_SIZE, rendering.PREFILTER_MIP_LEVELS), IBL_TRACY_COLOR)

	// Reuse pending slot from immutable pool (OPT-04: zero runtime allocation)
	pending_idx := 1 - mgr.pool_active_idx
	mgr.pending_spec_tex = mgr.specular_pool[pending_idx]

	mgr.ibl_total_mips = rendering.PREFILTER_MIP_LEVELS
	mgr.ibl_current_mip = 0
	mgr.ibl_current_slice = 0
	env_manager_set_ibl_state(mgr, .Specular_Mips)
	log.log_info("suckless-odin.env", "IBL: Reusing pooled specular texture (slot %d, zero alloc), starting progressive mips", pending_idx)
}

@(private)
env_manager_ibl_done :: proc(mgr: ^Env_Manager, scene: ^Scene) {
	dbg.push_group("IBL: Finalize")
	defer dbg.pop_group()
	tracy.message_c("IBL: Pipeline complete, finalizing", tracy.COLOR_GPU_COMPUTE)

	// Barrier: make imageStore writes visible to texture() sampling.
	// TEXTURE_FETCH_BARRIER_BIT is required because scene_render reads
	// the prefilter/irradiance maps via texture() in the SAME frame.
	// (C11 relies on implicit SwapBuffers sync; we need explicit barrier.)
	sync_zone := tracy.hybrid_perf_zone_begin(&tracy.SRCLOC_HYBRID_SYNC)
	gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT | gl.SHADER_IMAGE_ACCESS_BARRIER_BIT)
	tracy.hybrid_perf_zone_end(sync_zone)

	itt.task_end()
	itt.pause()
	if renderdoc.is_capturing() {
		renderdoc.end_capture()
	}

	// Store transition_state before we set it, or simply use it in the switch
	transition_state := mgr.transition_state

	// Set IBL state to Idle first to satisfy the SafeTransition invariant:
	// (if transition_state becomes Idle, IBL must already be Idle).
	env_manager_set_ibl_state(mgr, .Idle)

	// Dispatch based on transition_state (ISO: env_manager_update_ibl)
	switch transition_state {
	case .Wait_IBL:
		switch mgr.transition_mode {
		case .Black_Screen:
			env_manager_set_transition_state(mgr, .Fade_Out)
			mgr.transition_alpha = 0.0
		case .Crossfade:
			if scene != nil {
				env_manager_capture_snapshot(mgr, scene.postfx_pipeline.width, scene.postfx_pipeline.height)
			}
			env_manager_swap_textures(mgr, scene)
			env_manager_set_transition_state(mgr, .Fade_In)
			mgr.transition_alpha = 1.0
		}
	case .Loading:
		switch mgr.transition_mode {
		case .Black_Screen:
			env_manager_set_transition_state(mgr, .Fade_Out)
			mgr.transition_alpha = 0.0
		case .Crossfade:
			if scene != nil {
				env_manager_capture_snapshot(mgr, scene.postfx_pipeline.width, scene.postfx_pipeline.height)
			}
			env_manager_swap_textures(mgr, scene)
			env_manager_set_transition_state(mgr, .Fade_In)
			mgr.transition_alpha = 1.0
		}
	case .Idle, .Fade_Out, .Fade_In:
		env_manager_swap_textures(mgr, scene)
		env_manager_set_transition_state(mgr, .Idle)
	}
}

@(private)
env_manager_advance_ibl :: proc(mgr: ^Env_Manager, scene: ^Scene) {
	switch mgr.ibl_state {
	case .Idle:
		return

	case .Upload_Texture:
		env_manager_ibl_upload_texture(mgr, scene)

	case .Upload_Progressive:
		env_manager_ibl_upload_progressive(mgr)

	case .Generate_Mipmaps:
		env_manager_ibl_generate_mipmaps(mgr)

	case .Luminance:
		env_manager_ibl_luminance(mgr)

	case .Specular_Init:
		env_manager_ibl_specular_init(mgr)

	case .Specular_Mips:
		env_manager_process_specular_slice(mgr, &scene.ibl)

	case .Irradiance:
		env_manager_process_irradiance_slice(mgr, &scene.ibl)

	case .Done:
		env_manager_ibl_done(mgr, scene)
	}
}

// --- Transition alpha update (ISO: env_manager_update_transition) ---
// Exposed for testing; called internally by env_manager_update.

env_manager_update_transition :: proc(mgr: ^Env_Manager, scene: ^Scene, dt: f32) {
	switch mgr.transition_state {
	case .Idle, .Loading, .Wait_IBL:
		// Nothing to animate
		return
	case .Fade_Out:
		mgr.transition_alpha += dt / mgr.transition_duration
		if mgr.transition_alpha >= 1.0 {
			mgr.transition_alpha = 1.0
			// Black screen swap happens here once screen is fully black
			if scene != nil {
				env_manager_swap_textures(mgr, scene)
			}
			env_manager_set_transition_state(mgr, .Fade_In)
		}
	case .Fade_In:
		mgr.transition_alpha -= dt / mgr.transition_duration
		if mgr.transition_alpha <= 0.0 {
			mgr.transition_alpha = 0.0
			env_manager_set_transition_state(mgr, .Idle)
		}
	}
}

// Renders the transition overlay (fullscreen quad using debug_program)
env_manager_render_overlay :: proc(mgr: ^Env_Manager, scene: ^Scene) {
	if mgr.transition_state == .Idle || mgr.transition_state == .Loading || mgr.transition_state == .Wait_IBL {
		return
	}

	// Bypass transition overlay for the initial environment load
	// (we have no valid screen snapshot to crossfade from)
	if mgr.transition_state == .Fade_In && mgr.transition_mode == .Crossfade && mgr.transition_snapshot_tex == 0 {
		return
	}

	dbg.push_group("Env_Manager: Render_Overlay")
	defer dbg.pop_group()

	gl.Disable(gl.DEPTH_TEST)
	gl.Enable(gl.BLEND)
	gl.BlendFunc(gl.SRC_ALPHA, gl.ONE_MINUS_SRC_ALPHA)

	gl.UseProgram(mgr.debug_program)

	// Set uniforms:
	// layout(location = 0) uniform float lod;
	// layout(location = 1) uniform float u_alpha;
	// layout(location = 2) uniform bool u_bypass_processing;
	// layout(location = 3) uniform bool u_black_screen;
	gl.Uniform1f(0, 0.0)
	gl.Uniform1f(1, mgr.transition_alpha)
	gl.Uniform1i(2, 1) // u_bypass_processing = true

	if mgr.transition_state == .Fade_Out && mgr.transition_mode == .Black_Screen {
		// Fade out to black
		gl.Uniform1i(3, 1) // u_black_screen = true
	} else if mgr.transition_state == .Fade_In && mgr.transition_mode == .Black_Screen {
		// Fade in from black
		gl.Uniform1i(3, 1) // u_black_screen = true
	} else if mgr.transition_state == .Fade_In && mgr.transition_mode == .Crossfade {
		// Crossfade: snapshot texture is bound
		gl.Uniform1i(3, 0) // u_black_screen = false
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, mgr.transition_snapshot_tex)
	} else {
		// fallback
		gl.Uniform1i(3, 1)
	}

	gl.BindVertexArray(mgr.overlay_vao)
	gl.DrawArrays(gl.TRIANGLES, 0, 3)
	gl.BindVertexArray(0)

	gl.UseProgram(0)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	gl.Disable(gl.BLEND)
	gl.Enable(gl.DEPTH_TEST)
}





// --- Slicing constants (ISO: ibl_coordinator.c) ---
// Controls how compute work is split across frames to avoid frame spikes.

// Slicing parameters are loaded dynamically from assets/configs/compute_tuning.json via mgr.compute_tuning.slicing.
// --- Internal: specular mip processing (ONE SLICE PER FRAME) ---
// ISO C11: process_specular_mips in ibl_coordinator.c
// - Mip 0: split into IBL_SPECULAR_MIP0_SLICES Y-slices (1 slice/frame)
// - Mip 1: split into IBL_SPECULAR_MIP1_SLICES Y-slices (1 slice/frame)
// - Mip 2: split into IBL_SPECULAR_MIP2_SLICES Y-slices (1 slice/frame)
// - Mips 3+: grouped together in 1 frame (small enough)

@(private)
env_manager_process_specular_slice :: proc(mgr: ^Env_Manager, ibl: ^rendering.IBL_Resources) {
	dbg.push_group("IBL: Specular_Mip_Slice")
	defer dbg.pop_group()

	perf_zone := tracy.hybrid_perf_zone_begin(&tracy.SRCLOC_HYBRID_SPECULAR)
	defer tracy.hybrid_perf_zone_end(perf_zone)

	// Determine slice count for current mip (ISO: process_specular_mips branching)
	if mgr.ibl_current_mip >= mgr.compute_tuning.slicing.specular_mip_grouping_start_mip {
		// Mips 3+ grouped in a single frame (small textures, negligible cost)
		tracy.message_c(fmt.tprintf("IBL: Specular Mips %d-%d (grouped)",
			mgr.ibl_current_mip, mgr.ibl_total_mips - 1), tracy.COLOR_IBL_SPECULAR)

		gl.UseProgram(ibl.spmap_program)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)

		for mip in mgr.ibl_current_mip..<mgr.ibl_total_mips {
			env_manager_dispatch_specular_mip(mgr, ibl, mip, 0, 1)
		}

		gl.UseProgram(0)
		mgr.ibl_current_mip = mgr.ibl_total_mips
	} else {
		// Per-slice processing for large mips
		if mgr.ibl_current_slice == 0 {
			// First slice of this mip — determine total slices
			switch mgr.ibl_current_mip {
			case 0:
				mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip0_slices
			case 1:
				mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip1_slices
			case 2:
				mgr.ibl_total_slices = mgr.compute_tuning.slicing.specular_mip2_slices
			case:
				mgr.ibl_total_slices = 1
			}
		}

		tracy.message_c(fmt.tprintf("IBL: Specular Mip %d Slice %d/%d",
			mgr.ibl_current_mip, mgr.ibl_current_slice + 1, mgr.ibl_total_slices), IBL_TRACY_COLOR)
		log.log_debug("suckless-odin.ibl", "Progressive IBL: Specular Mip %d Slice %d/%d",
			mgr.ibl_current_mip, mgr.ibl_current_slice + 1, mgr.ibl_total_slices)

		gl.UseProgram(ibl.spmap_program)
		gl.ActiveTexture(gl.TEXTURE0)
		gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)

		env_manager_dispatch_specular_mip(mgr, ibl, mgr.ibl_current_mip,
			mgr.ibl_current_slice, mgr.ibl_total_slices)

		gl.UseProgram(0)

		// Advance slice/mip counters
		mgr.ibl_current_slice += 1
		if mgr.ibl_current_slice >= mgr.ibl_total_slices {
			mgr.ibl_current_slice = 0
			mgr.ibl_current_mip += 1
		}
	}

	// Check if all specular mips are done
	if mgr.ibl_current_mip >= mgr.ibl_total_mips {
		log.log_info("suckless-odin.env", "IBL: Specular complete")
		env_manager_start_irradiance(mgr)
	}
}

// Dispatch a single specular mip slice (ISO: pbr_prefilter_mip with Y-slicing).
@(private)
env_manager_dispatch_specular_mip :: proc(
	mgr: ^Env_Manager, ibl: ^rendering.IBL_Resources,
	mip: i32, slice_index: i32, total_slices: i32,
) {
	mip_w := max(i32(1), rendering.PREFILTER_SIZE >> u32(mip))
	mip_h := max(i32(1), rendering.PREFILTER_SIZE >> u32(mip))
	roughness := f32(mip) / f32(mgr.ibl_total_mips - 1)

	// Y-range slicing (ISO: pbr_prefilter_mip lines_per_slice logic)
	lines_per_slice := (mip_h + total_slices - 1) / total_slices
	y_start := slice_index * lines_per_slice
	y_end := min(y_start + lines_per_slice, mip_h)
	actual_lines := y_end - y_start

	if actual_lines <= 0 {
		return
	}

	gl.BindImageTexture(1, mgr.pending_spec_tex, mip, false, 0, gl.WRITE_ONLY, gl.RGBA16F)
	gl.Uniform1f(gl.GetUniformLocation(ibl.spmap_program, "roughnessValue"), roughness)
	gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "currentMipLevel"), mip)
	gl.Uniform1f(gl.GetUniformLocation(ibl.spmap_program, "clamp_threshold"), mgr.ibl_clamp_threshold)
	gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "u_offset_y"), y_start)
	gl.Uniform1i(gl.GetUniformLocation(ibl.spmap_program, "u_max_y"), y_end)

	gx := (mip_w + 15) / 16
	gy := (actual_lines + 15) / 16
	gl.DispatchCompute(u32(gx), u32(gy), 1)
	// ISO C11: "No barrier here: caller is responsible for issuing a single
	// glMemoryBarrier after all slices are dispatched. Slices write to disjoint
	// Y-ranges of the same image, so no inter-slice coherency is required."
	// The single barrier is in .Done state before swap.
}

// Transition from specular to irradiance: select pending irradiance slot from pool.
@(private)
env_manager_start_irradiance :: proc(mgr: ^Env_Manager) {
	// Reuse pending slot from immutable pool (OPT-04: zero runtime allocation)
	pending_idx := 1 - mgr.pool_active_idx
	mgr.pending_irr_tex = mgr.irradiance_pool[pending_idx]

	mgr.ibl_current_slice = 0
	mgr.ibl_total_slices = mgr.compute_tuning.slicing.irdiff_slices
	env_manager_set_ibl_state(mgr, .Irradiance)
	log.log_info("suckless-odin.env", "IBL: Specular complete, starting irradiance on pooled texture (slot %d, %d slices)", pending_idx, mgr.compute_tuning.slicing.irdiff_slices)
}

// --- Internal: irradiance computation (ONE SLICE PER FRAME) ---
// ISO C11: process_irradiance in ibl_coordinator.c
// 12 Y-slices, one dispatched per frame.

@(private)
env_manager_process_irradiance_slice :: proc(mgr: ^Env_Manager, ibl: ^rendering.IBL_Resources) {
	dbg.push_group("IBL: Irradiance_Slice")
	defer dbg.pop_group()

	perf_zone := tracy.hybrid_perf_zone_begin(&tracy.SRCLOC_HYBRID_IRRADIANCE)
	defer tracy.hybrid_perf_zone_end(perf_zone)

	tracy.message_c(fmt.tprintf("IBL: Irradiance Slice %d/%d",
		mgr.ibl_current_slice + 1, mgr.ibl_total_slices), tracy.COLOR_IBL_IRRADIANCE)
	log.log_debug("suckless-odin.ibl", "Progressive IBL: Irradiance Slice %d/%d",
		mgr.ibl_current_slice + 1, mgr.ibl_total_slices)

	size := i32(rendering.IRRADIANCE_SIZE)

	// Y-range slicing (ISO: pbr_irradiance_slice_compute)
	lines_per_slice := (size + mgr.ibl_total_slices - 1) / mgr.ibl_total_slices
	y_start := mgr.ibl_current_slice * lines_per_slice
	y_end := min(y_start + lines_per_slice, size)
	actual_lines := y_end - y_start

	if actual_lines <= 0 {
		mgr.ibl_current_slice += 1
		if mgr.ibl_current_slice >= mgr.ibl_total_slices {
			env_manager_set_ibl_state(mgr, .Done)
			log.log_info("suckless-odin.env", "IBL: Irradiance complete")
		}
		return
	}

	gl.UseProgram(ibl.irmap_program)
	gl.ActiveTexture(gl.TEXTURE0)
	gl.BindTexture(gl.TEXTURE_2D, mgr.pending_hdr_tex)
	gl.BindImageTexture(1, mgr.pending_irr_tex, 0, false, 0, gl.WRITE_ONLY, gl.RGBA16F)
	gl.Uniform1f(gl.GetUniformLocation(ibl.irmap_program, "clamp_threshold"), mgr.ibl_clamp_threshold)
	gl.Uniform1i(gl.GetUniformLocation(ibl.irmap_program, "u_offset_y"), y_start)
	gl.Uniform1i(gl.GetUniformLocation(ibl.irmap_program, "u_max_y"), y_end)

	gx := (size + 15) / 16
	gy := (actual_lines + 3) / 4
	gl.DispatchCompute(u32(gx), u32(gy), 1)
	// ISO C11: no barrier between slices — disjoint Y-ranges.
	// Single barrier issued in .Done state before swap.
	gl.UseProgram(0)

	// Advance slice counter
	mgr.ibl_current_slice += 1
	if mgr.ibl_current_slice >= mgr.ibl_total_slices {
		env_manager_set_ibl_state(mgr, .Done)
		log.log_info("suckless-odin.env", "IBL: Irradiance complete")
	}
}

// --- Internal: capture screen snapshot (ISO: capture_snapshot) ---

@(private)
env_manager_capture_snapshot :: proc(mgr: ^Env_Manager, width, height: i32) {
	dbg.push_group("Env_Manager: Capture_Snapshot")
	defer dbg.pop_group()

	if mgr.transition_snapshot_tex == 0 {
		gl.GenTextures(1, &mgr.transition_snapshot_tex)
		gl.BindTexture(gl.TEXTURE_2D, mgr.transition_snapshot_tex)
		gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, width, height)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
		gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
		dbg.object_label(gl.TEXTURE, mgr.transition_snapshot_tex, "Env_Transition_Snapshot")
	} else {
		// Resize if dimensions changed
		gl.BindTexture(gl.TEXTURE_2D, mgr.transition_snapshot_tex)
		tex_w, tex_h: i32
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_WIDTH, &tex_w)
		gl.GetTexLevelParameteriv(gl.TEXTURE_2D, 0, gl.TEXTURE_HEIGHT, &tex_h)
		if tex_w != width || tex_h != height {
			gl.DeleteTextures(1, &mgr.transition_snapshot_tex)
			gl.GenTextures(1, &mgr.transition_snapshot_tex)
			gl.BindTexture(gl.TEXTURE_2D, mgr.transition_snapshot_tex)
			gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RGBA16F, width, height)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
			gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
			dbg.object_label(gl.TEXTURE, mgr.transition_snapshot_tex, "Env_Transition_Snapshot")
		}
	}

	gl.BindTexture(gl.TEXTURE_2D, mgr.transition_snapshot_tex)
	gl.CopyTexSubImage2D(gl.TEXTURE_2D, 0, 0, 0, 0, 0, width, height)
	gl.BindTexture(gl.TEXTURE_2D, 0)

	log.log_info("suckless-odin.env", "Env: Captured snapshot (%dx%d)", width, height)
}

// --- Internal: texture swap (IBL done → transfer to scene) ---

@(private)
env_manager_swap_textures :: proc(mgr: ^Env_Manager, scene: ^Scene) {
	// Instead of destroying scene.env_texture, recycle the HDR texture
	if scene.env_texture.id != 0 {
		if mgr.recycled_hdr_tex != 0 && mgr.recycled_hdr_tex != scene.env_texture.id {
			gl.DeleteTextures(1, &mgr.recycled_hdr_tex)
		}
		mgr.recycled_hdr_tex = scene.env_texture.id
		scene.env_texture.id = 0
	}

	// Swap active IBL pool slot (OPT-04: zero runtime allocation/deallocation)
	pending_idx := 1 - mgr.pool_active_idx
	scene.ibl.prefilter_map = mgr.specular_pool[pending_idx]
	scene.ibl.irradiance_map = mgr.irradiance_pool[pending_idx]
	mgr.pool_active_idx = pending_idx

	// Transfer pending HDR texture → active scene texture
	scene.env_texture.id = mgr.pending_hdr_tex
	scene.env_texture.width = mgr.async_result.width
	scene.env_texture.height = mgr.async_result.height

	// Clear pending handles (ownership transferred/pooled)
	mgr.pending_hdr_tex = 0
	mgr.pending_spec_tex = 0
	mgr.pending_irr_tex = 0

	mgr.is_first_load = false

	// Flag post-processing UBO as dirty
	scene.postfx_pipeline.ubo_dirty = true

	// Update skybox to use new env texture
	rendering.skybox_update_env(&scene.skybox, scene.env_texture.id, scene.ibl.prefilter_map)

	log.log_info("suckless-odin.env", "Environment textures swapped simultaneously (pool slot %d active)", mgr.pool_active_idx)
	elapsed_ms := time.duration_milliseconds(time.tick_since(mgr.load_start_tick))
	log.log_info("suckless-odin.ibl", "IBL environment ready in %.2f ms, descriptor set updated.", elapsed_ms)
}
