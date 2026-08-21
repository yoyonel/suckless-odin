package app

import "vendor:glfw"
import "core:math"
import mt "../core/math_types"
import log "../core/log"
import cam "../camera"
import scene "../scene"
import gui "../gui"

// Gamepad configuration defaults (ISO port from suckless-ogl gamepad_input.c)
GAMEPAD_DEFAULT_DEADZONE         :: 0.15
GAMEPAD_DEFAULT_LOOK_SENSITIVITY :: 140.0
GAMEPAD_DEFAULT_MOVE_SENSITIVITY :: 1.0
GAMEPAD_DEFAULT_TRIGGER_THRESH   :: 0.05
GAMEPAD_BUTTON_COUNT             :: 15
GAMEPAD_AXIS_COUNT               :: 6

// Normalisation factor for GLFW triggers from [-1, 1] to [0, 1]
TRIGGER_NORM_FACTOR :: 0.5

Gamepad_State :: struct {
	connected:         bool,
	joystick_id:       i32,
	deadzone:          f32,
	look_sensitivity:  f32,
	move_sensitivity:  f32,
	trigger_threshold: f32,
	prev_buttons:      [GAMEPAD_BUTTON_COUNT]u8,
	axes:              [GAMEPAD_AXIS_COUNT]f32,
}

// Initializes gamepad state with standard defaults
gamepad_init :: proc(state: ^Gamepad_State) {
	state.connected = false
	state.joystick_id = glfw.JOYSTICK_1
	state.deadzone = GAMEPAD_DEFAULT_DEADZONE
	state.look_sensitivity = GAMEPAD_DEFAULT_LOOK_SENSITIVITY
	state.move_sensitivity = GAMEPAD_DEFAULT_MOVE_SENSITIVITY
	state.trigger_threshold = GAMEPAD_DEFAULT_TRIGGER_THRESH
	for i in 0 ..< GAMEPAD_BUTTON_COUNT {
		state.prev_buttons[i] = 0
	}
	for i in 0 ..< GAMEPAD_AXIS_COUNT {
		state.axes[i] = 0.0
	}
}

// Rescales stick axis value outside deadzone so usable range smoothly starts from 0.0
gamepad_apply_deadzone :: proc(value, deadzone: f32) -> f32 {
	abs_val := math.abs(value)
	if abs_val < deadzone {
		return 0.0
	}
	sign: f32 = 1.0 if value > 0.0 else -1.0
	return sign * (abs_val - deadzone) / (1.0 - deadzone)
}

