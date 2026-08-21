# Architecture Decision Record: Native C Implementation for SIMD & HDR Decoding

**Date:** 2026-08-18  
**Status:** Accepted  
**Context:** Design rationale for implementing `deps/simd_utils.c` in native C rather than pure Odin.

---

## 1. Context & Problem Statement

The rendering engine processes 4K Radiance RGBE HDR maps (`4096x2048`), representing ~8.39 million pixels (33.55 million sub-pixels) per environment.
To achieve smooth runtime environment transitions without micro-stutters:
1. HDR files must be decoded from RLE format in memory.
2. Pixel components must be converted from IEEE 754 32-bit floating point (FP32) to half-precision 16-bit float (FP16).
3. The resulting ~64 MB buffer must be transferred to GPU DMA staging without causing CPU cache thrashing.

The question arose: **Why is `deps/simd_utils.c` written in C rather than pure Odin?**

---

## 2. Decision & Key Technical Rationales

We chose to implement the SIMD compute kernel and parallel scanline decoder in native C (`deps/simd_utils.c` + `deps/simd_utils.h`) and bind it to Odin via `foreign import` (`src/core/simd_utils/simd_utils.odin`).

### 2.1 Hardware-Specific x86 Intrinsics (F16C & Streaming Stores)
* **F16C Hardware Instruction Set**:
  * `_mm256_cvtps_ph` and `_mm_cvtph_ps` perform 8 float conversions to FP16 in a single hardware cycle.
  * In the Odin standard library (`core:simd/x86`), F16C conversion intrinsics and non-temporal streaming stores are not uniformly exposed or require inline LLVM IR wrappers.
* **Non-Temporal Streaming Stores (`_mm_stream_si128` / `vmovntdq`)**:
  * Bypasses the CPU cache hierarchy (L1/L2/L3) when writing the ~64 MB decoded FP16 buffer to DRAM.
  * Eliminates **Read-For-Ownership (RFO)** cache line fetch traffic on write misses, preserving L1/L2 cache lines for renderer structures, framebuffers, and UI state.
  * Ensures memory consistency via explicit hardware `_mm_sfence()`.

### 2.2 Micro-Architecture Compiler Flag Isolation
* `deps/simd_utils.c` is compiled specifically with `-O3 -mavx2 -mf16c`.
* This isolates high-end vectorization instructions to this compilation unit, allowing the rest of the Odin codebase to remain broadly portable across x86-64 baselines without forcing blanket AVX2 flags across the entire engine.

### 2.3 Lightweight Zero-Overhead POSIX Worker Threads
* The scanline parser distributes work across 8 logical cores via direct `pthread_create` / `pthread_join`.
* Avoids instantiating per-thread Odin runtime contexts, allocator tracking, or fiber scheduler structures for short-lived, purely numerical compute batches.

### 2.4 ISO Parity & Codebase Consistency
* Directly ports and shares verified SIMD kernels from sister projects (`suckless-vulkan` and `suckless-ogl`).
* Provides 100% bit-for-bit mathematical and numerical parity with reference C implementations.

---

## 3. Integration in Odin

The C library is linked into Odin using standard foreign function interfaces:

```odin
// src/core/simd_utils/simd_utils.odin
package simd_utils

foreign import simd "deps/simd_utils.c"

@(default_calling_convention="c")
foreign simd {
    fast_hdr_decode_fp16_threaded :: proc(
        data: [^]u8,
        size: uint,
        out_w, out_h: ^i32,
        out_fp16: [^]u16,
        max_elements: uint,
        flip_y: i32,
        num_threads: i32,
    ) -> i32 ---
}
```

---

## 4. Maintenance & Evolution

* **Unit Testing**: Validated via `task test-simd` ([`tests/test_simd.odin`](../tests/test_simd.odin)), comparing scalar vs. SIMD multi-threaded output bit-for-bit.
* **Profiling**: Monitored continuously with `task profile-callgrind` and `task profile-tracy`.
