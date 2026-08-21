package perf_mode

@(private)
os_init :: proc(pm: ^Perf_Mode) {
}

@(private)
os_activate :: proc(pm: ^Perf_Mode, quiet: bool) -> bool {
	return false
}

@(private)
os_deactivate :: proc(pm: ^Perf_Mode) {
}
