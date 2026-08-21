package camera

import mt "../core/math_types"
import "core:math"

// Camera defaults (ISO port of camera.h defines)
DEFAULT_CAMERA_SPEED          :: 15.0
DEFAULT_CAMERA_SENSITIVITY    :: 0.15
DEFAULT_CAMERA_ZOOM           :: 60.0
DEFAULT_ZOOM_SPEED            :: 1.0
DEFAULT_SCROLL_SENSITIVITY    :: 50.0
DEFAULT_MAX_PITCH             :: 89.0
DEFAULT_MIN_PITCH             :: -89.0
DEFAULT_MAX_ALPHA             :: 1.0
DEFAULT_ACCELERATION          :: 10.0
DEFAULT_FRICTION              :: 0.85
DEFAULT_ROTATION_SMOOTHING    :: 0.18
DEFAULT_BOBBING_FREQUENCY     :: 2.2
DEFAULT_BOBBING_AMPLITUDE     :: 0.0004
DEFAULT_MIN_VELOCITY_FOR_BOBBING :: 0.5
DEFAULT_BOBBING_RESET_SPEED   :: 0.95
DEFAULT_MIN_VELOCITY          :: 0.01
DEFAULT_TARGET_FPS            :: 60
DEFAULT_FIXED_TIMESTEP        :: 1.0 / f32(DEFAULT_TARGET_FPS)
DEFAULT_MOUSE_SMOOTHING_FACTOR :: 0.1

// First-person camera with realistic physics and head-bobbing.
// ISO port of camera.h/camera.c from suckless-ogl.
Camera :: struct {
	position:   mt.Vec3,
	front:      mt.Vec3,
	up:         mt.Vec3,
	right:      mt.Vec3,
	world_up:   mt.Vec3,

	yaw:        f32,
	pitch:      f32,

	velocity:   f32,   // Maximum movement speed
	sensitivity: f32,  // Mouse sensitivity factor
	zoom:       f32,   // Current FOV in degrees

	// Movement states
	move_forward:  bool,
	move_backward: bool,
	move_left:     bool,
	move_right_:   bool,  // suffixed to avoid shadowing .right field
	move_up_:      bool,
	move_down:     bool,

	// Unified movement input [-1,1] per camera-local axis
	// [0] = right/left, [1] = up/down, [2] = forward/backward
	move_input: mt.Vec3,

	// Realistic physics
	velocity_current: mt.Vec3,
	acceleration:     f32,
	friction:         f32,

	// Smooth rotation
	yaw_target:         f32,
	pitch_target:       f32,
	rotation_smoothing: f32,
	smoothed_x:         f32,
	smoothed_y:         f32,

	// Head bobbing
	bobbing_time:       f32,
	bobbing_frequency:  f32,
	bobbing_amplitude:  f32,
	bobbing_enabled:    bool,

	// Timing
	physics_accumulator: f32,
	fixed_timestep:      f32,
	mouse_smoothing_factor: f32,

	// Input state
	last_mouse_x: f64,
	last_mouse_y: f64,
	first_mouse:  bool,
}

// Initializes camera with default values (ISO port of camera_init)
init :: proc(cam: ^Camera, distance: f32, yaw: f32, pitch: f32) {
	cam.position = mt.Vec3{0, 0, distance}
	cam.world_up = mt.VEC3_UP

	cam.yaw = yaw
	cam.pitch = pitch
	cam.velocity = DEFAULT_CAMERA_SPEED
	cam.sensitivity = DEFAULT_CAMERA_SENSITIVITY
	cam.zoom = DEFAULT_CAMERA_ZOOM

	cam.move_forward  = false
	cam.move_backward = false
	cam.move_left     = false
	cam.move_right_   = false
	cam.move_up_      = false
	cam.move_down     = false
	cam.move_input    = mt.VEC3_ZERO

	cam.velocity_current = mt.VEC3_ZERO
	cam.acceleration     = DEFAULT_ACCELERATION
	cam.friction         = DEFAULT_FRICTION

	cam.yaw_target         = yaw
	cam.pitch_target       = pitch
	cam.rotation_smoothing = DEFAULT_ROTATION_SMOOTHING
	cam.smoothed_x         = 0
	cam.smoothed_y         = 0

	cam.bobbing_time      = 0
	cam.bobbing_frequency = DEFAULT_BOBBING_FREQUENCY
	cam.bobbing_amplitude = DEFAULT_BOBBING_AMPLITUDE
	cam.bobbing_enabled   = true

	cam.physics_accumulator    = 0
	cam.fixed_timestep         = DEFAULT_FIXED_TIMESTEP
	cam.mouse_smoothing_factor = DEFAULT_MOUSE_SMOOTHING_FACTOR

	cam.last_mouse_x = 0
	cam.last_mouse_y = 0
	cam.first_mouse  = true

	update_vectors(cam)
}

