// +build test
// Phase 3: Visual regression tests — full PBR scene rendering from multiple viewpoints.
// MUST be run single-threaded: odin test tests/gl/ -define:ODIN_TEST_THREADS=1
// Requires a display (or xvfb-run on CI).
//
// ISO port of suckless-ogl/tests/test_app.c visual regression harness.
// Renders the real scene (PBR spheres + IBL + skybox) from 6 cardinal camera angles.
//
// Modes:
//   GEN_REFS=1 → generate/overwrite reference images (always passes)
//   (default)  → compare rendered output against saved references
//   If reference doesn't exist and GEN_REFS not set → test fails
package test_gl

import "core:testing"
import "core:fmt"
import "core:os"
import "core:math"
import "core:c"
import "core:strings"
import "core:time"

import gl "vendor:OpenGL"
import stbi "vendor:stb/image"

import sc "../../src/scene"
import cam "../../src/camera"
import mt "../../src/core/math_types"

// --- Constants (matching legacy test_app.c) ---

// Test resolution (smaller than fullscreen for speed, sufficient for meaningful regression)
TEST_WIDTH  :: 512
TEST_HEIGHT :: 384

CHANNELS :: 4  // RGBA

// Legacy comparison parameters (ISO port of test_app.c thresholds)
PIXEL_TOLERANCE           :: f32(5.0)   // Per-pixel Euclidean RGB distance threshold
DIFF_PERCENTAGE_TOLERANCE :: f32(0.02)  // Max 2% of pixels can differ

CAMERA_DIST :: f32(25.0)  // Camera distance from origin (matches legacy)

REF_DIR :: "tests/references/"

// --- Viewpoints (ISO port of G_VIEWPOINTS from test_app.c) ---

Viewpoint :: struct {
	name:     string,
	position: mt.Vec3,
	yaw:      f32,
	pitch:    f32,
	world_up: mt.Vec3,
}

VIEWPOINTS :: [6]Viewpoint{
	{"front",  {0, 0,  CAMERA_DIST}, -90.0,   0.0, {0, 1,  0}},
	{"back",   {0, 0, -CAMERA_DIST},  90.0,   0.0, {0, 1,  0}},
	{"left",   {-CAMERA_DIST, 0, 0},   0.0,   0.0, {0, 1,  0}},
	{"right",  { CAMERA_DIST, 0, 0}, 180.0,   0.0, {0, 1,  0}},
	{"top",    {0,  CAMERA_DIST, 0}, -90.0, -89.0, {0, 0, -1}},
	{"bottom", {0, -CAMERA_DIST, 0}, -90.0,  89.0, {0, 0,  1}},
}

// --- FBO render target ---

@(private)
Render_Target :: struct {
	fbo:     u32,
	texture: u32,
	rbo:     u32,
	width:   i32,
	height:  i32,
}

@(private)
render_target_create :: proc(width, height: i32) -> (rt: Render_Target, ok: bool) {
	rt.width = width
	rt.height = height

	gl.GenFramebuffers(1, &rt.fbo)
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)

	// Color attachment (RGBA8)
	gl.GenTextures(1, &rt.texture)
	gl.BindTexture(gl.TEXTURE_2D, rt.texture)
	gl.TexImage2D(gl.TEXTURE_2D, 0, gl.RGBA8, width, height, 0, gl.RGBA, gl.UNSIGNED_BYTE, nil)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	gl.FramebufferTexture2D(gl.FRAMEBUFFER, gl.COLOR_ATTACHMENT0, gl.TEXTURE_2D, rt.texture, 0)

	// Depth attachment (renderbuffer)
	gl.GenRenderbuffers(1, &rt.rbo)
	gl.BindRenderbuffer(gl.RENDERBUFFER, rt.rbo)
	gl.RenderbufferStorage(gl.RENDERBUFFER, gl.DEPTH_COMPONENT24, width, height)
	gl.FramebufferRenderbuffer(gl.FRAMEBUFFER, gl.DEPTH_ATTACHMENT, gl.RENDERBUFFER, rt.rbo)

	status := gl.CheckFramebufferStatus(gl.FRAMEBUFFER)
	if status != gl.FRAMEBUFFER_COMPLETE {
		render_target_destroy(&rt)
		return rt, false
	}

	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	return rt, true
}

@(private)
render_target_destroy :: proc(rt: ^Render_Target) {
	if rt.texture != 0 { gl.DeleteTextures(1, &rt.texture); rt.texture = 0 }
	if rt.rbo != 0 { gl.DeleteRenderbuffers(1, &rt.rbo); rt.rbo = 0 }
	if rt.fbo != 0 { gl.DeleteFramebuffers(1, &rt.fbo); rt.fbo = 0 }
}

// --- Pixel capture ---