// Polls gamepad state, detects connection events, handles edge-triggered buttons,
// and applies continuous analog movement/rotation to the camera.
gamepad_poll :: proc(application: ^App, state: ^Gamepad_State, dt: f32) {
	if application == nil || state == nil { return }

	was_connected := state.connected
	state.connected = bool(glfw.JoystickIsGamepad(state.joystick_id))

	if state.connected && !was_connected {
		name := glfw.GetGamepadName(state.joystick_id)
		log.log_info("suckless-odin.gamepad", "Gamepad connected: %s (ID=%d)", name, state.joystick_id)
	} else if !state.connected && was_connected {
		log.log_info("suckless-odin.gamepad", "Gamepad disconnected (ID=%d)", state.joystick_id)
		for i in 0 ..< GAMEPAD_AXIS_COUNT {
			state.axes[i] = 0.0
		}
		return
	}

	if !state.connected {
		return
	}

	pad: glfw.GamepadState
	if !bool(glfw.GetGamepadState(state.joystick_id, &pad)) {
		state.connected = false
		for i in 0 ..< GAMEPAD_AXIS_COUNT {
			state.axes[i] = 0.0
		}
		return
	}

	// 1. Process Deadzone-filtered Analog Sticks
	state.axes[glfw.GAMEPAD_AXIS_LEFT_X] = gamepad_apply_deadzone(
		pad.axes[glfw.GAMEPAD_AXIS_LEFT_X], state.deadzone,
	)
	state.axes[glfw.GAMEPAD_AXIS_LEFT_Y] = gamepad_apply_deadzone(
		pad.axes[glfw.GAMEPAD_AXIS_LEFT_Y], state.deadzone,
	)
	state.axes[glfw.GAMEPAD_AXIS_RIGHT_X] = gamepad_apply_deadzone(
		pad.axes[glfw.GAMEPAD_AXIS_RIGHT_X], state.deadzone,
	)
	state.axes[glfw.GAMEPAD_AXIS_RIGHT_Y] = gamepad_apply_deadzone(
		pad.axes[glfw.GAMEPAD_AXIS_RIGHT_Y], state.deadzone,
	)

	// 2. Normalise Triggers from [-1, 1] to [0, 1]
	trig_left := (pad.axes[glfw.GAMEPAD_AXIS_LEFT_TRIGGER] + 1.0) * TRIGGER_NORM_FACTOR
	trig_right := (pad.axes[glfw.GAMEPAD_AXIS_RIGHT_TRIGGER] + 1.0) * TRIGGER_NORM_FACTOR
	state.axes[glfw.GAMEPAD_AXIS_LEFT_TRIGGER] = trig_left if trig_left > state.trigger_threshold else 0.0
	state.axes[glfw.GAMEPAD_AXIS_RIGHT_TRIGGER] = trig_right if trig_right > state.trigger_threshold else 0.0

	// 3. Edge-triggered Buttons
	btn_r1_now := pad.buttons[glfw.GAMEPAD_BUTTON_RIGHT_BUMPER]
	btn_r1_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_RIGHT_BUMPER]
	if btn_r1_now != 0 && btn_r1_prev == 0 {
		scene.scene_cycle_env(&application.scene, 1)
	}

	btn_l1_now := pad.buttons[glfw.GAMEPAD_BUTTON_LEFT_BUMPER]
	btn_l1_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_LEFT_BUMPER]
	if btn_l1_now != 0 && btn_l1_prev == 0 {
		scene.scene_cycle_env(&application.scene, -1)
	}

	btn_back_now := pad.buttons[glfw.GAMEPAD_BUTTON_BACK]
	btn_back_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_BACK]
	if btn_back_now != 0 && btn_back_prev == 0 {
		camera_reset(application)
	}

	btn_start_now := pad.buttons[glfw.GAMEPAD_BUTTON_START]
	btn_start_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_START]
	if btn_start_now != 0 && btn_start_prev == 0 {
		gui.toggle(&application.imgui)
		if application.imgui.visible {
			application.camera_enabled = false
			glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_NORMAL)
		} else {
			application.camera_enabled = true
			glfw.SetInputMode(application.window, glfw.CURSOR, glfw.CURSOR_DISABLED)
			application.scene.camera.first_mouse = true
		}
	}

	btn_y_now := pad.buttons[glfw.GAMEPAD_BUTTON_Y]
	btn_y_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_Y]
	if btn_y_now != 0 && btn_y_prev == 0 {
		scene.scene_toggle_overlay(&application.scene)
	}

	btn_x_now := pad.buttons[glfw.GAMEPAD_BUTTON_X]
	btn_x_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_X]
	if btn_x_now != 0 && btn_x_prev == 0 {
		toggle_camera(application)
	}

	btn_a_now := pad.buttons[glfw.GAMEPAD_BUTTON_A]
	btn_a_prev := state.prev_buttons[glfw.GAMEPAD_BUTTON_A]
	if btn_a_now != 0 && btn_a_prev == 0 {
		toggle_fullscreen(application)
	}

	// Save button states for edge detection next frame
	for i in 0 ..< GAMEPAD_BUTTON_COUNT {
		state.prev_buttons[i] = pad.buttons[i]
	}

	// 4. Apply Analog & D-pad Movement to Camera
	c := &application.scene.camera

	stick_lx := state.axes[glfw.GAMEPAD_AXIS_LEFT_X]
	stick_ly := state.axes[glfw.GAMEPAD_AXIS_LEFT_Y]
	trig_r := state.axes[glfw.GAMEPAD_AXIS_RIGHT_TRIGGER]
	trig_l := state.axes[glfw.GAMEPAD_AXIS_LEFT_TRIGGER]

	dpad_up    := pad.buttons[glfw.GAMEPAD_BUTTON_DPAD_UP] != 0
	dpad_down  := pad.buttons[glfw.GAMEPAD_BUTTON_DPAD_DOWN] != 0
	dpad_left  := pad.buttons[glfw.GAMEPAD_BUTTON_DPAD_LEFT] != 0
	dpad_right := pad.buttons[glfw.GAMEPAD_BUTTON_DPAD_RIGHT] != 0

	has_dpad := dpad_up || dpad_down || dpad_left || dpad_right
	has_stick := math.abs(stick_lx) > 0.0 || math.abs(stick_ly) > 0.0
	has_trig  := trig_r > 0.0 || trig_l > 0.0

	if has_stick || has_dpad || has_trig {
		move_x := stick_lx * state.move_sensitivity
		move_z := -stick_ly * state.move_sensitivity  // -Y on stick is forward

		if has_dpad {
			if dpad_right { move_x = 1.0 }
			if dpad_left  { move_x = -1.0 }
			if dpad_up    { move_z = 1.0 }
			if dpad_down  { move_z = -1.0 }
		}

		move_y := (trig_r - trig_l) * state.move_sensitivity

		c.move_input = mt.Vec3{move_x, move_y, move_z}
	} else {
		// Keyboard fallback if stick is idle
		kb_x := f32(i32(c.move_right_)  - i32(c.move_left))
		kb_y := f32(i32(c.move_up_)      - i32(c.move_down))
		kb_z := f32(i32(c.move_forward)  - i32(c.move_backward))
		c.move_input = mt.Vec3{kb_x, kb_y, kb_z}
	}

	// 5. Apply Analog Rotation / Look to Camera (Yaw / Pitch)
	stick_rx := state.axes[glfw.GAMEPAD_AXIS_RIGHT_X]
	stick_ry := state.axes[glfw.GAMEPAD_AXIS_RIGHT_Y]

	if math.abs(stick_rx) > 0.0 || math.abs(stick_ry) > 0.0 {
		look_speed := state.look_sensitivity * dt
		c.yaw_target   += stick_rx * look_speed
		c.pitch_target -= stick_ry * look_speed

		if c.pitch_target > cam.DEFAULT_MAX_PITCH {
			c.pitch_target = cam.DEFAULT_MAX_PITCH
		}
		if c.pitch_target < cam.DEFAULT_MIN_PITCH {
			c.pitch_target = cam.DEFAULT_MIN_PITCH
		}
	}
}
