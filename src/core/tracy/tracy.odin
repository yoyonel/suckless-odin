package tracy

TRACY_ENABLE :: #config(TRACY_ENABLE, false)

Source_Location_Data :: struct {
	name:     cstring,
	function: cstring,
	file:     cstring,
	line:     u32,
	color:    u32,
}

Zone_Context :: struct {
	id:     u32,
	active: i32,
}

Zone :: struct {
	ctx: Zone_Context,
}

Plot_Format :: enum i32 {
	Number     = 0,
	Memory     = 1,
	Percentage = 2,
	Watt       = 3,
}

when TRACY_ENABLE {
	when ODIN_OS == .Windows {
		foreign import libtracy "../../../deps/libtracy_windows_x64.lib"
	} else {
		foreign import libtracy "../../../deps/libtracy.a"
	}

	@(default_calling_convention="c")
	foreign libtracy {
		___tracy_set_thread_name :: proc(name: cstring) ---
		___tracy_emit_zone_begin :: proc(srcloc: ^Source_Location_Data, active: i32) -> Zone_Context ---
		___tracy_emit_zone_begin_callstack :: proc(srcloc: ^Source_Location_Data, depth: i32, active: i32) -> Zone_Context ---
		___tracy_emit_zone_end :: proc(ctx: Zone_Context) ---
		___tracy_emit_zone_text :: proc(ctx: Zone_Context, txt: cstring, size: uint) ---
		___tracy_emit_zone_name :: proc(ctx: Zone_Context, txt: cstring, size: uint) ---
		___tracy_emit_zone_color :: proc(ctx: Zone_Context, color: u32) ---
		___tracy_emit_zone_value :: proc(ctx: Zone_Context, value: u64) ---
		___tracy_emit_frame_mark :: proc(name: cstring) ---
		___tracy_fiber_enter :: proc(fiber: cstring) ---
		___tracy_fiber_leave :: proc() ---

		___tracy_alloc_srcloc :: proc(line: u32, source: cstring, sourceSz: uint, function: cstring, functionSz: uint, color: u32) -> u64 ---
		___tracy_emit_zone_begin_alloc :: proc(srcloc: u64, active: i32) -> Zone_Context ---
		___tracy_emit_message :: proc(txt: cstring, size: uint, callstack_depth: i32) ---
		___tracy_emit_messageC :: proc(txt: cstring, size: uint, color: u32, callstack_depth: i32) ---

		// Real-time plots
		___tracy_emit_plot :: proc(name: cstring, val: f64) ---
		___tracy_emit_plot_float :: proc(name: cstring, val: f32) ---
		___tracy_emit_plot_int :: proc(name: cstring, val: i64) ---
		___tracy_emit_plot_config :: proc(name: cstring, type: i32, step: i32, fill: i32, color: u32) ---

		// Memory tracking
		___tracy_emit_memory_alloc :: proc(ptr: rawptr, size: uint, secure: i32) ---
		___tracy_emit_memory_free :: proc(ptr: rawptr, secure: i32) ---
		___tracy_emit_memory_alloc_named :: proc(ptr: rawptr, size: uint, secure: i32, name: cstring) ---
		___tracy_emit_memory_free_named :: proc(ptr: rawptr, secure: i32, name: cstring) ---

		// GPU Profiling functions from tracy_gpu.cpp
		tracy_gpu_init :: proc() ---
		tracy_gpu_shutdown :: proc() ---
		tracy_gpu_collect :: proc() ---
		tracy_gpu_screenshot :: proc(data: rawptr, w, h: u16) ---
		tracy_gpu_zone_begin :: proc(name, function, file: cstring, line, color: u32) -> rawptr ---
		tracy_gpu_zone_end :: proc(ctx: rawptr) ---
	}
}

set_thread_name :: #force_inline proc(name: cstring) {
	when TRACY_ENABLE {
		___tracy_set_thread_name(name)
	}
}

zone_begin :: #force_inline proc(loc: ^Source_Location_Data) -> Zone {
	when TRACY_ENABLE {
		return Zone{___tracy_emit_zone_begin(loc, 1)}
	} else {
		return {}
	}
}

