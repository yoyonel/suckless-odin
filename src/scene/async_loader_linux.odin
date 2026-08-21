package scene

import "core:os"
import posix "core:sys/posix"

@(private)
map_or_read_file :: proc(path_str: string, path_cstr: cstring) -> (mf: Mapped_File, ok: bool) {
	fd := posix.open(path_cstr, {})
	if fd >= 0 {
		defer posix.close(fd)
		stat: posix.stat_t
		if posix.fstat(fd, &stat) == .OK && stat.st_size > 0 {
			size := uint(stat.st_size)
			ptr := posix.mmap(nil, size, { .READ }, { .PRIVATE }, fd, 0)
			if ptr != posix.MAP_FAILED && ptr != nil {
				mf.data = cast([^]u8)ptr
				mf.size = size
				mf.is_mmap = true
				return mf, true
			}
		}
	}

	bytes, err := os.read_entire_file_from_path(path_str, context.allocator)
	if err == nil && len(bytes) > 0 {
		mf.data = raw_data(bytes)
		mf.size = uint(len(bytes))
		mf.is_mmap = false
		mf.raw_slice = bytes
		return mf, true
	}
	return mf, false
}

@(private)
unmap_file :: proc(mf: ^Mapped_File) {
	if mf.is_mmap && mf.data != nil && mf.size > 0 {
		posix.munmap(rawptr(mf.data), mf.size)
		mf.data = nil
		mf.size = 0
		return
	}
	if len(mf.raw_slice) > 0 {
		delete(mf.raw_slice)
		mf.raw_slice = nil
	}
	mf.data = nil
	mf.size = 0
}

@(private)
worker_os_init :: proc() {
}

@(private)
worker_os_cleanup :: proc() {
}
