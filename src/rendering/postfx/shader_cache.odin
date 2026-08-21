package postfx

import gl "vendor:OpenGL"
import "core:fmt"
import "core:strings"

import log "../../core/log"
import shader "../shader"

// Shader variant cache — compile optimized uber-shader variants
// with #define flags that eliminate dead branches at compile time.

MAX_CACHED_VARIANTS :: 64

Shader_Variant :: struct {
	program: u32,
	effects: Effect_Flags,
}

Shader_Cache :: struct {
	variants: [MAX_CACHED_VARIANTS]Shader_Variant,
	count:    i32,
	enabled:  bool,
}

// Try to find a cached variant for the given effect flags.
// Returns program ID or 0 if not cached. Promotes to index 0 on hit (LRU).
shader_cache_find :: proc(cache: ^Shader_Cache, effects: Effect_Flags) -> u32 {
	if !cache.enabled { return 0 }
	for i in 0 ..< cache.count {
		if cache.variants[i].effects == effects {
			// Found it! Promote to index 0 (LRU MRU policy)
			if i > 0 {
				entry := cache.variants[i]
				for j := i; j > 0; j -= 1 {
					cache.variants[j] = cache.variants[j - 1]
				}
				cache.variants[0] = entry
			}
			return cache.variants[0].program
		}
	}
	return 0
}

// Compile and cache a shader variant for the given effect flags.
// Returns the compiled program, or 0 on failure. Evicts LRU when full.
shader_cache_compile :: proc(cache: ^Shader_Cache, effects: Effect_Flags) -> u32 {
	if !cache.enabled { return 0 }

	// Build #define preamble
	preamble := build_defines_preamble(effects)
	defer delete(preamble)

	// Load and prepend defines to fragment shader source
	program, ok := shader.load_program_with_defines(
		"shaders/postfx/postfx.vert",
		"shaders/postfx/postfx.frag",
		preamble,
	)
	if !ok {
		log.log_warning("suckless-odin.postfx.shader_cache", "Failed to compile variant")
		return 0
	}

	// Set ALL sampler uniforms (fixes missing depth/exposure/dof bindings)
	gl.UseProgram(program)
	set_sampler_uniforms(program)
	set_split_colors_uniform(program)
	gl.UseProgram(0)

	// Move existing entries down to make room at index 0 (LRU eviction)
	move_count := cache.count
	if move_count >= MAX_CACHED_VARIANTS {
		// Cache full: evict LRU (last entry)
		if cache.variants[MAX_CACHED_VARIANTS - 1].program != 0 {
			gl.DeleteProgram(cache.variants[MAX_CACHED_VARIANTS - 1].program)
			cache.variants[MAX_CACHED_VARIANTS - 1].program = 0
		}
		move_count = MAX_CACHED_VARIANTS - 1
	} else {
		cache.count += 1
	}

	if move_count > 0 {
		for j := move_count; j > 0; j -= 1 {
			cache.variants[j] = cache.variants[j - 1]
		}
	}

	// Store new variant at index 0 (MRU)
	cache.variants[0] = {program = program, effects = effects}

	log.log_info("suckless-odin.postfx.shader_cache", "Compiled variant (cache size: %d/%d, effects: 0x%08X)", cache.count, MAX_CACHED_VARIANTS, transmute(u32)effects)
	return program
}

// Destroy all cached shader variants.
shader_cache_destroy :: proc(cache: ^Shader_Cache) {
	for i in 0 ..< cache.count {
		if cache.variants[i].program != 0 {
			gl.DeleteProgram(cache.variants[i].program)
			cache.variants[i].program = 0
		}
	}
	cache.count = 0
}

// Build GLSL #define preamble for the given effects.
// Inserts after #version line when prepended.
@(private)
build_defines_preamble :: proc(effects: Effect_Flags) -> string {
	b := strings.builder_make()
	defer strings.builder_destroy(&b)

	// Static defines that override runtime bitfield checks
	fmt.sbprintf(&b, "#define STATIC_VIGNETTE %d\n", 1 if .Vignette in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_GRAIN %d\n", 1 if .Grain in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_EXPOSURE %d\n", 1 if .Exposure in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_CHROM_ABBR %d\n", 1 if .Chrom_Abbr in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_BLOOM %d\n", 1 if .Bloom in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_COLOR_GRADING %d\n", 1 if .Color_Grading in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_DOF %d\n", 1 if .Dof in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_AUTO_EXPOSURE %d\n", 1 if .Auto_Exposure in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_MOTION_BLUR %d\n", 1 if .Motion_Blur in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_FXAA %d\n", 1 if .FXAA in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_TONEMAP %d\n", 1 if .Tonemap in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_BANDING %d\n", 1 if .Banding in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_FOG %d\n", 1 if .Fog in effects else 0)
	fmt.sbprintf(&b, "#define STATIC_LUT3D %d\n", 1 if .LUT3D in effects else 0)

	return strings.clone(strings.to_string(b))
}
