#+build windows
package applog

import "core:sys/windows"

@(private)
get_pid_tid :: proc() -> (i64, i64) {
	return i64(windows.GetCurrentProcessId()), i64(windows.GetCurrentThreadId())
}
