package app

import "vendor:glfw"
import gl "vendor:OpenGL"
import "core:fmt"
import "core:os"

import scene "../scene"
import postfx "../rendering/postfx"

// Run a fixed-frame benchmark: enable all effects, render N frames, print stats.
// Uses glFinish() per frame for accurate GPU timing (not just CPU submission).
run_benchmark :: proc(application: ^App, total_frames, warmup_frames: i32) {
	if application == nil { return }

	// Enable all non-debug effects for maximum GPU load
	all_effects :: postfx.Effect_Flags{
		.Vignette, .Grain, .Exposure, .Chrom_Abbr, .Bloom,
		.Color_Grading, .Dof, .Auto_Exposure, .FXAA, .Tonemap, .Banding,
	}
	application.scene.postfx_pipeline.active_effects = all_effects
	application.scene.postfx_pipeline.enabled = true
	application.scene.postfx_pipeline.ubo_dirty = true

	// Compile optimized shader variant for this effect combination
	postfx.pipeline_compile_variant(&application.scene.postfx_pipeline)

	// Disable GUI for clean measurement
	application.imgui.visible = false

	effective_warmup := min(warmup_frames, max(0, total_frames / 4))
	measured_frames := max(1, total_frames - effective_warmup)

	fmt.println("=== BENCHMARK START ===")
	fmt.printfln("  GPU: %s", gl.GetString(gl.RENDERER))
	fmt.printfln("  Frames: %d (warmup: %d, measured: %d)", total_frames, effective_warmup, measured_frames)
	fmt.printfln("  Effects: Vignette+Grain+Exposure+ChromAbbr+Bloom+ColorGrading+DoF+AutoExposure+FXAA+Tonemap+Banding")

	w, h := glfw.GetFramebufferSize(application.window)
	fmt.printfln("  Resolution: %dx%d", w, h)

	measure_start := glfw.GetTime()
	frame: i32

	for frame < total_frames && application.running && !glfw.WindowShouldClose(application.window) {
		current_time := glfw.GetTime()
		application.delta_time = f32(current_time - application.last_frame_time)
		application.last_frame_time = current_time

		glfw.PollEvents()
		scene.scene_update(&application.scene, application.delta_time)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

		bw, bh := glfw.GetFramebufferSize(application.window)
		scene.scene_render(&application.scene, bw, bh)

		// Force GPU completion per frame to measure real render cost
		gl.Finish()

		// Dump frame after warmup for visual validation (BEFORE swap)
		if frame == effective_warmup {
			dump_benchmark_frame(application, bw, bh)
		}

		glfw.SwapBuffers(application.window)

		frame += 1

		if frame == effective_warmup {
			// Force a pipeline flush before measurement begins
			gl.Finish()
			measure_start = glfw.GetTime()
		}
	}

	// Ensure all GPU work is complete
	gl.Finish()
	measure_end := glfw.GetTime()

	elapsed := max(0.0001, measure_end - measure_start)
	avg_ms := (elapsed / f64(measured_frames)) * 1000.0
	avg_fps := f64(measured_frames) / elapsed

	fmt.println("=== BENCHMARK RESULTS ===")
	fmt.printfln("  Measured frames: %d", measured_frames)
	fmt.printfln("  Total time:      %.3f s", elapsed)
	fmt.printfln("  Avg frame time:  %.3f ms", avg_ms)
	fmt.printfln("  Avg FPS:         %.1f", avg_fps)
	fmt.printfln("  Min theoretical: %.3f ms (based on %.1f FPS)", 1000.0 / avg_fps, avg_fps)
	fmt.println("========================")
}

// --- Private helpers ---

BENCHMARK_SCREENSHOT_PATH :: "/tmp/benchmark_frame.ppm"

@(private)
dump_benchmark_frame :: proc(application: ^App, width, height: i32) {
	// Read from scene FBO (COLOR_ATTACHMENT0 is the HDR render target)
	gl.BindFramebuffer(gl.READ_FRAMEBUFFER, application.scene.postfx_pipeline.scene_fbo)
	gl.ReadBuffer(gl.COLOR_ATTACHMENT0)
	defer gl.BindFramebuffer(gl.READ_FRAMEBUFFER, 0)

	pixels := make([]u8, int(width * height * 3))
	defer delete(pixels)

	gl.ReadPixels(0, 0, width, height, gl.RGB, gl.UNSIGNED_BYTE, raw_data(pixels))

	fd, err := os.open(BENCHMARK_SCREENSHOT_PATH, os.O_WRONLY | os.O_CREATE | os.O_TRUNC)
	if err != nil {
		fmt.printfln("  [WARN] Failed to write screenshot: %v", err)
		return
	}
	defer os.close(fd)

	// PPM P6 header
	header := fmt.tprintf("P6\n%d %d\n255\n", width, height)
	os.write(fd, transmute([]u8)header)

	// Flip vertically (OpenGL origin is bottom-left)
	row_size := int(width) * 3
	for y in 0 ..< int(height) {
		src_row := (int(height) - 1 - y) * row_size
		os.write(fd, pixels[src_row:][:row_size])
	}

	fmt.printfln("  Screenshot: %s", BENCHMARK_SCREENSHOT_PATH)
}