@(private)
capture_framebuffer :: proc(rt: ^Render_Target) -> []u8 {
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	pixels := make([]u8, int(rt.width * rt.height * CHANNELS))
	gl.ReadPixels(0, 0, rt.width, rt.height, gl.RGBA, gl.UNSIGNED_BYTE, raw_data(pixels))
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)

	// Flip vertically (GL bottom-to-top → PNG top-to-bottom)
	row_size := int(rt.width * CHANNELS)
	row_buf := make([]u8, row_size)
	defer delete(row_buf)
	for y in 0..<int(rt.height)/2 {
		top := y * row_size
		bot := (int(rt.height) - 1 - y) * row_size
		copy(row_buf, pixels[top:top+row_size])
		copy(pixels[top:top+row_size], pixels[bot:bot+row_size])
		copy(pixels[bot:bot+row_size], row_buf)
	}

	// Force alpha=255: skybox writes luma in alpha (for FXAA), not opacity.
	// Without post-processing, alpha is irrelevant — force opaque for valid PNGs.
	pixel_count := int(rt.width * rt.height)
	for p in 0..<pixel_count {
		pixels[p * CHANNELS + 3] = 255
	}

	return pixels
}

// --- Image comparison (ISO port of verify_reference_image from test_app.c) ---

// Per-pixel Euclidean RGB distance comparison with percentage threshold.
@(private)
compare_images :: proc(current, reference: []u8, width, height: i32) -> (diff_pct: f32, pass: bool) {
	pixel_count := int(width * height)
	diff_count := 0

	for p in 0..<pixel_count {
		i := p * CHANNELS
		dr := f32(current[i+0]) - f32(reference[i+0])
		dg := f32(current[i+1]) - f32(reference[i+1])
		db := f32(current[i+2]) - f32(reference[i+2])
		dist := math.sqrt(dr*dr + dg*dg + db*db)
		if dist > PIXEL_TOLERANCE {
			diff_count += 1
		}
	}

	diff_pct = f32(diff_count) / f32(pixel_count)
	return diff_pct, diff_pct <= DIFF_PERCENTAGE_TOLERANCE
}

// --- PNG I/O ---

@(private)
save_png :: proc(path: string, pixels: []u8, width, height: i32) -> bool {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)
	stride := width * CHANNELS
	result := stbi.write_png(c_path, c.int(width), c.int(height), CHANNELS, raw_data(pixels), c.int(stride))
	return result != 0
}

@(private)
load_png :: proc(path: string) -> (pixels: []u8, width, height: i32, ok: bool) {
	c_path := strings.clone_to_cstring(path)
	defer delete(c_path)

	// Reset flip flag — scene's HDR loading sets it globally via stbi.set_flip_vertically_on_load(1)
	stbi.set_flip_vertically_on_load(0)

	w, h, channels: c.int
	data := stbi.load(c_path, &w, &h, &channels, CHANNELS)
	if data == nil {
		return nil, 0, 0, false
	}

	width = i32(w)
	height = i32(h)
	pixel_count := int(width * height * CHANNELS)

	// Copy to Odin-managed memory so we can free stb's allocation
	pixels = make([]u8, pixel_count)
	for i in 0..<pixel_count {
		pixels[i] = data[i]
	}
	stbi.image_free(data)

	return pixels, width, height, true
}

// --- Diff artifact generation (for failure debugging) ---

@(private)
save_diff_artifacts :: proc(name: string, current, reference: []u8, width, height: i32) {
	// Save actual rendered frame
	actual_path := strings.concatenate({REF_DIR, "failed_actual_", name, ".png"})
	defer delete(actual_path)
	save_png(actual_path, current, width, height)

	// Save binary diff map (red where pixels differ, black elsewhere)
	pixel_count := int(width * height)
	diff_map := make([]u8, pixel_count * CHANNELS)
	defer delete(diff_map)

	for p in 0..<pixel_count {
		i := p * CHANNELS
		dr := f32(current[i+0]) - f32(reference[i+0])
		dg := f32(current[i+1]) - f32(reference[i+1])
		db := f32(current[i+2]) - f32(reference[i+2])
		dist := math.sqrt(dr*dr + dg*dg + db*db)

		if dist > PIXEL_TOLERANCE {
			diff_map[i+0] = 255
			diff_map[i+1] = 0
			diff_map[i+2] = 0
			diff_map[i+3] = 255
		} else {
			diff_map[i+0] = 0
			diff_map[i+1] = 0
			diff_map[i+2] = 0
			diff_map[i+3] = 255
		}
	}

	diff_path := strings.concatenate({REF_DIR, "failed_diff_", name, ".png"})
	defer delete(diff_path)
	save_png(diff_path, diff_map, width, height)
}

// --- Scene rendering from a viewpoint ---