zone_end :: #force_inline proc(zone: Zone) {
	when TRACY_ENABLE {
		___tracy_emit_zone_end(zone.ctx)
	}
}

frame_mark :: #force_inline proc(name: cstring = nil) {
	when TRACY_ENABLE {
		___tracy_emit_frame_mark(name)
	}
}

fiber_enter :: #force_inline proc(name: cstring) {
	when TRACY_ENABLE {
		___tracy_fiber_enter(name)
	}
}

fiber_leave :: #force_inline proc() {
	when TRACY_ENABLE {
		___tracy_fiber_leave()
	}
}

plot :: #force_inline proc(name: cstring, val: f64) {
	when TRACY_ENABLE {
		___tracy_emit_plot(name, val)
	}
}

plot_f32 :: #force_inline proc(name: cstring, val: f32) {
	when TRACY_ENABLE {
		___tracy_emit_plot_float(name, val)
	}
}

plot_i64 :: #force_inline proc(name: cstring, val: i64) {
	when TRACY_ENABLE {
		___tracy_emit_plot_int(name, val)
	}
}

plot_config :: #force_inline proc(name: cstring, type: Plot_Format, step: bool = false, fill: bool = true, color: u32 = 0) {
	when TRACY_ENABLE {
		___tracy_emit_plot_config(name, i32(type), i32(1 if step else 0), i32(1 if fill else 0), color)
	}
}

alloc :: #force_inline proc(ptr: rawptr, size: uint) {
	when TRACY_ENABLE {
		___tracy_emit_memory_alloc(ptr, size, 0)
	}
}

free :: #force_inline proc(ptr: rawptr) {
	when TRACY_ENABLE {
		___tracy_emit_memory_free(ptr, 0)
	}
}

alloc_named :: #force_inline proc(ptr: rawptr, size: uint, name: cstring) {
	when TRACY_ENABLE {
		___tracy_emit_memory_alloc_named(ptr, size, 0, name)
	}
}

free_named :: #force_inline proc(ptr: rawptr, name: cstring) {
	when TRACY_ENABLE {
		___tracy_emit_memory_free_named(ptr, 0, name)
	}
}

gpu_init :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_init()
	}
}

gpu_collect :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_collect()
	}
}

gpu_screenshot :: #force_inline proc(data: rawptr, w, h: u16) {
	when TRACY_ENABLE {
		tracy_gpu_screenshot(data, w, h)
	}
}

gpu_zone_begin :: #force_inline proc(name, function, file: cstring, line, color: u32) -> rawptr {
	when TRACY_ENABLE {
		return tracy_gpu_zone_begin(name, function, file, line, color)
	} else {
		return nil
	}
}

gpu_zone_end :: #force_inline proc(ctx: rawptr) {
	when TRACY_ENABLE {
		tracy_gpu_zone_end(ctx)
	}
}

gpu_shutdown :: #force_inline proc() {
	when TRACY_ENABLE {
		tracy_gpu_shutdown()
	}
}

alloc_srcloc :: #force_inline proc(line: u32, source, function: cstring, color: u32) -> u64 {
	when TRACY_ENABLE {
		return ___tracy_alloc_srcloc(line, source, uint(len(source)), function, uint(len(function)), color)
	} else {
		return 0
	}
}

zone_begin_alloc :: #force_inline proc(srcloc: u64) -> Zone {
	when TRACY_ENABLE {
		return Zone{___tracy_emit_zone_begin_alloc(srcloc, 1)}
	} else {
		return {}
	}
}

message :: #force_inline proc(msg: string) {
	when TRACY_ENABLE {
		___tracy_emit_message(cstring(raw_data(msg)), uint(len(msg)), 0)
	}
}

message_c :: #force_inline proc(msg: string, color: u32) {
	when TRACY_ENABLE {
		___tracy_emit_messageC(cstring(raw_data(msg)), uint(len(msg)), color, 0)
	}
}
