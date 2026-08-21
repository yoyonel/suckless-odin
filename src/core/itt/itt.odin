package itt

import "core:dynlib"
import "core:os"
import "core:strings"

import log "../log"

// Intel Instrumentation and Tracing Technology (ITT) API wrapper.
// Enables programmatic control of Intel VTune Profiler (pause/resume collection, named tasks).
// Zero-overhead when VTune is not running; dynamically resolves symbols at runtime.

Domain_Handle :: distinct rawptr
String_Handle :: distinct rawptr

@(private)
ITT_State :: struct {
	available:    bool,
	pause_fn:     #type proc "c" (),
	resume_fn:    #type proc "c" (),
	domain_fn:    #type proc "c" (name: cstring) -> Domain_Handle,
	string_fn:    #type proc "c" (name: cstring) -> String_Handle,
	task_begin_fn:#type proc "c" (domain: Domain_Handle, task_id: rawptr, parent_id: rawptr, name: String_Handle),
	task_end_fn:  #type proc "c" (domain: Domain_Handle),
	
	default_domain: Domain_Handle,
}

@(private)
g_itt: ITT_State

// Initialize ITT subsystem. Probes process environment and dynamic symbols.
init :: proc() -> bool {
	if g_itt.available { return true }

	// Try loading from current process or INTEL_LIBITTNOTIFY64 if set
	lib_handle: dynlib.Library
	ok := false

	itt_env_path := os.get_env("INTEL_LIBITTNOTIFY64", context.temp_allocator)
	if len(itt_env_path) > 0 {
		lib_handle, ok = dynlib.load_library(itt_env_path)
	}

	if !ok {
		// Try resolving from already loaded modules in the process
		when ODIN_OS == .Linux || ODIN_OS == .Darwin {
			lib_handle, ok = dynlib.load_library("libittnotify.so")
		} else when ODIN_OS == .Windows {
			lib_handle, ok = dynlib.load_library("libittnotify.dll")
		}
	}

	if !ok {
		log.log_debug("ITT", "Intel ITT API not active (running outside VTune)")
		return false
	}

	pause_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_pause")
	resume_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_resume")
	domain_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_domain_createA")
	string_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_string_handle_createA")
	task_begin_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_task_begin")
	task_end_ptr, _ := dynlib.symbol_address(lib_handle, "__itt_task_end")

	if pause_ptr != nil && resume_ptr != nil {
		g_itt.pause_fn = cast(#type proc "c" ())pause_ptr
		g_itt.resume_fn = cast(#type proc "c" ())resume_ptr
		if domain_ptr != nil { g_itt.domain_fn = cast(#type proc "c" (name: cstring) -> Domain_Handle)domain_ptr }
		if string_ptr != nil { g_itt.string_fn = cast(#type proc "c" (name: cstring) -> String_Handle)string_ptr }
		if task_begin_ptr != nil { g_itt.task_begin_fn = cast(#type proc "c" (domain: Domain_Handle, task_id: rawptr, parent_id: rawptr, name: String_Handle))task_begin_ptr }
		if task_end_ptr != nil { g_itt.task_end_fn = cast(#type proc "c" (domain: Domain_Handle))task_end_ptr }

		if g_itt.domain_fn != nil {
			g_itt.default_domain = g_itt.domain_fn("suckless.odin")
		}

		g_itt.available = true
		log.log_info("ITT", "Intel VTune ITT API connected successfully (programmatic collection active)")
		return true
	}

	return false
}

// Pause VTune collection (reduces trace size and overhead).
pause :: proc() {
	if g_itt.available && g_itt.pause_fn != nil {
		g_itt.pause_fn()
	}
}

// Resume VTune collection (targets critical sections like IBL computation).
resume :: proc() {
	if g_itt.available && g_itt.resume_fn != nil {
		g_itt.resume_fn()
	}
}

// Begin a named task on the VTune timeline.
task_begin :: proc(name: string) {
	if g_itt.available && g_itt.task_begin_fn != nil && g_itt.string_fn != nil {
		c_name := strings.clone_to_cstring(name, context.temp_allocator)
		str_handle := g_itt.string_fn(c_name)
		g_itt.task_begin_fn(g_itt.default_domain, nil, nil, str_handle)
	}
}

// End the current named task on the VTune timeline.
task_end :: proc() {
	if g_itt.available && g_itt.task_end_fn != nil {
		g_itt.task_end_fn(g_itt.default_domain)
	}
}

// Check if VTune ITT is connected.
is_active :: proc() -> bool {
	return g_itt.available
}
