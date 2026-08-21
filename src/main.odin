package main

import "core:os"

import log "core/log"
import "app"
import "core/settings"

main :: proc() {
	// Handle CLI arguments
	opts, action := cli_handle_args(os.args)
	switch action {
	case .Exit_Success:
		os.exit(0)
	case .Exit_Failure:
		os.exit(1)
	case .Continue:
		// proceed
	}

	application := app.create(settings.WINDOW_WIDTH, settings.WINDOW_HEIGHT, "suckless-odin — Icosphere Phong")
	if application == nil {
		log.log_error("suckless-odin.main", "Failed to create application")
		os.exit(1)
	}
	defer app.destroy(application)

	if !app.init(application, vsync = opts.vsync, compute_profile = opts.compute_profile, capture_ibl = opts.capture_ibl) {
		log.log_error("suckless-odin.main", "Failed to initialize application")
		os.exit(1)
	}

	// Apply CLI postfx options after init (pipeline is ready)
	app.apply_postfx_options(application, opts.postfx_enabled, opts.postfx_preset)

	if opts.benchmark {
		app.run_benchmark(application, opts.benchmark_frames, BENCHMARK_WARMUP_FRAMES)
	} else {
		app.run(application)
	}
}
