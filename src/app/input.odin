package app

import "vendor:glfw"
import gl "vendor:OpenGL"
import "base:runtime"
import settings "../core/settings"
import log "../core/log"
import cam "../camera"
import scene "../scene"
import gui "../gui"
import renderdoc "../core/renderdoc"

// GLFW key callback — handles press-only actions.
// Movement keys (WASD/Q/E) are handled via polling in process_keyboard().
@(private)
key_callback :: proc "c" (window: glfw.WindowHandle, key, scancode, action, mods: i32) {
	if action != glfw.PRESS { return }

	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }

	// Ctrl+F focuses search when GUI is visible (must be before the ImGui guard)
	if key == glfw.KEY_F && mods == glfw.MOD_CONTROL && app.imgui.visible {
		app.imgui.focus_search = true
		return
	}

	// When ImGui has keyboard focus, only block printable character keys
	// (so F2, Escape, F-keys etc. still work for toggling the GUI)
	if gui.wants_keyboard(&app.imgui) && key >= glfw.KEY_SPACE && key <= glfw.KEY_GRAVE_ACCENT {
		return
	}

	log.log_info("suckless-odin.input", "Key pressed: %d (action=%d)", key, action)

	switch key {
	case glfw.KEY_ESCAPE:
		glfw.SetWindowShouldClose(window, true)
	case glfw.KEY_F:
		toggle_fullscreen(app)
	case glfw.KEY_F1:
		scene.scene_toggle_overlay(&app.scene)
	case glfw.KEY_F2:
		gui.toggle(&app.imgui)
		// GUI open → release cursor for UI interaction; GUI closed → capture cursor for camera
		if app.imgui.visible {
			app.camera_enabled = false
			glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
		} else {
			app.camera_enabled = true
			glfw.SetInputMode(app.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
			app.scene.camera.first_mouse = true
		}
	case glfw.KEY_C:
		toggle_camera(app)
	case glfw.KEY_SPACE:
		camera_reset(app)
	case glfw.KEY_PAGE_UP:
		scene.scene_cycle_env(&app.scene, 1)
	case glfw.KEY_PAGE_DOWN:
		scene.scene_cycle_env(&app.scene, -1)
	case glfw.KEY_F12:
		renderdoc.trigger_capture()
	}
}

// Toggle between windowed and fullscreen mode.
// ISO port of app_toggle_fullscreen() from suckless-ogl/src/app_input.c.
@(private)
toggle_fullscreen :: proc(application: ^App) {
	gl.Finish()

	if !application.is_fullscreen {
		monitor := glfw.GetPrimaryMonitor()
		mode := glfw.GetVideoMode(monitor)
		application.saved_x, application.saved_y = glfw.GetWindowPos(application.window)
		application.saved_width, application.saved_height = glfw.GetWindowSize(application.window)
		glfw.SetWindowMonitor(application.window, monitor, 0, 0,
			mode.width, mode.height, mode.refresh_rate)
		log.log_info("suckless-odin.input", "Switched to fullscreen (%dx%d@%dHz)", mode.width, mode.height, mode.refresh_rate)
	} else {
		glfw.SetWindowMonitor(application.window, nil, application.saved_x, application.saved_y,
			application.saved_width, application.saved_height, 0)
		log.log_info("suckless-odin.input", "Switched to windowed (%dx%d at %d,%d)", application.saved_width, application.saved_height, application.saved_x, application.saved_y)
	}

	application.is_fullscreen = !application.is_fullscreen
	glfw.FocusWindow(application.window)
}

// Process held keys for continuous camera movement.
// ISO: W/S/A/D = move, Q = up, E = down (matches legacy camera_input.c)
@(private)
process_keyboard :: proc(application: ^App) {
	w := application.window
	s := &application.scene
	s.camera.move_forward  = glfw.GetKey(w, glfw.KEY_W) == glfw.PRESS
	s.camera.move_backward = glfw.GetKey(w, glfw.KEY_S) == glfw.PRESS
	s.camera.move_left     = glfw.GetKey(w, glfw.KEY_A) == glfw.PRESS
	s.camera.move_right_   = glfw.GetKey(w, glfw.KEY_D) == glfw.PRESS
	s.camera.move_up_      = glfw.GetKey(w, glfw.KEY_Q) == glfw.PRESS
	s.camera.move_down     = glfw.GetKey(w, glfw.KEY_E) == glfw.PRESS
}

// Toggle mouse-driven camera orientation (C key).
// ISO port of handle_camera_toggle() from suckless-ogl/src/app_input.c.
@(private)
toggle_camera :: proc(application: ^App) {
	application.camera_enabled = !application.camera_enabled
	if application.camera_enabled {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
		application.scene.camera.first_mouse = true
		// Camera mode → hide GUI to prevent invisible interactions
		application.imgui.visible = false
	} else {
		glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
	}
}

// Reset camera to default position and orientation (Space key).
// ISO port of GLFW_KEY_SPACE handler from suckless-ogl/src/app_input.c.
@(private)
camera_reset :: proc(application: ^App) {
	cam.init(&application.scene.camera,
		settings.DEFAULT_CAMERA_DISTANCE,
		settings.DEFAULT_CAMERA_YAW,
		settings.DEFAULT_CAMERA_PITCH)
}

// GLFW mouse callback — camera look (only when camera_enabled).
// ISO port of camera_process_mouse with smoothing.
@(private)
mouse_callback :: proc "c" (window: glfw.WindowHandle, xpos, ypos: f64) {
	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }
	if !app.camera_enabled { return }
	if gui.wants_mouse(&app.imgui) { return }

	c := &app.scene.camera
	if c.first_mouse {
		c.last_mouse_x = xpos
		c.last_mouse_y = ypos
		c.first_mouse = false
		return
	}

	xoffset := f32(xpos - c.last_mouse_x)
	yoffset := f32(c.last_mouse_y - ypos)  // reversed: y goes bottom-to-top
	c.last_mouse_x = xpos
	c.last_mouse_y = ypos

	cam.process_mouse(c, xoffset, yoffset)
}

// GLFW scroll callback — forward velocity impulse along camera front.
// ISO port of camera_process_scroll from suckless-ogl/src/camera.c.
@(private)
scroll_callback :: proc "c" (window: glfw.WindowHandle, xoffset, yoffset: f64) {
	context = runtime.default_context()

	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app == nil { return }
	if !app.camera_enabled { return }
	if gui.wants_mouse(&app.imgui) { return }

	cam.process_scroll(&app.scene.camera, f32(yoffset))
}

// GLFW framebuffer resize callback — lightweight and passive (Deferred Resize pattern).
// Does not reallocate GPU resources inside the synchronous GLFW/driver callback context.
@(private)
framebuffer_size_callback :: proc "c" (window: glfw.WindowHandle, width, height: i32) {
	context = runtime.default_context()
	gl.Viewport(0, 0, width, height)
	app := cast(^App)glfw.GetWindowUserPointer(window)
	if app != nil {
		app.width = width
		app.height = height
		app.pending_width = width
		app.pending_height = height
		app.resize_pending = true
	}
}
