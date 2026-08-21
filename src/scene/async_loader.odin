package scene

// Asynchronous HDR file loader — dedicated worker thread for I/O + decode.
// ISO C11: async_loader.c (pthread model ported to Odin core:thread + core:sync).
//
// Lifecycle:
//   IDLE → PENDING → LOADING → READY (or FAILED)
//
// The main thread submits a path via async_loader_request(), then polls
// with async_loader_poll() each frame. When state reaches READY the
// decoded float data is available for GPU upload.

import "core:c"
import "core:c/libc"
import "core:fmt"
import "core:sync"
import "core:thread"

import stbi "vendor:stb/image"

import log "../core/log"
import simd "../core/simd_utils"
import tracy "../core/tracy"

// --- Async state machine (ISO: AsyncState enum) ---

Async_State :: enum {
	Idle,
	Pending,
	Loading,
	Ready,
	Failed,
}

Async_Poll_Result :: enum {
	Busy,
	Ready,
	Failed,
}

// --- Async request data (ISO: AsyncRequest struct) ---

ASYNC_MAX_PATH :: 256

Async_Request :: struct {
	path:     [ASYNC_MAX_PATH]u8, // null-terminated path
	data:     [^]u16,             // decoded RGBA float16 pixels (SIMD-converted from FP32)
	width:    i32,
	height:   i32,
	channels: i32,
	state:    Async_State,
}

// --- Async loader (ISO: AsyncLoader struct) ---

Async_Loader :: struct {
	request:       Async_Request,
	mutex:         sync.Mutex,
	cond:          sync.Cond,
	worker:        ^thread.Thread,
	running:       bool,
	has_pending:   bool,
}

// --- Public API ---

async_loader_create :: proc(loader: ^Async_Loader) -> bool {
	loader.request.state = .Idle
	loader.running = true
	loader.has_pending = false

	tracy.async_status_init()

	loader.worker = thread.create(async_worker_proc)
	if loader.worker == nil {
		log.log_error("suckless-odin.async", "Failed to create worker thread")
		return false
	}
	loader.worker.data = loader
	thread.start(loader.worker)

	log.log_info("suckless-odin.async", "Async loader initialized")
	return true
}

async_loader_destroy :: proc(loader: ^Async_Loader) {
	// Signal shutdown
	sync.lock(&loader.mutex)
	loader.running = false
	sync.signal(&loader.cond)
	sync.unlock(&loader.mutex)

	// Join worker thread
	if loader.worker != nil {
		thread.join(loader.worker)
		thread.destroy(loader.worker)
		loader.worker = nil
	}

	// Free any unconsumed data (FP16 buffer allocated via libc.malloc)
	if loader.request.data != nil {
		libc.free(loader.request.data)
		loader.request.data = nil
	}

	tracy.async_status_shutdown()
	log.log_info("suckless-odin.async", "Async loader destroyed")
}

// Submit a new load request. Returns false if the loader is busy.
async_loader_request :: proc(loader: ^Async_Loader, path: string) -> bool {
	if len(path) == 0 || len(path) >= ASYNC_MAX_PATH - 1 {
		log.log_error("suckless-odin.async", "Invalid path length: %d", len(path))
		return false
	}

	sync.lock(&loader.mutex)
	defer sync.unlock(&loader.mutex)

	// Only accept if idle, failed, or previous result was consumed
	#partial switch loader.request.state {
	case .Idle, .Failed, .Ready:
		// OK — accept new request
	case:
		log.log_warning("suckless-odin.async", "Loader busy (state=%v), request rejected", loader.request.state)
		return false
	}

	// Free any unconsumed previous data (FP16 buffer)
	if loader.request.data != nil {
		libc.free(loader.request.data)
		loader.request.data = nil
	}

	// Copy path into request buffer
	for i in 0..<len(path) {
		loader.request.path[i] = path[i]
	}
	loader.request.path[len(path)] = 0

	loader.request.state = .Pending
	loader.has_pending = true
	tracy.async_status_transition(.Pending)
	sync.signal(&loader.cond)

	log.log_info("suckless-odin.async", "Request submitted: %s", cstring(&loader.request.path[0]))
	return true
}

// Poll for a completed result. Returns Async_Poll_Result.
// On Ready, ownership of `out.data` transfers to caller (must free with stbi.image_free).
async_loader_poll :: proc(loader: ^Async_Loader, out: ^Async_Request) -> Async_Poll_Result {
	when ODIN_DEBUG {
		assert(out != nil, "Pre-condition Violated: Output request pointer is nil")
	}

	sync.lock(&loader.mutex)
	defer sync.unlock(&loader.mutex)

	if loader.request.state == .Ready {
		when ODIN_DEBUG {
			assert(loader.request.data != nil, "Invariant Violated: Loader state is Ready but data buffer is nil")
		}
		out^ = loader.request
		// Transfer ownership — clear internal pointer
		loader.request.data = nil
		loader.request.state = .Idle
		tracy.async_status_transition(.Idle)
		return .Ready
	}

	if loader.request.state == .Failed {
		log.log_error("suckless-odin.async", "Async load failed for: %s", cstring(&loader.request.path[0]))
		loader.request.state = .Idle
		tracy.async_status_transition(.Idle)
		return .Failed
	}

	return .Busy
}

// --- Worker thread proc ---

@(private)
hdr_load_decode_loc := tracy.Source_Location_Data{
	name     = "Async Loader: Decode File",
	function = "async_worker_proc",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_IO_DECODE,
}

