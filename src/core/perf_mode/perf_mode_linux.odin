#+build linux
package perf_mode

import "core:dynlib"
import "core:sys/linux"

import log "../log"

@(private)
os_init :: proc(pm: ^Perf_Mode) {
	probe_gamemode(pm)
}

@(private)
os_activate :: proc(pm: ^Perf_Mode, quiet: bool) -> bool {
	// Try backends in order of preference
	if try_gamemode(pm) {
		pm.backend = .Game_Mode
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (GameMode)") }
	} else if try_sched_fifo(pm) {
		pm.backend = .Sched_FIFO
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (SCHED_FIFO)") }
	} else if try_nice(pm) {
		pm.backend = .Nice
		pm.active = true
		if !quiet { log.log_info("PERF", "Performance mode ON (nice -10)") }
	} else {
		log.log_warning("PERF", "Performance mode: no scheduling backend available")
	}

	// Lock memory (prevents page-fault stutters)
	if !pm.memory_locked {
		// MCL_CURRENT=1, MCL_FUTURE=2 → 3
		errno := linux.mlockall(transmute(linux.MLock_Flags)u32(3))
		if errno == .NONE {
			pm.memory_locked = true
			if !quiet { log.log_info("PERF", "Memory locked (mlockall)") }
		} else if !quiet {
			log.log_debug("PERF", "mlockall failed (errno %v) — needs CAP_IPC_LOCK", errno)
		}
	}

	return pm.active || pm.memory_locked
}

@(private)
os_deactivate :: proc(pm: ^Perf_Mode) {
	switch pm.backend {
	case .Game_Mode:
		if pm.gamemode_end != nil {
			pm.gamemode_end()
		}
	case .Sched_FIFO:
		// Restore original scheduling policy (OTHER with priority 0)
		param := linux.Sched_Param{sched_priority = 0}
		linux.sched_setscheduler(linux.Pid(0), pm.original_policy, &param)
	case .Nice:
		linux.setpriority(.PROCESS, 0, pm.original_nice)
	case .MMCSS, .High_Priority, .None:
		// Windows backends or inactive: nothing to do on Linux
	}

	// Unlock memory
	if pm.memory_locked {
		linux.munlockall()
		pm.memory_locked = false
	}
}

@(private)
probe_gamemode :: proc(pm: ^Perf_Mode) {
	lib, ok := dynlib.load_library("libgamemode.so.0")
	if !ok {
		log.log_debug("PERF", "GameMode not available: %s", dynlib.last_error())
		return
	}
	pm.gamemode_lib = lib

	start_ptr, s_ok := dynlib.symbol_address(lib, "real_gamemode_request_start")
	end_ptr, e_ok   := dynlib.symbol_address(lib, "real_gamemode_request_end")
	status_ptr, q_ok := dynlib.symbol_address(lib, "real_gamemode_query_status")

	if !s_ok || !e_ok || !q_ok {
		log.log_debug("PERF", "GameMode: missing symbols")
		dynlib.unload_library(lib)
		pm.gamemode_lib = nil
		return
	}

	pm.gamemode_start  = cast(proc "c" () -> i32)start_ptr
	pm.gamemode_end    = cast(proc "c" () -> i32)end_ptr
	pm.gamemode_status = cast(proc "c" () -> i32)status_ptr
	log.log_debug("PERF", "GameMode probed successfully")
}

@(private)
try_gamemode :: proc(pm: ^Perf_Mode) -> bool {
	if pm.gamemode_start == nil { return false }
	ret := pm.gamemode_start()
	return ret == 0
}

@(private)
try_sched_fifo :: proc(pm: ^Perf_Mode) -> bool {
	// Save current policy
	pm.original_policy = 0  // SCHED_OTHER

	param := linux.Sched_Param{sched_priority = 50}
	errno := linux.sched_setscheduler(linux.Pid(0), 1, &param)  // 1 = SCHED_FIFO
	if errno != .NONE {
		log.log_debug("PERF", "SCHED_FIFO failed (errno %v) — need CAP_SYS_NICE or root", errno)
		return false
	}
	return true
}

@(private)
try_nice :: proc(pm: ^Perf_Mode) -> bool {
	// Save current nice value
	current, get_err := linux.getpriority(.PROCESS, 0)
	if get_err != .NONE {
		pm.original_nice = 0
	} else {
		pm.original_nice = current
	}

	set_err := linux.setpriority(.PROCESS, 0, -10)
	if set_err != .NONE {
		log.log_debug("PERF", "nice(-10) failed (errno %v)", set_err)
		return false
	}
	return true
}
