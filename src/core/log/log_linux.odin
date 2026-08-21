#+build linux
package applog

import "core:sys/linux"

@(private)
get_pid_tid :: proc() -> (i64, i64) {
	return i64(linux.getpid()), i64(linux.gettid())
}