@(private)
float_half_convert_loc := tracy.Source_Location_Data{
	name     = "Async Loader: SIMD Conversion",
	function = "async_worker_proc",
	file     = #file,
	line     = #line,
	color    = tracy.COLOR_IO_CONVERT,
}

Mapped_File :: struct {
	data:      [^]u8,
	size:      uint,
	is_mmap:   bool,
	raw_slice: []u8,
	handle:    rawptr,
}

@(private)
alloc_aligned_fp16 :: proc(pixel_count: uint) -> [^]u16 {
	alloc_size := (pixel_count * size_of(u16) + 63) & ~uint(63)
	ptr := cast([^]u16)libc.aligned_alloc(64, alloc_size)
	if ptr == nil {
		ptr = cast([^]u16)libc.malloc(pixel_count * size_of(u16))
	}
	return ptr
}

@(private)
async_worker_proc :: proc(t: ^thread.Thread) {
	loader := cast(^Async_Loader)t.data

	// Platform-specific worker thread scheduling & priority initialization
	worker_os_init()
	defer worker_os_cleanup()

	// Name this thread in Tracy so it appears as a separate lane
	tracy.set_thread_name("AsyncLoader")

	sync.lock(&loader.mutex)
	for loader.running {
		// Wait for work
		for loader.running && !loader.has_pending {
			sync.wait(&loader.cond, &loader.mutex)
		}

		if !loader.running {
			break
		}

		// Extract path to load
		if loader.request.state != .Pending {
			loader.has_pending = false
			continue
		}

		loader.request.state = .Loading
		loader.has_pending = false
		tracy.async_status_transition(.Loading)

		// Copy path out before unlocking
		path_cstr := cstring(&loader.request.path[0])

		// Unlock during heavy I/O
		sync.unlock(&loader.mutex)

		// --- Heavy I/O (disk read + decode) — Tracy zone ---
		zone := tracy.zone_begin(&hdr_load_decode_loc)
		tracy.message_c(fmt.tprintf("Loading HDR: %s", path_cstr), tracy.COLOR_IO_DECODE)

		path_str := string(path_cstr)
		mf, map_ok := map_or_read_file(path_str, path_cstr)

		w, h: i32
		half_data: [^]u16

		if map_ok && mf.size > 0 {
			if simd.fast_hdr_get_dimensions(mf.data, mf.size, &w, &h) != 0 {
				pixel_count := uint(w) * uint(h) * 4 // RGBA
				half_data = alloc_aligned_fp16(pixel_count)
				if half_data != nil {
					if simd.fast_hdr_decode_fp16_threaded(mf.data, mf.size, &w, &h, half_data, pixel_count, 1, 8) == 0 {
						libc.free(half_data)
						half_data = nil
					}
				}
			}

			// Fallback to STB image if fast direct decoder encounters an unsupported non-RLE format
			if half_data == nil {
				stbi.set_flip_vertically_on_load(1)
				w_c, h_c, channels: c.int
				data := stbi.loadf_from_memory(mf.data, c.int(mf.size), &w_c, &h_c, &channels, 4)
				if data != nil {
					w = i32(w_c)
					h = i32(h_c)
					pixel_count := uint(w) * uint(h) * 4
					half_data = alloc_aligned_fp16(pixel_count)
					if half_data != nil {
						simd.convert_float_to_half_simd(data, half_data, pixel_count)
					}
					stbi.image_free(data)
				}
			}
			unmap_file(&mf)
		} else {

			// Direct file fallback if os.read_entire_file failed
			stbi.set_flip_vertically_on_load(1)
			w_c, h_c, channels: c.int
			data := stbi.loadf(path_cstr, &w_c, &h_c, &channels, 4)
			if data != nil {
				w = i32(w_c)
				h = i32(h_c)
				pixel_count := uint(w) * uint(h) * 4
				half_data = alloc_aligned_fp16(pixel_count)
				if half_data != nil {
					simd.convert_float_to_half_simd(data, half_data, pixel_count)
				}
				stbi.image_free(data)
			}
		}

		tracy.zone_end(zone)

		if half_data != nil {
			tracy.async_status_transition(.Convert)
			conv_zone := tracy.zone_begin(&float_half_convert_loc)
			pixel_count := uint(w) * uint(h) * 4
			tracy.zone_end(conv_zone)
			tracy.message_c(fmt.tprintf("Direct Decoded HDR->FP16: %dx%d (%d KB)",
				w, h, pixel_count * 2 / 1024), tracy.COLOR_IO_CONVERT)
		}

		// Re-acquire mutex to update state
		sync.lock(&loader.mutex)

		if half_data == nil {
			loader.request.state = .Failed
			tracy.async_status_transition(.Failed)
			tracy.message_c(fmt.tprintf("FAILED: %s", path_cstr), tracy.COLOR_IO_FAILED)
			log.log_error("suckless-odin.async", "Failed to load HDR image: %s", path_cstr)
		} else {
			loader.request.data = half_data
			loader.request.width = i32(w)
			loader.request.height = i32(h)
			loader.request.channels = 4
			loader.request.state = .Ready
			tracy.async_status_transition(.Ready)
			tracy.message_c(fmt.tprintf("Loaded: %s (%dx%d, FP16)", path_cstr, w, h), tracy.COLOR_IO_READY)
			log.log_info("suckless-odin.async", "Loaded: %s (%dx%d, FP16)", path_cstr, w, h)
		}
	}
	sync.unlock(&loader.mutex)
}
