package perf_mode

import "core:dynlib"
import "core:os"

import log "../log"

// Backend used for performance mode — ordered by preference.
Backend :: enum {
	None,
	Game_Mode,     // Feral GameMode (Linux: D-Bus → gamemoded)
	MMCSS,         // Windows MMCSS (avrt.dll → "Games" task)
	Sched_FIFO,    // Linux SCHED_FIFO real-time scheduling
	High_Priority, // Windows SetPriorityClass(HIGH_PRIORITY_CLASS)
	Nice,          // Linux setpriority(-10)
}

// Runtime state for the performance mode subsystem.
Perf_Mode :: struct {
	active:                   bool,
	backend:                  Backend,
	gamemode_lib:             dynlib.Library,
	gamemode_start:           proc "c" () -> i32,
	gamemode_end:             proc "c" () -> i32,
	gamemode_status:          proc "c" () -> i32,
	original_nice:            i32,
	original_policy:          i32,
	mesa_needs_restart:       bool,
	memory_locked:            bool,

	// Windows MMCSS & Thread Priority state
	avrt_lib:                 dynlib.Library,
	avrt_handle:              rawptr,
	avrt_set_task:            proc "stdcall" (TaskName: cstring, TaskIndex: ^u32) -> rawptr,
	avrt_revert_task:         proc "stdcall" (AvrtHandle: rawptr) -> i32,
	original_priority_class:  u32,
	original_thread_priority: i32,
}

// Initializes the performance mode subsystem (probes available backends).
// Does NOT activate — call activate() to turn on.
init :: proc(pm: ^Perf_Mode) {
	pm^ = {}
	os_init(pm)
}

// Activates the best available backend.
// When `quiet` is true, suppresses INFO logs (used for session restore).
// Returns true if successfully activated.
activate :: proc(pm: ^Perf_Mode, quiet := false) -> bool {
	if pm.active { return true }

	_ = os_activate(pm, quiet)

	// Set Mesa env vars (take effect on next GL context creation = restart)
	set_mesa_env(pm, quiet)

	if !pm.active && !pm.memory_locked {
		return false
	}
	pm.active = true
	return true
}

// Deactivates performance mode, restoring previous state.
deactivate :: proc(pm: ^Perf_Mode) {
	if !pm.active { return }

	os_deactivate(pm)

	log.log_info("PERF", "Performance mode OFF")
	pm.active = false
	pm.backend = .None
}

// Toggles performance mode on/off. Returns new active state.
toggle :: proc(pm: ^Perf_Mode) -> bool {
	if pm.active {
		deactivate(pm)
	} else {
		activate(pm)
	}
	return pm.active
}

// Cleans up resources (deactivates perf mode).
cleanup :: proc(pm: ^Perf_Mode) {
	if pm.active {
		deactivate(pm)
	}
	// We intentionally do not call dynlib.unload_library(pm.gamemode_lib) here.
	// Leaving the library mapped at exit is 100% safe as the OS reclaims all resources,
	// but keeping it loaded preserves the virtual memory mapping and symbol tables so
	// that Valgrind can resolve and suppress third-party system/D-Bus leaks.
	pm.gamemode_lib = nil
	pm.avrt_lib = nil
}

// Returns a human-readable label for the current backend.
backend_label :: proc(pm: ^Perf_Mode) -> string {
	if !pm.active { return "OFF" }
	switch pm.backend {
	case .Game_Mode:     return "GameMode"
	case .MMCSS:         return "MMCSS (Games)"
	case .Sched_FIFO:    return "SCHED_FIFO"
	case .High_Priority: return "High Priority"
	case .Nice:          return "Nice (-10)"
	case .None:          return "OFF"
	}
	return "OFF"
}

@(private)
mesa_env_already_set :: proc() -> bool {
	buf1: [8]u8
	buf2: [8]u8
	v1 := os.get_env_buf(buf1[:], "MESA_NO_ERROR")
	v2 := os.get_env_buf(buf2[:], "mesa_glthread")
	return v1 == "1" && v2 == "true"
}

@(private)
set_mesa_env :: proc(pm: ^Perf_Mode, quiet: bool) {
	// These env vars are read by Mesa at context creation time.
	// Setting them mid-session only takes effect on restart.
	// Skip if already set (e.g. setup_mesa_early called before context creation).
	if mesa_env_already_set() {
		return
	}
	err1 := os.set_env("MESA_NO_ERROR", "1")
	err2 := os.set_env("mesa_glthread", "true")
	if err1 == nil && err2 == nil {
		pm.mesa_needs_restart = true
		if !quiet {
			log.log_info("PERF", "Mesa env vars set (MESA_NO_ERROR=1, mesa_glthread=true) — restart needed")
		}
	}
}

// Call BEFORE GL context creation to apply Mesa optimizations immediately.
// Should be called from app init if session persists perf_mode as active.
setup_mesa_early :: proc() {
	os.set_env("MESA_NO_ERROR", "1")
	os.set_env("mesa_glthread", "true")
	log.log_info("PERF", "Mesa optimizations active (pre-context)")
}
