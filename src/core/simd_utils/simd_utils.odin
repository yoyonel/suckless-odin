package simd_utils

// SIMD FP32→FP16 conversion — ISO: suckless-ogl/src/simd_utils.c
// Uses AVX2/F16C intrinsics (compiled with -mavx2 -mf16c).
// Linked via deps/libtracy.a (shared native deps archive).

when ODIN_OS == .Windows {
	foreign import lib "../../../deps/libsimd_windows_x64.lib"
} else {
	foreign import lib "../../../deps/libsimd.a"
}

@(default_calling_convention = "c")
foreign lib {
	// Convert `count` float32 values to float16 (half) values using SIMD AVX2/F16C with Non-Temporal Streaming Stores.
	convert_float_to_half_simd :: proc(src: [^]f32, dst: [^]u16, count: uint) ---

	// IEEE 754 float32 -> float16 scalar conversion reference (for testing / validation).
	convert_float_to_half_scalar :: proc(src: [^]f32, dst: [^]u16, count: uint) ---

	// Extract width & height from Radiance HDR file in memory without decoding.
	fast_hdr_get_dimensions :: proc(data: [^]u8, size: uint, out_w, out_h: ^i32) -> i32 ---

	// Fast direct Radiance HDR (RGBE) -> FP16 Decoder with AVX2 streaming stores (0 heap allocs).
	// Returns 1 on success, 0 on failure.
	fast_hdr_decode_fp16 :: proc(data: [^]u8, size: uint, out_w, out_h: ^i32, out_fp16: [^]u16, max_elements: uint, flip_y: i32) -> i32 ---

	// Multi-threaded fast direct Radiance HDR (RGBE) -> FP16 Decoder across `num_threads` CPU cores.
	fast_hdr_decode_fp16_threaded :: proc(data: [^]u8, size: uint, out_w, out_h: ^i32, out_fp16: [^]u16, max_elements: uint, flip_y: i32, num_threads: i32) -> i32 ---
}
