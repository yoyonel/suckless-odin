package applog

import "core:fmt"
import "core:time"
import tracy "../tracy"

// Severity levels for log filtering (mirrors C version)
Log_Level :: enum {
	Not_Set  = 0,
	Debug    = 10,
	Info     = 20,
	Warning  = 30,
	Error    = 40,
	Critical = 50,
}

// Callback type for log message interception
Log_Callback :: #type proc(level: Log_Level, tag: string, message: string)

// Module-level state
@(private)
g_log_callback: Log_Callback = nil

@(private)
g_min_level: Log_Level = .Debug

// Sets a custom callback for log messages
set_callback :: proc(callback: Log_Callback) {
	g_log_callback = callback
}

// Sets the global minimum log level
set_level :: proc(level: Log_Level) {
	g_min_level = level
}

// Core log function — format matches legacy C11:
// "2026-05-15 23:35:02,089 [PID:TID] - tag - LEVEL    - message"
log_message :: proc(level: Log_Level, tag: string, format: string, args: ..any) {
	if int(level) < int(g_min_level) {
		return
	}

	message := fmt.tprintf(format, ..args)
	level_str := level_to_string(level)

	now := time.now()
	year, month, day := time.date(now)
	hour, min, sec := time.clock(now)
	ms := time.duration_milliseconds(time.Duration(now._nsec % 1_000_000_000)) 

	pid, tid := get_pid_tid()

	formatted := fmt.tprintf("%04d-%02d-%02d %02d:%02d:%02d,%03d [%d:%d] - %s - %-8s - %s",
		year, int(month), day, hour, min, sec, int(ms), int(pid), int(tid),
		tag, level_str, message)

	if g_log_callback != nil {
		g_log_callback(level, tag, message)
	}

	when tracy.TRACY_ENABLE {
		color: u32
		switch level {
		case .Debug:            color = tracy.COLOR_LOG_DEBUG
		case .Info:             color = tracy.COLOR_LOG_INFO
		case .Warning:          color = tracy.COLOR_LOG_WARNING
		case .Error, .Critical: color = tracy.COLOR_LOG_ERROR
		case .Not_Set:          color = tracy.COLOR_LOG_DEBUG
		}
		tracy.message_c(formatted, color)
	}

	if int(level) >= int(Log_Level.Error) {
		fmt.eprintln(formatted)
	} else {
		fmt.println(formatted)
	}
}

// Convenience wrappers
log_debug :: proc(tag: string, format: string, args: ..any) {
	log_message(.Debug, tag, format, ..args)
}

log_info :: proc(tag: string, format: string, args: ..any) {
	log_message(.Info, tag, format, ..args)
}

log_warning :: proc(tag: string, format: string, args: ..any) {
	log_message(.Warning, tag, format, ..args)
}

log_error :: proc(tag: string, format: string, args: ..any) {
	log_message(.Error, tag, format, ..args)
}

log_critical :: proc(tag: string, format: string, args: ..any) {
	log_message(.Critical, tag, format, ..args)
}

@(private)
level_to_string :: proc(level: Log_Level) -> string {
	switch level {
	case .Not_Set:  return "NOTSET"
	case .Debug:    return "DEBUG"
	case .Info:     return "INFO"
	case .Warning:  return "WARNING"
	case .Error:    return "ERROR"
	case .Critical: return "CRITICAL"
	}
	return "UNKNOWN"
}
