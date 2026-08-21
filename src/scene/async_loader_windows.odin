//+build windows
package scene

import "core:dynlib"
import "core:os"
import win32 "core:sys/windows"

@(private)
map_or_read_file :: proc(path_str: string, path_cstr: cstring) -> (mf: Mapped_File, ok: bool) {
	wpath := win32.utf8_to_wstring(path_str, context.temp_allocator)
	file_handle := win32.CreateFileW(
		wpath,
		win32.GENERIC_READ,
		win32.FILE_SHARE_READ,
		nil,
		win32.OPEN_EXISTING,
		win32.FILE_ATTRIBUTE_NORMAL,
		nil,
	)
	if file_handle != win32.INVALID_HANDLE_VALUE {
		defer win32.CloseHandle(file_handle)
		var_file_size: win32.LARGE_INTEGER
		if win32.GetFileSizeEx(file_handle, &var_file_size) && var_file_size > 0 {
			mapping_handle := win32.CreateFileMappingW(
				file_handle,
				nil,
				win32.PAGE_READONLY,
				0,
				0,
				nil,
			)
			if mapping_handle != nil {
				ptr := win32.MapViewOfFile(
					mapping_handle,
					win32.FILE_MAP_READ,
					0,
					0,
					0,
				)
				if ptr != nil {
					mf.data = cast([^]u8)ptr
					mf.size = uint(var_file_size)
					mf.is_mmap = true
					mf.handle = rawptr(mapping_handle)
					return mf, true
				}
				win32.CloseHandle(mapping_handle)
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
		win32.UnmapViewOfFile(rawptr(mf.data))
		if mf.handle != nil {
			win32.CloseHandle(win32.HANDLE(mf.handle))
			mf.handle = nil
		}
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

foreign import kernel32 "system:kernel32.lib"

@(default_calling_convention = "stdcall")
foreign kernel32 {
	GetCurrentThread  :: proc() -> rawptr ---
	SetThreadPriority :: proc(hThread: rawptr, nPriority: i32) -> i32 ---
}

THREAD_PRIORITY_ABOVE_NORMAL :: 1

Worker_Win32_Context :: struct {
	avrt_lib:    dynlib.Library,
	avrt_handle: rawptr,
}

@(private = "file")
g_worker_ctx: Worker_Win32_Context

@(private)
worker_os_init :: proc() {
	hThread := GetCurrentThread()
	SetThreadPriority(hThread, THREAD_PRIORITY_ABOVE_NORMAL)

	lib, ok := dynlib.load_library("avrt.dll")
	if ok {
		g_worker_ctx.avrt_lib = lib
		avrt_set_task, _ := dynlib.symbol_address(lib, "AvSetMmThreadCharacteristicsA")
		if avrt_set_task != nil {
			set_task := cast(proc "stdcall" (TaskName: cstring, TaskIndex: ^u32) -> rawptr)avrt_set_task
			task_index: u32 = 0
			g_worker_ctx.avrt_handle = set_task("Playback", &task_index)
		}
	}
}

@(private)
worker_os_cleanup :: proc() {
	if g_worker_ctx.avrt_lib != nil {
		if g_worker_ctx.avrt_handle != nil {
			avrt_revert_task, _ := dynlib.symbol_address(g_worker_ctx.avrt_lib, "AvRevertMmThreadCharacteristics")
			if avrt_revert_task != nil {
				revert_task := cast(proc "stdcall" (AvrtHandle: rawptr) -> i32)avrt_revert_task
				revert_task(g_worker_ctx.avrt_handle)
				g_worker_ctx.avrt_handle = nil
			}
		}
		dynlib.unload_library(g_worker_ctx.avrt_lib)
		g_worker_ctx.avrt_lib = nil
	}
}
