package tests

import "core:testing"
import perf_mode "../src/core/perf_mode"

@(test)
test_perf_mode_lifecycle :: proc(t: ^testing.T) {
	pm: perf_mode.Perf_Mode
	perf_mode.init(&pm)

	testing.expect_value(t, pm.active, false)
	testing.expect_value(t, perf_mode.backend_label(&pm), "OFF")

	// Test activation
	ok := perf_mode.activate(&pm, quiet = true)
	if ok {
		testing.expect_value(t, pm.active, true)
		label := perf_mode.backend_label(&pm)
		testing.expect(t, label != "OFF", "Expected active backend label")

		// Test deactivation
		perf_mode.deactivate(&pm)
		testing.expect_value(t, pm.active, false)
		testing.expect_value(t, perf_mode.backend_label(&pm), "OFF")
	}

	// Test toggle
	new_state := perf_mode.toggle(&pm)
	if new_state {
		testing.expect_value(t, pm.active, true)
		perf_mode.toggle(&pm)
		testing.expect_value(t, pm.active, false)
	}

	perf_mode.cleanup(&pm)
}
