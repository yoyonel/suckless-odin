#+build windows
package perf_mode

import "core:dynlib"
import log "../log"

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
	GetCurrentProcess :: proc() -> rawptr ---
	GetCurrentThread  :: proc() -> rawptr ---
	SetPriorityClass  :: proc(hProcess: rawptr, dwPriorityClass: u32) -> i32 ---
	GetPriorityClass  :: proc(hProcess: rawptr) -> u32 ---
	SetThreadPriority :: proc(hThread: rawptr, nPriority: i32) -> i32 ---
	GetThreadPriority :: proc(hThread: rawptr) -> i32 ---
}

HIGH_PRIORITY_CLASS         :: 0x00000080
ABOVE_NORMAL_PRIORITY_CLASS :: 0x00008000
NORMAL_PRIORITY_CLASS       :: 0x00000020

THREAD_PRIORITY_HIGHEST      :: 2
THREAD_PRIORITY_ABOVE_NORMAL :: 1
THREAD_PRIORITY_NORMAL       :: 0

@(private)
os_init :: proc(pm: ^Perf_Mode) {
	probe_avrt(pm)
}

@(private)
os_activate :: proc(pm: ^Perf_Mode, quiet: bool) -> bool {
	// Save initial priorities
	hProcess := GetCurrentProcess()
	hThread := GetCurrentThread()
	pm.original_priority_class = GetPriorityClass(hProcess)
	pm.original_thread_priority = GetThreadPriority(hThread)

	// 1. Try MMCSS ("Games" task) via avrt.dll
	if pm.avrt_set_task != nil {
		task_index: u32 = 0
		handle := pm.avrt_set_task("Games", &task_index)
		if handle != nil {
			pm.avrt_handle = handle
			pm.backend = .MMCSS
			pm.active = true
			if !quiet { log.log_info("PERF", "Performance mode ON (Windows MMCSS: Games)") }
			return true
		}
	}

	// 2. Fallback: Elevate process to HIGH_PRIORITY_CLASS and thread to THREAD_PRIORITY_HIGHEST
	if SetPriorityClass(hProcess, HIGH_PRIORITY_CLASS) != 0 {
		SetThreadPriority(hThread, THREAD_PRIORITY_HIGHEST)
		pm.backend = .High_Priority
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (Windows High Priority)") }
		return true
	} else if SetPriorityClass(hProcess, ABOVE_NORMAL_PRIORITY_CLASS) != 0 {
		SetThreadPriority(hThread, THREAD_PRIORITY_ABOVE_NORMAL)
		pm.backend = .High_Priority
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (Windows Above Normal Priority)") }
		return true
	}

	return false
}

@(private)
os_deactivate :: proc(pm: ^Perf_Mode) {
	hProcess := GetCurrentProcess()
	hThread := GetCurrentThread()

	if pm.backend == .MMCSS && pm.avrt_handle != nil && pm.avrt_revert_task != nil {
		pm.avrt_revert_task(pm.avrt_handle)
		pm.avrt_handle = nil
	}

	if pm.original_priority_class != 0 {
		SetPriorityClass(hProcess, pm.original_priority_class)
	}
	SetThreadPriority(hThread, pm.original_thread_priority)
}

@(private)
probe_avrt :: proc(pm: ^Perf_Mode) {
	lib, ok := dynlib.load_library("avrt.dll")
	if !ok {
		log.log_debug("PERF", "avrt.dll not available: %s", dynlib.last_error())
		return
	}
	pm.avrt_lib = lib

	set_ptr, s_ok := dynlib.symbol_address(lib, "AvSetMmThreadCharacteristicsA")
	rev_ptr, r_ok := dynlib.symbol_address(lib, "AvRevertMmThreadCharacteristics")

	if !s_ok || !r_ok {
		log.log_debug("PERF", "avrt.dll: missing MMCSS symbols")
		dynlib.unload_library(lib)
		pm.avrt_lib = nil
		return
	}

	pm.avrt_set_task    = cast(proc "stdcall" (cstring, ^u32) -> rawptr)set_ptr
	pm.avrt_revert_task = cast(proc "stdcall" (rawptr) -> i32)rev_ptr
	log.log_debug("PERF", "Windows MMCSS probed successfully")
}
