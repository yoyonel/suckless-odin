package renderdoc

import "core:c"
import "core:dynlib"
import "core:strings"

import log "../log"

// RenderDoc In-App Capture API (v1.4.0) wrapper.
// Enables programmatic frame and multi-frame captures directly from Odin code.
// Zero-overhead when RenderDoc is not attached.

RENDERDOC_API_Version :: enum c.int {
	eRENDERDOC_API_Version_1_0_0 = 10000,
	eRENDERDOC_API_Version_1_1_0 = 10100,
	eRENDERDOC_API_Version_1_2_0 = 10200,
	eRENDERDOC_API_Version_1_3_0 = 10300,
	eRENDERDOC_API_Version_1_4_0 = 10400,
	eRENDERDOC_API_Version_1_5_0 = 10500,
	eRENDERDOC_API_Version_1_6_0 = 10600,
}

RENDERDOC_DevicePointer :: rawptr
RENDERDOC_WindowHandle  :: rawptr

pRENDERDOC_GetAPI :: #type proc "c" (version: RENDERDOC_API_Version, outAPIPointers: ^rawptr) -> c.int

API_1_4_0 :: struct {
	GetAPIVersion:              #type proc "c" (major, minor, patch: ^c.int),
	SetCaptureOptionF32:        #type proc "c" (opt: c.int, val: c.float) -> c.int,
	SetCaptureOptionU32:        #type proc "c" (opt: c.int, val: c.uint32_t) -> c.int,
	GetCaptureOptionF32:        #type proc "c" (opt: c.int) -> c.float,
	GetCaptureOptionU32:        #type proc "c" (opt: c.int) -> c.uint32_t,
	SetFocusToggleKeys:         #type proc "c" (keys: ^c.int, num: c.int),
	SetCaptureKeys:             #type proc "c" (keys: ^c.int, num: c.int),
	GetOverlayBits:             #type proc "c" () -> c.uint32_t,
	MaskOverlayBits:            #type proc "c" (And: c.uint32_t, Or: c.uint32_t),
	RemoveHooks:                #type proc "c" (),
	UnloadCrashHandler:         #type proc "c" (),
	SetCaptureFilePathTemplate: #type proc "c" (pathtemplate: cstring),
	GetCaptureFilePathTemplate: #type proc "c" () -> cstring,
	GetNumCaptures:             #type proc "c" () -> c.uint32_t,
	GetCapture:                 #type proc "c" (idx: c.uint32_t, filename: cstring, pathlength: ^c.uint32_t, timestamp: ^c.uint64_t) -> c.uint32_t,
	TriggerCapture:             #type proc "c" (),
	IsRemoteAccessConnected:    #type proc "c" () -> c.uint32_t,
	LaunchReplayUI:             #type proc "c" (connectTargetControl: c.uint32_t, cmdline: cstring) -> c.uint32_t,
	UnloadAndExit:              #type proc "c" (),
	StartFrameCapture:          #type proc "c" (device: RENDERDOC_DevicePointer, wndHandle: RENDERDOC_WindowHandle),
	IsFrameCapturing:           #type proc "c" () -> c.uint32_t,
	EndFrameCapture:            #type proc "c" (device: RENDERDOC_DevicePointer, wndHandle: RENDERDOC_WindowHandle) -> c.uint32_t,
	TriggerMultiFrameCapture:   #type proc "c" (numFrames: c.uint32_t),
	SetCaptureFileComments:     #type proc "c" (filePath: cstring, comments: cstring),
	DiscardFrameCapture:        #type proc "c" (device: RENDERDOC_DevicePointer, wndHandle: RENDERDOC_WindowHandle) -> c.uint32_t,
}

@(private)
RenderDoc_State :: struct {
	available: bool,
	api:       ^API_1_4_0,
}

@(private)
g_rdoc: RenderDoc_State

// Initialize RenderDoc in-app API by probing loaded dynamic library.
init :: proc() -> bool {
	if g_rdoc.available { return true }

	lib_handle: dynlib.Library
	ok := false

	when ODIN_OS == .Linux || ODIN_OS == .Darwin {
		lib_handle, ok = dynlib.load_library("librenderdoc.so")
	} else when ODIN_OS == .Windows {
		lib_handle, ok = dynlib.load_library("renderdoc.dll")
	}

	if !ok {
		log.log_debug("RenderDoc", "RenderDoc library not found in process memory (not running under RenderDoc)")
		return false
	}

	get_api_sym, sym_ok := dynlib.symbol_address(lib_handle, "RENDERDOC_GetAPI")
	if !sym_ok || get_api_sym == nil {
		log.log_warning("RenderDoc", "Failed to find RENDERDOC_GetAPI symbol in librenderdoc")
		return false
	}

	get_api_fn := cast(pRENDERDOC_GetAPI)get_api_sym
	api_ptr: rawptr
	ret := get_api_fn(.eRENDERDOC_API_Version_1_4_0, &api_ptr)
	if ret != 1 || api_ptr == nil {
		log.log_warning("RenderDoc", "RENDERDOC_GetAPI(1.4.0) returned error code: %d", ret)
		return false
	}

	g_rdoc.api = cast(^API_1_4_0)api_ptr
	g_rdoc.available = true

	major, minor, patch: c.int
	g_rdoc.api.GetAPIVersion(&major, &minor, &patch)
	log.log_info("RenderDoc", "RenderDoc In-App API initialized (v%d.%d.%d active)", major, minor, patch)
	return true
}

// Check if RenderDoc in-app API is currently active.
is_active :: proc() -> bool {
	return g_rdoc.available && g_rdoc.api != nil
}

// Start a multi-frame or single-frame capture sequence.
start_capture :: proc(device: rawptr = nil, window: rawptr = nil) {
	if is_active() {
		g_rdoc.api.StartFrameCapture(device, window)
		log.log_info("RenderDoc", "Frame capture STARTED")
	}
}

// End the active frame capture sequence and save the .rdc capture file.
end_capture :: proc(device: rawptr = nil, window: rawptr = nil) -> bool {
	if is_active() {
		ret := g_rdoc.api.EndFrameCapture(device, window)
		if ret == 1 {
			log.log_info("RenderDoc", "Frame capture COMPLETED and written to disk successfully")
			return true
		}
		log.log_warning("RenderDoc", "Frame capture ended with error code: %d", ret)
		return false
	}
	return false
}

// Check if a capture is currently in progress.
is_capturing :: proc() -> bool {
	if is_active() {
		return g_rdoc.api.IsFrameCapturing() == 1
	}
	return false
}

// Trigger an immediate single frame capture at next swap.
trigger_capture :: proc() {
	if is_active() {
		g_rdoc.api.TriggerCapture()
		log.log_info("RenderDoc", "Capture triggered for next frame")
	}
}

// Set custom output capture path template (e.g. "build/profiling/renderdoc/ibl_capture").
set_capture_path_template :: proc(template_path: string) {
	if is_active() {
		c_path := strings.clone_to_cstring(template_path, context.temp_allocator)
		g_rdoc.api.SetCaptureFilePathTemplate(c_path)
	}
}
