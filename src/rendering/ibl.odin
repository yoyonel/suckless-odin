package rendering

import gl "vendor:OpenGL"
import "core:os"
import "core:strings"
import "core:fmt"

import dbg "../core/gl_debug"
import log "../core/log"
import settings "../core/settings"
import tracy "../core/tracy"

// IBL textures produced by compute shaders
IBL_Resources :: struct {
	irradiance_map: u32,  // unit 15
	prefilter_map:  u32,  // unit 16
	brdf_lut:       u32,  // unit 17

	// Compute programs
	irmap_program:  u32,
	spmap_program:  u32,
	spbrdf_program: u32,

	// Progressive/amortized startup state
	brdf_lut_computed:   bool,
	brdf_lut_row_offset: i32,
}

IBL_TRACY_COLOR :: 0x88C0D0

// Sizes matching suckless-ogl
IRRADIANCE_SIZE :: 64
PREFILTER_SIZE  :: 1024
BRDF_LUT_SIZE   :: 512
PREFILTER_MIP_LEVELS :: 11  // ISO C11: floor(log2(PREFILTER_SIZE)) + 1 = full mip chain

IBL_IRRADIANCE_UNIT :: 15
IBL_PREFILTER_UNIT  :: 16
IBL_BRDF_LUT_UNIT   :: 17

// Initialize IBL resources: compile compute programs + generate BRDF LUT.
// Irradiance and prefilter maps are computed progressively by the env_manager.
ibl_init :: proc(ibl: ^IBL_Resources, tuning: settings.Compute_Tuning_Params) -> bool {
	spbrdf_defines := fmt.tprintf("#define SAMPLE_COUNT %du\n", tuning.spbrdf_sample_count)
	spmap_defines  := fmt.tprintf("#define SAMPLE_COUNT %du\n", tuning.spmap_sample_count)
	irmap_defines  := fmt.tprintf("#define SAMPLE_DELTA %f\n", tuning.irmap_sample_delta)

	// Load compute shaders
	ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl", irmap_defines) or_return
	ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl", spmap_defines) or_return
	ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl", spbrdf_defines) or_return

	// --- BRDF LUT (view-independent, computed progressively) ---
	gl.GenTextures(1, &ibl.brdf_lut)
	gl.BindTexture(gl.TEXTURE_2D, ibl.brdf_lut)
	gl.TexStorage2D(gl.TEXTURE_2D, 1, gl.RG16F, BRDF_LUT_SIZE, BRDF_LUT_SIZE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR)
	gl.TexParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR)
	dbg.object_label(gl.TEXTURE, ibl.brdf_lut, "IBL_BRDF_LUT")

	ibl.brdf_lut_computed = false
	ibl.brdf_lut_row_offset = 0

	gl.BindTexture(gl.TEXTURE_2D, 0)

	// Irradiance and prefilter maps are managed by the Env_Manager double-buffered pool.
	// Initialized to 0 here and bound to the pool at scene creation.
	ibl.irradiance_map = 0
	ibl.prefilter_map  = 0

	return true
}

// Bind IBL textures to their fixed texture units for rendering
ibl_bind :: proc(ibl: ^IBL_Resources) {
	gl.ActiveTexture(gl.TEXTURE0 + IBL_IRRADIANCE_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.irradiance_map)

	gl.ActiveTexture(gl.TEXTURE0 + IBL_PREFILTER_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.prefilter_map)

	gl.ActiveTexture(gl.TEXTURE0 + IBL_BRDF_LUT_UNIT)
	gl.BindTexture(gl.TEXTURE_2D, ibl.brdf_lut)
}

// Update BRDF LUT progressively over multiple frames (32 rows per frame).
ibl_update_brdf_lut :: proc(ibl: ^IBL_Resources) {
	if ibl == nil || ibl.brdf_lut_computed { return }

	zone := tracy.hybrid_perf_zone_begin(&tracy.SRCLOC_HYBRID_BRDF)
	defer tracy.hybrid_perf_zone_end(zone)

	dbg.push_group("IBL: BRDF_LUT_Slice")
	gl.UseProgram(ibl.spbrdf_program)
	gl.Uniform1i(0, ibl.brdf_lut_row_offset)
	gl.BindImageTexture(0, ibl.brdf_lut, 0, false, 0, gl.WRITE_ONLY, gl.RG16F)

	// Dispatch 32 rows progressively (512x32)
	// Local work group size in shader: local_size_x = 16, local_size_y = 16 (OPT-05)
	// For width=512: gx = 512 / 16 = 32
	// For height=32: gy = 32 / 16 = 2
	gl.DispatchCompute(32, 2, 1)
	gl.MemoryBarrier(gl.TEXTURE_FETCH_BARRIER_BIT)
	dbg.pop_group()

	ibl.brdf_lut_row_offset += 32
	if ibl.brdf_lut_row_offset >= BRDF_LUT_SIZE {
		ibl.brdf_lut_computed = true
		log.log_info("perf.ibl", "IBL: Progressive BRDF LUT precomputation completed successfully")
	}
}

