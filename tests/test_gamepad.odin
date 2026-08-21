package tests

import "core:testing"
import "core:math"
import app "../src/app"

@(test)
test_gamepad_deadzone_filtering :: proc(t: ^testing.T) {
	deadzone: f32 = 0.15

	// 1. Inside deadzone -> strictly 0.0
	testing.expect_value(t, app.gamepad_apply_deadzone(0.0, deadzone), 0.0)
	testing.expect_value(t, app.gamepad_apply_deadzone(0.10, deadzone), 0.0)
	testing.expect_value(t, app.gamepad_apply_deadzone(-0.14, deadzone), 0.0)

	// 2. Exactly at deadzone boundary -> 0.0
	testing.expect_value(t, app.gamepad_apply_deadzone(0.15, deadzone), 0.0)
	testing.expect_value(t, app.gamepad_apply_deadzone(-0.15, deadzone), 0.0)

	// 3. At maximum positive -> strictly 1.0
	val_max := app.gamepad_apply_deadzone(1.0, deadzone)
	testing.expect(t, math.abs(val_max - 1.0) < 0.0001, "Expected 1.0 at full deflection")

	// 4. At maximum negative -> strictly -1.0
	val_min := app.gamepad_apply_deadzone(-1.0, deadzone)
	testing.expect(t, math.abs(val_min - (-1.0)) < 0.0001, "Expected -1.0 at full deflection")

	// 5. Halfway point outside deadzone (e.g. 0.575 is halfway between 0.15 and 1.0)
	half_val := app.gamepad_apply_deadzone(0.15 + (1.0 - 0.15) * 0.5, deadzone)
	testing.expect(t, math.abs(half_val - 0.5) < 0.0001, "Expected 0.5 at midpoint outside deadzone")
}

@(test)
test_gamepad_initialization_defaults :: proc(t: ^testing.T) {
	state: app.Gamepad_State
	app.gamepad_init(&state)

	testing.expect(t, !state.connected, "Gamepad should start disconnected")
	testing.expect_value(t, state.deadzone, app.GAMEPAD_DEFAULT_DEADZONE)
	testing.expect_value(t, state.look_sensitivity, app.GAMEPAD_DEFAULT_LOOK_SENSITIVITY)
	testing.expect_value(t, state.move_sensitivity, app.GAMEPAD_DEFAULT_MOVE_SENSITIVITY)
	testing.expect_value(t, state.trigger_threshold, app.GAMEPAD_DEFAULT_TRIGGER_THRESH)

	for i in 0 ..< app.GAMEPAD_BUTTON_COUNT {
		testing.expect_value(t, state.prev_buttons[i], 0)
	}
	for i in 0 ..< app.GAMEPAD_AXIS_COUNT {
		testing.expect_value(t, state.axes[i], 0.0)
	}
}