@(private)
render_viewpoint :: proc(s: ^sc.Scene, rt: ^Render_Target, vp: Viewpoint) {
	// Set camera to deterministic viewpoint (bypass physics/smoothing)
	s.camera.position = vp.position
	s.camera.yaw = vp.yaw
	s.camera.pitch = vp.pitch
	s.camera.world_up = vp.world_up
	// Also set targets to avoid smoothing drift
	s.camera.yaw_target = vp.yaw
	s.camera.pitch_target = vp.pitch
	cam.update_vectors(&s.camera)

	// Render to FBO
	gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
	gl.Viewport(0, 0, rt.width, rt.height)
	gl.Enable(gl.DEPTH_TEST)
	gl.DepthFunc(gl.LESS)
	gl.ClearColor(0.0, 0.0, 0.0, 1.0)
	gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)

	sc.scene_render(s, rt.width, rt.height)

	gl.Finish()
	gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
}

// --- Per-viewpoint regression check ---

@(private)
check_viewpoint :: proc(t: ^testing.T, s: ^sc.Scene, rt: ^Render_Target, vp: Viewpoint, gen_refs: bool) {
	render_viewpoint(s, rt, vp)
	pixels := capture_framebuffer(rt)
	defer delete(pixels)

	ref_name := strings.concatenate({"ref_", vp.name, ".png"})
	defer delete(ref_name)
	ref_path := strings.concatenate({REF_DIR, ref_name})
	defer delete(ref_path)

	if gen_refs {
		// Reference generation mode
		saved := save_png(ref_path, pixels, rt.width, rt.height)
		testing.expect(t, saved, fmt.tprintf("Failed to save reference: %s", ref_path))
		return
	}

	// Comparison mode
	ref_pixels, ref_w, ref_h, load_ok := load_png(ref_path)
	if !load_ok {
		testing.expect(t, false, fmt.tprintf("Reference not found: %s (run with GEN_REFS=1 to generate)", ref_path))
		return
	}
	defer delete(ref_pixels)

	if ref_w != rt.width || ref_h != rt.height {
		testing.expect(t, false, fmt.tprintf("Reference size mismatch for '%s': ref=%dx%d rendered=%dx%d",
			vp.name, ref_w, ref_h, rt.width, rt.height))
		return
	}

	diff_pct, pass := compare_images(pixels, ref_pixels, rt.width, rt.height)
	if !pass {
		save_diff_artifacts(vp.name, pixels, ref_pixels, rt.width, rt.height)
		testing.expect(t, false, fmt.tprintf("Visual regression FAILED for '%s': %.2f%% pixels differ (max %.2f%%)",
			vp.name, diff_pct * 100.0, DIFF_PERCENTAGE_TOLERANCE * 100.0))
	}
}

// =============================================================================
// TEST: Full PBR scene multi-view visual regression
// =============================================================================

@(test)
test_visual_scene_multi_view :: proc(t: ^testing.T) {
	if !ensure_gl_context(t) { return }

	// GEN_REFS=1 → generate references instead of comparing
	gen_refs_val, gen_refs_found := os.lookup_env_alloc("GEN_REFS", context.allocator)
	gen_refs := gen_refs_found && gen_refs_val != ""
	if gen_refs_found { delete(gen_refs_val) }

	// Create FBO render target
	rt, rt_ok := render_target_create(TEST_WIDTH, TEST_HEIGHT)
	if !rt_ok {
		testing.expect(t, false, "Failed to create render target FBO")
		return
	}
	defer render_target_destroy(&rt)

	// Initialize the full scene (materials, IBL, skybox, PBR spheres)
	s: sc.Scene
	if !sc.scene_create(&s, TEST_WIDTH, TEST_HEIGHT) {
		testing.expect(t, false, "scene_create failed (check HDR/IBL/materials paths)")
		return
	}
	defer sc.scene_destroy(&s)

	// Wait for async IBL pipeline to complete (first load)
	for _ in 0..<5000 {
		sc.scene_update(&s, 0.016)
		// ISO: real app always renders between compute dispatches (GPU coherency).
		// Render into FBO to avoid polluting the default framebuffer.
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, rt.width, rt.height)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
		if !s.env_mgr.is_first_load && s.env_mgr.transition_state == .Idle && s.env_mgr.ibl_state == .Idle { break }
		// Yield to let the async loader thread complete I/O
		time.sleep(1 * time.Millisecond)
	}
	if s.env_mgr.is_first_load || s.env_mgr.transition_state != .Idle || s.env_mgr.ibl_state != .Idle {
		testing.expect(t, false, "IBL pipeline and transition did not complete within timeout")
		return
	}

	// Steady-state stabilization frames: drain any lingering GPU commands and ensure FBO convergence
	for _ in 0..<5 {
		sc.scene_update(&s, 0.016)
		gl.BindFramebuffer(gl.FRAMEBUFFER, rt.fbo)
		gl.Viewport(0, 0, rt.width, rt.height)
		gl.Clear(gl.COLOR_BUFFER_BIT | gl.DEPTH_BUFFER_BIT)
		sc.scene_render(&s, rt.width, rt.height)
		gl.BindFramebuffer(gl.FRAMEBUFFER, 0)
	}
	gl.Finish()

	// Render and check all 6 viewpoints
	viewpoints := VIEWPOINTS
	for &vp in viewpoints {
		check_viewpoint(t, &s, &rt, vp, gen_refs)
	}
}