// Recompile IBL compute shaders with new preprocessor defines.
// Safely deletes existing programs to prevent GPU resource leaks.
ibl_recompile_shaders :: proc(ibl: ^IBL_Resources, tuning: settings.Compute_Tuning_Params) -> bool {
	// Delete existing programs if they exist
	if ibl.irmap_program  != 0 { gl.DeleteProgram(ibl.irmap_program); ibl.irmap_program = 0 }
	if ibl.spmap_program  != 0 { gl.DeleteProgram(ibl.spmap_program); ibl.spmap_program = 0 }
	if ibl.spbrdf_program != 0 { gl.DeleteProgram(ibl.spbrdf_program); ibl.spbrdf_program = 0 }

	spbrdf_defines := fmt.tprintf("#define SAMPLE_COUNT %du\n", tuning.spbrdf_sample_count)
	spmap_defines  := fmt.tprintf("#define SAMPLE_COUNT %du\n", tuning.spmap_sample_count)
	irmap_defines  := fmt.tprintf("#define SAMPLE_DELTA %f\n", tuning.irmap_sample_delta)

	// Compile and link programs
	ibl.irmap_program  = load_compute_shader("shaders/IBL/irmap.glsl", irmap_defines) or_return
	ibl.spmap_program  = load_compute_shader("shaders/IBL/spmap.glsl", spmap_defines) or_return
	ibl.spbrdf_program = load_compute_shader("shaders/IBL/spbrdf.glsl", spbrdf_defines) or_return

	// Reset BRDF LUT computation status to trigger progressive recalculation
	ibl.brdf_lut_computed = false
	ibl.brdf_lut_row_offset = 0

	return true
}

ibl_destroy :: proc(ibl: ^IBL_Resources) {
	if ibl.brdf_lut       != 0 { gl.DeleteTextures(1, &ibl.brdf_lut); ibl.brdf_lut = 0 }
	if ibl.irmap_program  != 0 { gl.DeleteProgram(ibl.irmap_program); ibl.irmap_program = 0 }
	if ibl.spmap_program  != 0 { gl.DeleteProgram(ibl.spmap_program); ibl.spmap_program = 0 }
	if ibl.spbrdf_program != 0 { gl.DeleteProgram(ibl.spbrdf_program); ibl.spbrdf_program = 0 }
	ibl^ = {}
}

// ---- Internal helpers ----

@(private)
dispatch_compute :: proc(width, height: i32) {
	gx := (width  + 31) / 32
	gy := (height + 31) / 32
	gl.DispatchCompute(u32(gx), u32(gy), 1)
}

@(private)
load_compute_shader :: proc(path: string, defines: string = "") -> (u32, bool) {
	data, err := os.read_entire_file_from_path(path, context.allocator)
	if err != nil {
		log.log_error("suckless-odin.ibl", "Failed to read compute shader: %s", path)
		return 0, false
	}
	defer delete(data)
	src := string(data)

	src_to_compile := src
	defer if len(defines) > 0 { delete(src_to_compile) }

	if len(defines) > 0 {
		src_to_compile = inject_defines(src, defines)
	}

	shader := gl.CreateShader(gl.COMPUTE_SHADER)
	src_cstr := strings.clone_to_cstring(src_to_compile)
	defer delete(src_cstr)
	gl.ShaderSource(shader, 1, &src_cstr, nil)
	gl.CompileShader(shader)

	success: i32
	gl.GetShaderiv(shader, gl.COMPILE_STATUS, &success)
	if success == 0 {
		buf: [1024]u8
		log_len: i32
		gl.GetShaderInfoLog(shader, 1024, &log_len, &buf[0])
		log.log_error("suckless-odin.ibl", "Compute shader compile error (%s):\n%s", path, cstring(&buf[0]))
		gl.DeleteShader(shader)
		return 0, false
	}

	program := gl.CreateProgram()
	gl.AttachShader(program, shader)
	gl.LinkProgram(program)

	gl.GetProgramiv(program, gl.LINK_STATUS, &success)
	if success == 0 {
		buf: [1024]u8
		log_len: i32
		gl.GetProgramInfoLog(program, 1024, &log_len, &buf[0])
		log.log_error("suckless-odin.ibl", "Compute shader link error (%s):\n%s", path, cstring(&buf[0]))
		gl.DeleteShader(shader)
		gl.DeleteProgram(program)
		return 0, false
	}

	gl.DeleteShader(shader)
	log.log_info("suckless-odin.ibl", "Compute shader loaded: %s (program=%d)", path, program)
	return program, true
}

@(private)
inject_defines :: proc(source: string, defines: string) -> string {
	if len(defines) == 0 { return strings.clone(source) }

	// Find end of #version line
	version_end := strings.index(source, "\n")
	if version_end < 0 {
		// No newline, just prepend defines
		return strings.concatenate({source, "\n", defines})
	}

	// Insert after #version line
	return strings.concatenate({source[:version_end + 1], defines, source[version_end + 1:]})
}
