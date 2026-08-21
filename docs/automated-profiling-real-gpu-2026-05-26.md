# Automated Profiling & Real GPU Performance Tracking
**Date:** 2026-05-26
**Context:** Hardware-accelerated and Headless Profiling Pipeline using Tracy and xdotool.

## 1. Overview & Objectives

To deliver a high-performance rendering engine free of micro-stutters and rendering pipeline spikes, profiling must be conducted on **real, physical GPU hardware** rather than software rasterization wrappers (like Mesa's LLVMpipe). 

To make this profiling deterministic, repeatable, and easily executable in development and CI environments, this project integrates an **automated dual-mode profiling pipeline** driven by shell scripts and `Taskfile.yml` recipes.

This system:
1. Compiles the application in release/profile mode with Tracy telemetry enabled.
2. Automates window discovery, activation, and focus.
3. Automatically triggers environment map transitions using simulated keystrokes.
4. Records high-fidelity trace data (including CPU and GPU queue execution).
5. Exports telemetry directly to easily analyzable formats (CSV, `.tracy` files).

---

## 2. Quick Start / Usage

The profiling system provides two main `Taskfile.yml` recipes depending on your execution context:

### 2.1 Profile on Physical GPU (Local Dev)
To compile the application with full hardware acceleration, capture telemetry, automate environment cycling, and output trace files, run:
```bash
task profile
```
*   **Requirements**: Native Linux desktop session with an active display (defaults to `DISPLAY=:0.0`).
*   **Behavior**:
    *   Compiles the project in speed-optimized mode (`-o:speed -define:TRACY_ENABLE=true`).
    *   Launches `tracy-capture` to record telemetry.
    *   Starts the application, searches for the GLFW window titled `"suckless-odin — Icosphere Phong"`, and focuses it.
    *   Waits **4.5 seconds** to allow the startup environment load to completely finish.
    *   Sends `Page_Up` (X11 `Prior`) to cycle the environment map.
    *   Waits **6.0 seconds** to record the cycled environment map's progressive IBL compute shaders running on your GPU.
    *   Sends `Escape` to close the application cleanly.
    *   Exports statistics to CSV.

### 2.2 Headless Fallback Profile (CI/CD / Software Rendering)
To run the automated profiling session in a virtual framebuffer (useful for testing scripts, validating pipelines, or running in headless CI servers), run:
```bash
task profile-headless
```
*   **Requirements**: `Xvfb` and `xdotool` installed.
*   **Behavior**:
    *   Starts a virtual X11 server via `xvfb-run`.
    *   Uses Mesa's software LLVMpipe renderer.
    *   Uses longer timing sleeps (**25.0 seconds** per stage) to account for CPU-emulated compute shader delays, ensuring the cycling triggers successfully.

---

## 3. Telemetry Outputs & Artifacts

Every profile run generates two persistent files that are saved in the host machine:

### 3.1 Raw Tracy Trace (`/tmp/trace.tracy`)
*   **What it is**: High-fidelity, nanosecond-precise binary telemetry database.
*   **How to use it**: Open it directly using the graphical Tracy Profiler application on your workstation:
    ```bash
    tracy-profiler /tmp/trace.tracy
    ```
*   **Use cases**: 
    *   Exploring the interactive timeline of CPU and GPU execution queues.
    *   Identifying micro-stutters, frame rate variance, and driver command submission delays.
    *   Analyzing individual draw calls, framebuffer binding costs, or compute shader thread scheduling.

### 3.2 Aggregated Metric Table (`/tmp/trace.csv`)
*   **What it is**: Machine-readable statistical summary of all named zones.
*   **Data Fields**: `name`, `src_file`, `src_line`, `total_ns`, `total_perc`, `counts` (number of calls), `mean_ns`, `min_ns`, `max_ns`.
*   **Use cases**:
    *   Extracting exact execution timings.
    *   Automating performance regressions tracking (e.g., verifying that compute shader slice times remain within budget).
    *   Sanity checking call patterns.

### 3.3 Startup Telemetry & Warm-up Metrics (`/tmp/startup_telemetry.csv`)
*   **What it is**: Lightweight CSV trace capturing the engine's initialization cost and the detailed breakdown of its first 5 frames.
*   **Producer**: Written automatically by [`src/app/telemetry.odin`](../src/app/telemetry.odin) via [`src/app/app.odin`](../src/app/app.odin) as soon as `frame_index == 5`.
*   **Consumer**: Parsed and reported by [`scripts/analyze_profile.py`](../scripts/analyze_profile.py) during `task profile` and `task profile-headless`.
*   **Why it exists**: Isolates cold-start costs (shader compilation, pipeline setup, initial IBL bakes) from steady-state rendering, ensuring startup regressions are detected immediately.
*   **Structure & Manual Interpretation (Human Guide)**:
    ```csv
    metric,value
    init_time_ms,184.230
    frame_1_total_ms,12.540
    frame_1_poll_ms,0.015
    frame_1_update_ms,0.450
    frame_1_render_ms,10.200
    frame_1_swap_ms,1.875
    frame_2_total_ms,4.120
    ...
    ```
    *   `init_time_ms`: Total engine initialization duration (GLFW window creation, OpenGL 4.5 context, PBR shaders compilation, PostFX pipeline setup, initial UBO/SSBO allocations). Target: **< 300 ms** on physical GPU.
    *   `frame_1_total_ms` (Frame 1): Usually the longest frame due to first-time buffer population and GPU driver command stream initialization.
    *   `frame_N_poll_ms`: Time spent in `glfwPollEvents()` processing OS window events.
    *   `frame_N_update_ms`: CPU logic update (camera movement, state machine transitions, uniforms staging).
    *   `frame_N_render_ms`: CPU time recording OpenGL draw commands (instanced sphere grid, skybox, PostFX passes).
    *   `frame_N_swap_ms`: Time blocked in `glfwSwapBuffers()` (GPU sync, front buffer presentation, or VSync).
    *   `frame_2` to `frame_5`: Highlights frame time convergence towards target steady-state (< 4.0 ms per frame at 250 FPS).


---

## 4. Verification and Invariant Checks (Dev Guide)

To ensure the profiling run was completely successful, developers should verify key invariants in the logs and CSV trace:

### 4.1 Invariant: Double-Load Count
Because `task profile` is designed to cycle the environment map once, all major initialization and loading functions must report **exactly 2 calls** in `/tmp/trace.csv`:
*   `IBL: Upload_HDR_Texture` must have **`counts = 2`**
*   `IBL: Generate_Mipmaps` must have **`counts = 2`**
*   `IBL: Luminance_Reduction` must have **`counts = 2`**
*   `Skybox: Start Cubemap Gen` must have **`counts = 2`**
*   `IBL: Finalize` must have **`counts = 2`**

### 4.2 Invariant: Slices Processing
For each load, the environment manager splits the prefiltering workloads into progressive slices (37 slices for Specular, 12 slices for Irradiance). Therefore, the slice counts must be exactly doubled:
*   `IBL: Specular_Mip_Slice` must have **`counts = 74`** ($37 \times 2$)
*   `IBL: Irradiance_Slice` must have **`counts = 24`** ($12 \times 2$)

### 4.3 Event-Driven Synchronization & Diagnostics
The profiling runner uses event-driven synchronization (`scripts/interactive_runner.sh`) by tailing application log traces rather than arbitrary `sleep` timeouts.
*   **Synchronization Mechanism**: The runner monitors transitions into the `Idle` state (`Transition state: .* -> Idle`) before injecting keystrokes (`Page_Up`, `w`, `Page_Down`, `Escape`).
*   **Diagnostic Check**: If an environment transition fails or stalls, the runner logs a clear timeout warning indicating the exact pending state transition.


---

## 5. Performance Insights: Hardware vs. Software Rendering

Our automated trace captures reveal massive performance gains when executing natively on the physical **Intel(R) Iris(R) Xe Graphics (RPL-U)** hardware GPU compared to the CPU-based **Mesa LLVMpipe** software driver:

| Performance Zone | Mesa LLVMpipe (CPU) | Intel Iris Xe GPU (Hardware) | Hardware Acceleration | GPU Execution Details |
| :--- | :---: | :---: | :---: | :--- |
| **`Frame` (Main Loop)** | ~35.0 ms | **4.01 ms** | **8.7x** | Solid **250 FPS** with 0ms driver bubbles. |
| **`IBL: Specular_Mip_Slice`** | 870.17 ms | **0.19 ms** | **4,579x** | Parallel compute shader execution completing a slice in **193 µs**! |
| **`IBL: Generate_Mipmaps`** | 235.48 ms | **0.16 ms** | **1,470x** | GPU mipmap generation finishing in **160 µs**! |
| **`Skybox: Cubemap Gen Face`** | ~20.0 ms | **0.096 ms** | **208x** | Seamless cubemap projection face in **96 µs**! |
| **`IBL: Upload_HDR_Texture`** | 68.30 ms | **113.19 ms** | — | Asynchronous PBO upload. Returns immediately, avoiding CPU stalls. |
 
---
 
## 6. Automated Longest Frames & Root Cause Breakdown
 
To locate and eliminate frame-rate micro-stutters and spikes systematically, our profiling system includes an automated **unwrapped trace parser**. It parses all trace events, filters and ranks every `Frame` execution instance by its precise duration, and prints the **Top 5 Longest Frames** alongside their exact starting time.
 
### 6.1 Root Cause Overlap Isolation
 
For each of the top 5 longest frames, the analysis script scans the active thread traces to isolate all sub-zones (e.g., specific draw passes, compute dispatch slices, PBO transfers) that executed inside that frame's time-bounds. This isolates exact contributing bottlenecks instantly:
 
```text
================================================================================
                           TOP 5 LONGEST FRAMES DETAIL                          
================================================================================
Rank 1: Frame duration = 1150.417 ms (started at 6.043s)
   Contributing zones in this frame:
     - Scene Update                        : 1036.499 ms (Thread 1)
     - IBL: Specular_Mip_Slice             : 1036.266 ms (Thread 1)
     - Render_Frame                        :  56.990 ms (Thread 1)
     - Scene Render                        :  56.503 ms (Thread 1)
```
 
*   **Benefits**:
    *   **No Manual Tracing**: Instantly points out the exact lines or compute passes responsible for a spike.
    *   **CI Visibility**: Outputs directly to standard console output, providing immediate visibility in build logs during automated PR profiling checks.