// Recomputes front/right/up from yaw/pitch (ISO port of camera_update_vectors)
update_vectors :: proc(cam: ^Camera) {
	front: mt.Vec3
	front.x = math.cos(mt.radians(cam.yaw)) * math.cos(mt.radians(cam.pitch))
	front.y = math.sin(mt.radians(cam.pitch))
	front.z = math.sin(mt.radians(cam.yaw)) * math.cos(mt.radians(cam.pitch))
	cam.front = mt.vec3_normalize(front)

	cam.right = mt.vec3_normalize(mt.vec3_cross(cam.front, cam.world_up))
	cam.up    = mt.vec3_normalize(mt.vec3_cross(cam.right, cam.front))
}

// Builds unified input from keyboard flags if keys are active (ISO port of camera_build_keyboard_input)
build_keyboard_input :: proc(cam: ^Camera) {
	kb_x := f32(i32(cam.move_right_)  - i32(cam.move_left))
	kb_y := f32(i32(cam.move_up_)      - i32(cam.move_down))
	kb_z := f32(i32(cam.move_forward)  - i32(cam.move_backward))

	if kb_x != 0 || kb_y != 0 || kb_z != 0 {
		cam.move_input = mt.Vec3{kb_x, kb_y, kb_z}
	}
}

// Fixed-timestep physics update (ISO port of camera_fixed_update)
fixed_update :: proc(cam: ^Camera) {
	target_velocity := mt.VEC3_ZERO

	// Forward / backward
	if abs(cam.move_input.z) > 0 {
		target_velocity += mt.vec3_scale(cam.front, cam.move_input.z * cam.velocity)
	}
	// Right / left
	if abs(cam.move_input.x) > 0 {
		target_velocity += mt.vec3_scale(cam.right, cam.move_input.x * cam.velocity)
	}
	// Up / down
	if abs(cam.move_input.y) > 0 {
		target_velocity += mt.vec3_scale(cam.world_up, cam.move_input.y * cam.velocity)
	}

	// Interpolation
	alpha := cam.acceleration * cam.fixed_timestep
	if alpha > DEFAULT_MAX_ALPHA {
		alpha = DEFAULT_MAX_ALPHA
	}
	cam.velocity_current = mt.vec3_lerp(cam.velocity_current, target_velocity, alpha)

	// Friction
	target_norm := mt.vec3_length(target_velocity)
	if target_norm < DEFAULT_MIN_VELOCITY {
		cam.velocity_current = mt.vec3_scale(cam.velocity_current, cam.friction)
	}

	// Position update
	movement := mt.vec3_scale(cam.velocity_current, cam.fixed_timestep)
	cam.position += movement

	// Head bobbing
	if cam.bobbing_enabled {
		current_speed := mt.vec3_length(cam.velocity_current)
		if current_speed > DEFAULT_MIN_VELOCITY_FOR_BOBBING {
			cam.bobbing_time += cam.fixed_timestep * current_speed / cam.velocity
			bobbing_offset := math.sin(cam.bobbing_time * cam.bobbing_frequency) * cam.bobbing_amplitude
			cam.position.y += bobbing_offset
		} else {
			cam.bobbing_time *= DEFAULT_BOBBING_RESET_SPEED
		}
	}
}

// Processes mouse movement (ISO port of camera_process_mouse)
process_mouse :: proc(cam: ^Camera, xoffset, yoffset: f32) {
	cam.smoothed_x = cam.mouse_smoothing_factor * cam.smoothed_x + (1.0 - cam.mouse_smoothing_factor) * xoffset
	cam.smoothed_y = cam.mouse_smoothing_factor * cam.smoothed_y + (1.0 - cam.mouse_smoothing_factor) * yoffset

	cam.yaw_target   += cam.smoothed_x * cam.sensitivity
	cam.pitch_target += cam.smoothed_y * cam.sensitivity

	// Clamp pitch
	if cam.pitch_target > DEFAULT_MAX_PITCH {
		cam.pitch_target = DEFAULT_MAX_PITCH
	}
	if cam.pitch_target < DEFAULT_MIN_PITCH {
		cam.pitch_target = DEFAULT_MIN_PITCH
	}
}

// Smooth rotation interpolation (ISO port of camera_smooth_rotation)
smooth_rotation :: proc(cam: ^Camera) {
	cam.yaw   += (cam.yaw_target - cam.yaw) * cam.rotation_smoothing
	cam.pitch += (cam.pitch_target - cam.pitch) * cam.rotation_smoothing
	update_vectors(cam)
}

// Process scroll wheel input — forward velocity impulse along camera front.
// ISO port of camera_process_scroll from suckless-ogl/src/camera.c.
process_scroll :: proc(cam: ^Camera, yoffset: f32) {
	impulse := mt.vec3_scale(cam.front, yoffset * DEFAULT_SCROLL_SENSITIVITY)
	cam.velocity_current += impulse
}

// Get view matrix (ISO port of camera_get_view_matrix)
get_view_matrix :: proc(cam: ^Camera) -> mt.Mat4 {
	center := cam.position + cam.front
	return mt.look_at(cam.position, center, cam.up)
}

// Full update with fixed timestep (ISO port of camera_update)
update :: proc(cam: ^Camera, delta_time: f32) {
	cam.physics_accumulator += delta_time

	build_keyboard_input(cam)

	for cam.physics_accumulator >= cam.fixed_timestep {
		fixed_update(cam)
		cam.physics_accumulator -= cam.fixed_timestep
	}

	smooth_rotation(cam)
}
