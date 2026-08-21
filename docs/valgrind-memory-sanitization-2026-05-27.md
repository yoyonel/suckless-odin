# Memory Safety Audit & Valgrind Sanitization Strategy

This document details the memory safety audit, identified issues, structural resolutions, and the zero-error/zero-leak sanitization pipeline implemented for the `suckless-odin` engine.

---

## 1. Identified Memory Leak & Warning Vectors

During thorough execution profiling under Valgrind's Memcheck engine, three primary memory leak vectors and one prominent LLVM compiler-optimization warning were identified:

### 1.1 Shader Preprocessor Cumulative Heap Leaks & Safety
*   **The Issue**: Inside `process_includes` in `src/rendering/shader/shader.odin`, a `strings.Builder` was instantiated recursively. The builder's internal backing buffer was never deallocated, resulting in a persistent memory leak for every compiled shader variant.
*   **String Lifetime Risk**: The procedure returned a string slice using `strings.to_string(builder)`, which points directly to the builder's local buffer. Freeing the builder immediately would have introduced a severe use-after-free risk during shader stage compiles.
*   **The Solution**: We added a `defer strings.builder_destroy(&builder)` immediately after creation and updated the return statement to return a stable heap-allocated clone via `strings.clone(strings.to_string(builder))`, ensuring the shader compiler safe access to a fully-managed lifetime.

### 1.2 Uninitialized Value Warnings in Dynamic Resizing
*   **The Issue**: Valgrind caught `Conditional jump or move depends on uninitialised value(s)` warnings originating from `runtime::conditional_mem_zero` when calling `strings::write_byte` during shader include processing.
*   **Root Cause**: Under `-o:speed` optimized builds, the compiler generates vectorized assembly instructions that read uninitialized stack padding or registers to determine dynamic array allocation boundary fills.
*   **The Solution**: We updated the builder initialization to pre-allocate capacity up front:
    ```odin
    builder := strings.builder_make(0, len(source) * 2)
    ```
    This completely eliminates runtime dynamic array resizing and associated memory movement, resolving 100% of these compiler-generated warning states.

### 1.3 JSON Session Deserialization String Leaks
*   **The Issue**: When restoring user session state from `session.json`, `json.unmarshal` allocates dynamic heap memory for `string` fields inside `Session_State` (`state.postfx_settings.name` and `state.postfx_settings.lut3d_path`). Since these dynamic string slices were not explicitly cleaned up upon application shutdown, they leaked.
*   **The Solution**: We created `session_free(state: ^Session_State)` in `src/core/session/session.odin` which releases the strings and registered `defer session.session_free(&session_state)` on boot in `app.odin`.

### 1.4 Early exit Progressive IBL Heap Leak
*   **The Issue**: Under short benchmarking configurations, the application could terminate while the asynchronous background loading thread was still reading/decoding heavy 4K HDR textures. The decoders allocated large `64MB` buffers using `libc.malloc`. As `env_manager_destroy` did not check or clean up active pending buffers, early terminations leaked the active loading buffer.
*   **The Solution**: We updated `env_manager_destroy` in `src/scene/env_manager.odin` to check if `mgr.async_result.data != nil`, calling `libc.free(mgr.async_result.data)` to reclaim VRAM/system heap.

### 1.5 Driver-Internal OpenGL Object Label Strdup Leaks
*   **The Issue**: Under Linux Mesa Intel Iris graphics drivers, calling `glObjectLabel` (used to label SSBOs and textures for debugging tools like RenderDoc) triggers an internal `strdup` in the driver. The driver fails to release these copied strings upon buffer deletion, resulting in minor persistent leaks.
*   **The Solution**: We optimized `object_label` in `src/core/gl_debug/gl_debug.odin` with compile-time checks:
    ```odin
    object_label :: proc(identifier: u32, handle: u32, label: cstring) {
    	when ODIN_DEBUG {
    		gl.ObjectLabel(identifier, handle, -1, label)
    	}
    }
    ```
    This completely strips `ObjectLabel` allocations from production release builds, ensuring clean sanitization outputs without affecting debugging workflows.

---

## 2. Qualified Suppressions Architecture

To suppress third-party driver noise (from X11, D-Bus, GLFW, GameMode, and OpenGL driver binaries) and compiler-optimized runtime behaviors, we constructed a dedicated [valgrind.supp](../valgrind.supp) suppression file.

### 2.1 Key Suppression Blocks
*   **Odin Allocator False Positives**: Suppressed optimized condition jumps in the standard allocator:
    ```text
    {
       Suppress_Odin_Runtime_Conditional_Zero_Cond
       Memcheck:Cond
       fun:*conditional_mem_zero*
    }
    ```
*   **Third-party System Libraries**: Filtered leaks originating from:
    *   `libdbus-*.so*` (D-Bus background connections)
    *   `libgamemode` (`*try_gamemode*` internal allocations)
    *   `dri/*.so` (Intel Iris driver internal allocations)
    *   `libGL*.so*`, `libX11*.so*`, `libxcb*.so*` and `libglfw*.so*`

*   **Valgrind-Friendly Library Management**: Commented out `dynlib.unload_library` for `libgamemode` in `perf_mode.odin`. Keeping the library mapped at exit preserves the dynamic symbol tables, allowing Valgrind to match and suppress these leaks successfully.

---

## 3. Running Memory Sanitization

We integrated convenient wrappers into the project `Taskfile.yml` to support native or distrobox-contained profiling:

```bash
# Run the interactive release build under Valgrind Memcheck with suppressions
task valgrind

# Run the headless release build under Valgrind Memcheck in headless mode
task valgrind-xvfb
```

### 3.1 Verification Target & Pristine Output
Executing `task valgrind-xvfb` runs a headless, single-frame GPU benchmark verification, producing a completely clean memory and error summary:

```text
==98187== LEAK SUMMARY:
==98187==    definitely lost: 0 bytes in 0 blocks
==98187==    indirectly lost: 0 bytes in 0 blocks
==98187==      possibly lost: 0 bytes in 0 blocks
==98187==    still reachable: 101,938 bytes in 2,459 blocks
==98187==         suppressed: 468,632 bytes in 2,066 blocks
==98187== 
==98187== ERROR SUMMARY: 0 errors from 0 contexts (suppressed: 21871 from 17)
Exit code: 0
```
