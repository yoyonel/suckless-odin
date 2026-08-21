package gui

import "core:fmt"
import "core:math"
import imgui "../../deps/odin-imgui"
import perf_mode "../core/perf_mode"
import postfx "../rendering/postfx"

// ─── Post-FX Section (live controls) ───────────────────────────────────────────

// Per-effect split line colors — indexed from Glasbey palette (maximin CIELAB).
// Must match shader splitColors[] uniform (indexed by Post_Effect ordinal).

// Show a colored "[S]" marker if the effect has an active A/B split.
@(private)
draw_split_indicator :: proc(p: ^postfx.Pipeline, effect: postfx.Post_Effect) {
	if effect in p.debug_split {
		palette := postfx.GLASBEY_256
		rgb := palette[u32(effect)]
		color := imgui.Vec4{rgb[0], rgb[1], rgb[2], 1.0}
		imgui.SameLine()
		imgui.TextColored(color, "[S]")
	}
}

@(private)
draw_postfx_exposure :: proc(p: ^postfx.Pipeline) {
	exposure_on := postfx.Post_Effect.Exposure in p.active_effects
	if imgui.Checkbox("Exposure", &exposure_on) {
		postfx.pipeline_toggle(p, .Exposure)
	}
	draw_split_indicator(p, .Exposure)
	if exposure_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##exposure", {}) {
			if imgui.SmallButton("Reset##exposure") { postfx.pipeline_reset_effect(p, .Exposure) }
			if imgui.SliderFloat("Exposure##value", &p.exposure.exposure, 0.1, 10.0) {
				p.ubo_dirty = true
			}
			exposure_split := postfx.Post_Effect.Exposure in p.debug_split
			if imgui.Checkbox("A/B Split##exposure", &exposure_split) {
				postfx.pipeline_toggle_split(p, .Exposure)
			}
			if exposure_split {
				pos_pct := p.split_positions[.Exposure] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_exposure", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Exposure] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_tonemapping :: proc(p: ^postfx.Pipeline) {
	tonemap_on := postfx.Post_Effect.Tonemap in p.active_effects
	if imgui.Checkbox("Tonemapping", &tonemap_on) {
		postfx.pipeline_toggle(p, .Tonemap)
	}
	draw_split_indicator(p, .Tonemap)
	if tonemap_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##tonemap", {}) {
			if imgui.SmallButton("Reset##tonemap") { postfx.pipeline_reset_effect(p, .Tonemap) }
			if imgui.SliderFloat("Slope", &p.tonemapper.slope, 0.1, 3.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Toe", &p.tonemapper.toe, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Shoulder", &p.tonemapper.shoulder, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Black Clip", &p.tonemapper.black_clip, 0.0, 0.5) { p.ubo_dirty = true }
			if imgui.SliderFloat("White Clip", &p.tonemapper.white_clip, 0.0, 0.5) { p.ubo_dirty = true }
			tonemap_split := postfx.Post_Effect.Tonemap in p.debug_split
			if imgui.Checkbox("A/B Split##tonemap", &tonemap_split) {
				postfx.pipeline_toggle_split(p, .Tonemap)
			}
			if tonemap_split {
				pos_pct := p.split_positions[.Tonemap] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_tonemap", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Tonemap] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_vignette :: proc(p: ^postfx.Pipeline) {
	vignette_on := postfx.Post_Effect.Vignette in p.active_effects
	if imgui.Checkbox("Vignette", &vignette_on) {
		postfx.pipeline_toggle(p, .Vignette)
	}
	draw_split_indicator(p, .Vignette)
	if vignette_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##vignette", {}) {
			if imgui.SmallButton("Reset##vignette") { postfx.pipeline_reset_effect(p, .Vignette) }
			if imgui.SliderFloat("Intensity##vig", &p.vignette.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Smoothness##vig", &p.vignette.smoothness, 0.01, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Roundness##vig", &p.vignette.roundness, 0.0, 1.0) { p.ubo_dirty = true }
			vignette_split := postfx.Post_Effect.Vignette in p.debug_split
			if imgui.Checkbox("A/B Split##vignette", &vignette_split) {
				postfx.pipeline_toggle_split(p, .Vignette)
			}
			if vignette_split {
				pos_pct := p.split_positions[.Vignette] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_vignette", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Vignette] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_grain :: proc(p: ^postfx.Pipeline) {
	grain_on := postfx.Post_Effect.Grain in p.active_effects
	if imgui.Checkbox("Film Grain", &grain_on) {
		postfx.pipeline_toggle(p, .Grain)
	}
	draw_split_indicator(p, .Grain)
	if grain_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##grain", {}) {
			if imgui.SmallButton("Reset##grain") { postfx.pipeline_reset_effect(p, .Grain) }
			if imgui.SliderFloat("Intensity##grain", &p.grain.intensity, 0.0, 0.2) { p.ubo_dirty = true }
			if imgui.SliderFloat("Texel Size##grain", &p.grain.texel_size, 0.5, 4.0) { p.ubo_dirty = true }
			grain_split := postfx.Post_Effect.Grain in p.debug_split
			if imgui.Checkbox("A/B Split##grain", &grain_split) {
				postfx.pipeline_toggle_split(p, .Grain)
			}
			if grain_split {
				pos_pct := p.split_positions[.Grain] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_grain", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Grain] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_ca :: proc(p: ^postfx.Pipeline) {
	ca_on := postfx.Post_Effect.Chrom_Abbr in p.active_effects
	if imgui.Checkbox("Chromatic Aberration", &ca_on) {
		postfx.pipeline_toggle(p, .Chrom_Abbr)
	}
	draw_split_indicator(p, .Chrom_Abbr)
	if ca_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##ca", {}) {
			if imgui.SmallButton("Reset##ca") { postfx.pipeline_reset_effect(p, .Chrom_Abbr) }
			if imgui.SliderFloat("Strength##ca", &p.chrom_abbr.strength, 0.0, 0.05) { p.ubo_dirty = true }
			ca_split := postfx.Post_Effect.Chrom_Abbr in p.debug_split
			if imgui.Checkbox("A/B Split##ca", &ca_split) {
				postfx.pipeline_toggle_split(p, .Chrom_Abbr)
			}
			if ca_split {
				pos_pct := p.split_positions[.Chrom_Abbr] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_ca", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Chrom_Abbr] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_color_grading :: proc(p: ^postfx.Pipeline) {
	cg_on := postfx.Post_Effect.Color_Grading in p.active_effects
	if imgui.Checkbox("Color Grading", &cg_on) {
		postfx.pipeline_toggle(p, .Color_Grading)
	}
	draw_split_indicator(p, .Color_Grading)
	if cg_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##cg", {}) {
			if imgui.SmallButton("Reset##cg") { postfx.pipeline_reset_effect(p, .Color_Grading) }
			if imgui.SliderFloat("Saturation", &p.color_grading.saturation, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Contrast", &p.color_grading.contrast, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Gamma##cg", &p.color_grading.gamma, 0.1, 3.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Gain", &p.color_grading.gain, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Offset", &p.color_grading.offset, -0.5, 0.5) { p.ubo_dirty = true }
			cg_split := postfx.Post_Effect.Color_Grading in p.debug_split
			if imgui.Checkbox("A/B Split##cg", &cg_split) {
				postfx.pipeline_toggle_split(p, .Color_Grading)
			}
			if cg_split {
				pos_pct := p.split_positions[.Color_Grading] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_cg", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Color_Grading] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_bloom :: proc(p: ^postfx.Pipeline) {
	bloom_on := postfx.Post_Effect.Bloom in p.active_effects
	if imgui.Checkbox("Bloom", &bloom_on) {
		postfx.pipeline_toggle(p, .Bloom)
	}
	draw_split_indicator(p, .Bloom)
	if bloom_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##bloom", {}) {
			if imgui.SmallButton("Reset##bloom") { postfx.pipeline_reset_effect(p, .Bloom) }
			if imgui.SliderFloat("Intensity##bloom", &p.bloom.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Threshold##bloom", &p.bloom.threshold, 0.0, 5.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Soft Knee##bloom", &p.bloom.soft_threshold, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Radius##bloom", &p.bloom.radius, 0.1, 4.0) { p.ubo_dirty = true }
			bloom_debug := postfx.Post_Effect.Bloom_Debug in p.active_effects
			if imgui.Checkbox("Debug##bloom", &bloom_debug) {
				postfx.pipeline_toggle(p, .Bloom_Debug)
			}
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Shows bloom texture in isolation\nBright = pixels above threshold\nBlack = not contributing to glow")
			}
			bloom_split := postfx.Post_Effect.Bloom in p.debug_split
			if imgui.Checkbox("A/B Split##bloom", &bloom_split) {
				postfx.pipeline_toggle_split(p, .Bloom)
			}
			if bloom_split {
				pos_pct := p.split_positions[.Bloom] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_bloom", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Bloom] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_fxaa :: proc(p: ^postfx.Pipeline) {
	fxaa_on := postfx.Post_Effect.FXAA in p.active_effects
	if imgui.Checkbox("FXAA", &fxaa_on) {
		postfx.pipeline_toggle(p, .FXAA)
	}
	draw_split_indicator(p, .FXAA)
	if fxaa_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##fxaa", {}) {
			if imgui.SmallButton("Reset##fxaa") { postfx.pipeline_reset_effect(p, .FXAA) }
			if imgui.SliderFloat("Subpixel Quality", &p.fxaa.subpix, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Edge Threshold", &p.fxaa.edge_threshold, 0.01, 0.5) { p.ubo_dirty = true }
			if imgui.SliderFloat("Edge Threshold Min", &p.fxaa.edge_threshold_min, 0.01, 0.2) { p.ubo_dirty = true }
			fxaa_debug := postfx.Post_Effect.FXAA_Debug in p.active_effects
			if imgui.Checkbox("Debug##fxaa", &fxaa_debug) {
				postfx.pipeline_toggle(p, .FXAA_Debug)
			}
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Highlights pixels modified by FXAA:\nGreen = edge detected and smoothed\nOriginal color = no AA applied")
			}
			fxaa_split := postfx.Post_Effect.FXAA in p.debug_split
			if imgui.Checkbox("A/B Split##fxaa", &fxaa_split) {
				postfx.pipeline_toggle_split(p, .FXAA)
			}
			if fxaa_split {
				pos_pct := p.split_positions[.FXAA] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_fxaa", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.FXAA] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_auto_exposure :: proc(p: ^postfx.Pipeline) {
	ae_on := postfx.Post_Effect.Auto_Exposure in p.active_effects
	if imgui.Checkbox("Auto-Exposure", &ae_on) {
		postfx.pipeline_toggle(p, .Auto_Exposure)
	}
	draw_split_indicator(p, .Auto_Exposure)
	if ae_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##ae", {}) {
			if imgui.SmallButton("Reset##ae") { postfx.pipeline_reset_effect(p, .Auto_Exposure) }
			imgui.SliderFloat("Min Luminance", &p.auto_exposure_fx.params.min_luminance, 0.001, 1.0)
			imgui.SliderFloat("Max Luminance", &p.auto_exposure_fx.params.max_luminance, 100.0, 50000.0)
			imgui.SliderFloat("Speed Up", &p.auto_exposure_fx.params.speed_up, 0.1, 10.0)
			imgui.SliderFloat("Speed Down", &p.auto_exposure_fx.params.speed_down, 0.1, 10.0)
			imgui.SliderFloat("Key Value", &p.auto_exposure_fx.params.key_value, 0.01, 1.0)
			imgui.Spacing()
			imgui.Text("Current: %.3f", p.auto_exposure_fx.current_exposure)
			imgui.Text("Scene Lum: %.4f", p.auto_exposure_fx.current_scene_lum)
			imgui.Text("Target: %.3f", p.auto_exposure_fx.current_target)
			ae_split := postfx.Post_Effect.Auto_Exposure in p.debug_split
			if imgui.Checkbox("A/B Split##ae", &ae_split) {
				postfx.pipeline_toggle_split(p, .Auto_Exposure)
			}
			if ae_split {
				pos_pct := p.split_positions[.Auto_Exposure] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_ae", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Auto_Exposure] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_dof :: proc(p: ^postfx.Pipeline) {
	dof_on := postfx.Post_Effect.Dof in p.active_effects
	if imgui.Checkbox("Depth of Field", &dof_on) {
		postfx.pipeline_toggle(p, .Dof)
	}
	draw_split_indicator(p, .Dof)
	if dof_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##dof", {}) {
			if imgui.SmallButton("Reset##dof") { postfx.pipeline_reset_effect(p, .Dof) }
			if imgui.SliderFloat("Focal Distance##dof", &p.dof.focal_distance, 1.0, 100.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Focal Range##dof", &p.dof.focal_range, 0.5, 50.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Bokeh Scale##dof", &p.dof.bokeh_scale, 1.0, 50.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Anamorphic##dof", &p.dof.anamorphic_ratio, 0.5, 2.0) { p.ubo_dirty = true }

			dof_debug := postfx.Post_Effect.Dof_Debug in p.active_effects
			if imgui.Checkbox("Debug##dof", &dof_debug) {
				postfx.pipeline_toggle(p, .Dof_Debug)
			}
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Depth-of-field mask:\nWhite = in focus (sharp)\nGray = transition zone\nBlack = fully blurred (bokeh)")
			}
			dof_split := postfx.Post_Effect.Dof in p.debug_split
			if imgui.Checkbox("A/B Split##dof", &dof_split) {
				postfx.pipeline_toggle_split(p, .Dof)
			}
			if dof_split {
				pos_pct := p.split_positions[.Dof] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_dof", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Dof] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_motion_blur :: proc(p: ^postfx.Pipeline) {
	mb_on := postfx.Post_Effect.Motion_Blur in p.active_effects
	if imgui.Checkbox("Motion Blur", &mb_on) {
		postfx.pipeline_toggle(p, .Motion_Blur)
	}
	draw_split_indicator(p, .Motion_Blur)
	if mb_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##mblur", {}) {
			if imgui.SmallButton("Reset##mblur") { postfx.pipeline_reset_effect(p, .Motion_Blur) }
			if imgui.SliderFloat("Intensity##mblur", &p.motion_blur.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Max Velocity##mblur", &p.motion_blur.max_velocity, 0.005, 0.2) { p.ubo_dirty = true }
			samples_f := f32(p.motion_blur.samples)
			if imgui.SliderFloat("Samples##mblur", &samples_f, 2.0, 32.0) {
				p.motion_blur.samples = i32(samples_f)
				p.ubo_dirty = true
			}
			// Debug toggle
			mb_dbg := postfx.Post_Effect.Motion_Blur_Debug in p.active_effects
			if imgui.Checkbox("Debug View##mblur", &mb_dbg) {
				postfx.pipeline_toggle(p, .Motion_Blur_Debug)
			}
			if mb_dbg {
				mode_names := [4]cstring{"Velocity", "Tile-Max", "Neighbor-Max", "Speed Heatmap"}
				current_mode := p.motion_blur.debug_mode
				if imgui.BeginCombo("Debug Mode##mblur", mode_names[current_mode]) {
					for i in i32(0) ..< 4 {
						if imgui.Selectable(mode_names[i], i == current_mode) {
							p.motion_blur.debug_mode = i
							p.ubo_dirty = true
						}
					}
					imgui.EndCombo()
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_banding :: proc(p: ^postfx.Pipeline) {
	banding_on := postfx.Post_Effect.Banding in p.active_effects
	if imgui.Checkbox("Banding", &banding_on) {
		postfx.pipeline_toggle(p, .Banding)
	}
	draw_split_indicator(p, .Banding)
	if banding_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##banding", {}) {
			if imgui.SmallButton("Reset##banding") { postfx.pipeline_reset_effect(p, .Banding) }

			// Mode combo
			mode_names := [5]cstring{"Linear", "Dithered", "Perceptual", "Channel", "Luminance"}
			current_mode := i32(p.banding.mode)
			if imgui.BeginCombo("Mode##banding", mode_names[current_mode]) {
				for i in i32(0) ..< 5 {
					if imgui.Selectable(mode_names[i], i == current_mode) {
						p.banding.mode = postfx.Banding_Mode(i)
						p.ubo_dirty = true
					}
				}
				imgui.EndCombo()
			}

			// Levels slider (common to most modes)
			if imgui.SliderFloat("Levels##banding", &p.banding.levels, 2.0, 256.0) { p.ubo_dirty = true }

			// Mode-specific controls
			mode := p.banding.mode
			if mode == .Dithered {
				if imgui.SliderFloat("Dither Strength##banding", &p.banding.dither_strength, 0.0, 3.0) { p.ubo_dirty = true }
			}
			if mode == .Perceptual {
				if imgui.SliderFloat("Gamma##banding", &p.banding.perceptual_gamma, 0.5, 4.0) { p.ubo_dirty = true }
			}
			if mode == .Channel || mode == .Luminance {
				if imgui.SliderFloat("R Levels##banding", &p.banding.channel_levels[0], 2.0, 256.0) { p.ubo_dirty = true }
				if imgui.SliderFloat("G Levels##banding", &p.banding.channel_levels[1], 2.0, 256.0) { p.ubo_dirty = true }
				if imgui.SliderFloat("B Levels##banding", &p.banding.channel_levels[2], 2.0, 256.0) { p.ubo_dirty = true }
			}

			// A/B Split
			banding_split := postfx.Post_Effect.Banding in p.debug_split
			if imgui.Checkbox("A/B Split##banding", &banding_split) {
				postfx.pipeline_toggle_split(p, .Banding)
			}
			if banding_split {
				pos_pct := p.split_positions[.Banding] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_banding", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Banding] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_fog :: proc(p: ^postfx.Pipeline) {
	fog_on := postfx.Post_Effect.Fog in p.active_effects
	if imgui.Checkbox("Fog", &fog_on) {
		postfx.pipeline_toggle(p, .Fog)
	}
	draw_split_indicator(p, .Fog)
	if fog_on {
		imgui.SameLine()
		if imgui.TreeNodeEx("Settings##fog", {}) {
			if imgui.SmallButton("Reset##fog") { postfx.pipeline_reset_effect(p, .Fog) }
			if imgui.SliderFloat("Density##fog", &p.fog.density, 0.001, 1.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Start##fog", &p.fog.start, 0.0, 100.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Height Falloff##fog", &p.fog.height_falloff, 0.0, 0.5) { p.ubo_dirty = true }
			if imgui.SliderFloat("Max Opacity##fog", &p.fog.max_opacity, 0.0, 1.0) { p.ubo_dirty = true }
			if imgui.ColorEdit3("Color##fog", &p.fog.color) { p.ubo_dirty = true }
			fog_debug := postfx.Post_Effect.Fog_Debug in p.active_effects
			if imgui.Checkbox("Debug (greyscale mask)##fog", &fog_debug) {
				postfx.pipeline_toggle(p, .Fog_Debug)
			}
			imgui.SameLine()
			imgui.TextDisabled("(?)")
			if imgui.IsItemHovered() {
				imgui.SetTooltip("Fog density mask:\nWhite = fully fogged (max opacity)\nBlack = no fog\nGradient shows depth + height falloff")
			}
			fog_split := postfx.Post_Effect.Fog in p.debug_split
			if imgui.Checkbox("A/B Split##fog", &fog_split) {
				postfx.pipeline_toggle_split(p, .Fog)
			}
			if fog_split {
				pos_pct := p.split_positions[.Fog] * 100.0
				imgui.SetNextItemWidth(-1)
				if imgui.SliderFloat("##split_pos_fog", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
					p.split_positions[.Fog] = pos_pct / 100.0
					p.ubo_dirty = true
				}
			}
			imgui.TreePop()
		}
	}
}

@(private)
draw_postfx_lut3d :: proc(p: ^postfx.Pipeline) {
	// The toggle is disabled until a .cube file is loaded (sampling texture 0
	// returns black, causing unintended darkening at any intensity > 0).
	// The Settings tree is always open so the file picker remains accessible.
	@(static) lut_path_buf: [256]u8
	lut_on := postfx.Post_Effect.LUT3D in p.active_effects
	if lut_on && !p.lut3d_fx.loaded {
		postfx.pipeline_disable(p, .LUT3D)
		lut_on = false
	}
	if !p.lut3d_fx.loaded {
		imgui.BeginDisabled(true)
		imgui.Checkbox("LUT3D", &lut_on)
		imgui.EndDisabled()
	} else if imgui.Checkbox("LUT3D", &lut_on) {
		postfx.pipeline_toggle(p, .LUT3D)
	}
	draw_split_indicator(p, .LUT3D)
	imgui.SameLine()
	if imgui.TreeNodeEx("Settings##lut3d", {}) {
		if p.lut3d_fx.loaded {
			if imgui.SmallButton("Reset##lut3d") { postfx.pipeline_reset_effect(p, .LUT3D) }
			if imgui.SliderFloat("Intensity##lut3d", &p.lut3d.intensity, 0.0, 1.0) { p.ubo_dirty = true }
			imgui.TextDisabled("Loaded: %s (%d^3)", p.lut3d_fx.path, p.lut3d_fx.size)
			if imgui.SmallButton("Unload##lut3d") {
				postfx.lut3d_destroy(&p.lut3d_fx)
				postfx.pipeline_disable(p, .LUT3D)
			}
		} else {
			imgui.TextColored(imgui.Vec4{1.0, 0.6, 0.3, 1.0}, "No LUT loaded — enter path to a .cube file:")
			imgui.SetNextItemWidth(300)
			imgui.InputText("##lut3d_path", cast(cstring)&lut_path_buf[0], len(lut_path_buf))
			imgui.SameLine()
			if imgui.SmallButton("Load##lut3d") {
				path := string(cstring(&lut_path_buf[0]))
				if path != "" && postfx.pipeline_load_lut(p, path) {
					postfx.pipeline_enable(p, .LUT3D)
				}
			}
		}
		lut_debug := postfx.Post_Effect.LUT3D_Debug in p.active_effects
		if imgui.Checkbox("Debug delta##lut3d", &lut_debug) {
			postfx.pipeline_toggle(p, .LUT3D_Debug)
		}
		imgui.SameLine()
		imgui.TextDisabled("(?)")
		if imgui.IsItemHovered() {
			imgui.SetTooltip("Color difference |LUT(color) - original|:\nBright = large color shift from LUT\nBlack = no change")
		}
		lut_split := postfx.Post_Effect.LUT3D in p.debug_split
		if imgui.Checkbox("A/B Split##lut3d", &lut_split) {
			postfx.pipeline_toggle_split(p, .LUT3D)
		}
		if lut_split {
			pos_pct := p.split_positions[.LUT3D] * 100.0
			imgui.SetNextItemWidth(-1)
			if imgui.SliderFloat("##split_pos_lut3d", &pos_pct, 0.0, 100.0, "← %.0f%% →") {
				p.split_positions[.LUT3D] = pos_pct / 100.0
				p.ubo_dirty = true
			}
		}
		imgui.TreePop()
	}
}

@(private)
draw_postfx_luminance_stops :: proc(p: ^postfx.Pipeline) {
	imgui.Separator()
	lum_on := postfx.Post_Effect.Luminance_Debug in p.active_effects
	if imgui.Checkbox("Luminance Stops", &lum_on) {
		postfx.pipeline_toggle(p, .Luminance_Debug)
	}
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Filament-style luminance visualization.\nColor-codes final pixel luminance by stops:\n  Cyan = middle gray (18%)\n  Blue = darker stops\n  Green/Yellow/Red = brighter stops")
	}
}

@(private)
draw_postfx_section :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Post-Processing")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		imgui.Spacing()
		return
	}

	// Master toggle
	imgui.Checkbox("Enable Post-FX", &p.enabled)
	if !p.enabled {
		imgui.Spacing()
		return
	}

	imgui.Spacing()

	// --- Preset selector ---
	@(static) current_preset: i32 = 0
	preset_names := postfx.PRESET_NAMES
	preset_wip := postfx.PRESET_WIP
	preview := fmt.ctprintf("%s", preset_names[postfx.Preset_Id(current_preset)])
	if imgui.BeginCombo("Preset", preview) {
		for id in postfx.Preset_Id {
			is_selected := i32(id) == current_preset
			wip := preset_wip[id]
			label: cstring
			if wip {
				label = fmt.ctprintf("%s (WIP)", preset_names[id])
			} else {
				label = fmt.ctprintf("%s", preset_names[id])
			}
			if wip { imgui.BeginDisabled() }
			if imgui.Selectable(label, is_selected) {
				current_preset = i32(id)
				postfx.pipeline_apply_preset(p, id)
			}
			if wip { imgui.EndDisabled() }
		}
		imgui.EndCombo()
	}
	imgui.Spacing()

	// --- Save / Load user presets ---
	draw_postfx_save_load(p)

	imgui.Separator()
	imgui.Spacing()

	// Call our individual decomposed helpers
	draw_postfx_exposure(p)
	draw_postfx_tonemapping(p)
	draw_postfx_vignette(p)
	draw_postfx_grain(p)
	draw_postfx_ca(p)
	draw_postfx_color_grading(p)
	draw_postfx_bloom(p)
	draw_postfx_fxaa(p)
	draw_postfx_auto_exposure(p)
	draw_postfx_dof(p)
	draw_postfx_motion_blur(p)
	draw_postfx_banding(p)
	draw_postfx_fog(p)
	draw_postfx_lut3d(p)
	draw_postfx_luminance_stops(p)

	imgui.Spacing()
}

// GPU Timings tab — separate from Post-FX controls.
@(private)
draw_gpu_timings_section :: proc(state: Scene_State) {
	// Performance mode toggle (at the top of Profiling tab)
	draw_perf_mode_widget(state)
	imgui.Spacing()

	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "GPU Profiling")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		return
	}

	imgui.Checkbox("Enable Profiling", &p.timers.enabled)
	if !p.timers.enabled { return }

	total_avg, total_min, total_max := postfx.gpu_timer_get_total_metrics(&p.timers)

	imgui.Spacing()
	imgui.Separator()

	// Per-pass metrics table
	table_flags := imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit
	if imgui.BeginTable("##gpu_timings", 5, table_flags) {
		imgui.TableSetupColumn("Pass", {.WidthFixed}, 90)
		imgui.TableSetupColumn("Avg", {.WidthFixed}, 70)
		imgui.TableSetupColumn("Min", {.WidthFixed}, 70)
		imgui.TableSetupColumn("Max", {.WidthFixed}, 70)
		imgui.TableSetupColumn("%", {.WidthFixed}, 45)
		imgui.TableHeadersRow()

		pass_names := postfx.TIMER_PASS_NAMES
		for pass in postfx.Timer_Pass {
			avg, min_v, max_v := postfx.gpu_timer_get_metrics(&p.timers, pass)
			pct := postfx.gpu_timer_get_pct(&p.timers, pass)

			imgui.TableNextRow()
			imgui.TableNextColumn()
			imgui.Text("%s", pass_names[pass])
			imgui.TableNextColumn()
			imgui.Text("%.3f", avg)
			imgui.TableNextColumn()
			imgui.TextDisabled("%.3f", min_v)
			imgui.TableNextColumn()
			imgui.TextDisabled("%.3f", max_v)
			imgui.TableNextColumn()
			imgui.Text("%.0f%%", pct)
		}

		// Total row
		imgui.TableNextRow()
		imgui.TableNextColumn()
		imgui.TextColored(imgui.Vec4{0.8, 0.9, 1.0, 1.0}, "Total")
		imgui.TableNextColumn()
		imgui.TextColored(imgui.Vec4{0.8, 0.9, 1.0, 1.0}, "%.3f", total_avg)
		imgui.TableNextColumn()
		imgui.TextDisabled("%.3f", total_min)
		imgui.TableNextColumn()
		imgui.TextDisabled("%.3f", total_max)
		imgui.TableNextColumn()
		imgui.Text("")

		imgui.EndTable()
	}

	imgui.Spacing()
	// Frame budget: smoothed % of actual frame time consumed by PostFX
	frame_ms := state.frame_time_ms
	budget_pct: f32 = 0
	if frame_ms > 0 {
		budget_pct = (total_avg / frame_ms) * 100.0
	}
	budget_color: imgui.Vec4
	if budget_pct < 25 {
		budget_color = {0.3, 1.0, 0.3, 1.0} // green
	} else if budget_pct < 50 {
		budget_color = {1.0, 0.9, 0.3, 1.0} // yellow
	} else {
		budget_color = {1.0, 0.3, 0.3, 1.0} // red
	}
	imgui.TextColored(budget_color, "PostFX: %.1f%% of frame (%.2f ms)", budget_pct, frame_ms)
}

// Shader Cache tab — separate from Post-FX controls.
@(private)
draw_shader_cache_section :: proc(state: Scene_State) {
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Shader Optimization")
	imgui.Separator()

	p := state.postfx
	if p == nil {
		imgui.TextColored(imgui.Vec4{1.0, 0.5, 0.5, 1.0}, "Pipeline not initialized")
		return
	}

	imgui.Checkbox("Enable Variants", &p.shader_cache.enabled)
	if !p.shader_cache.enabled {
		imgui.TextDisabled("Disabled — using dynamic uber-shader with runtime branching")
		return
	}

	imgui.Spacing()

	// --- Current state ---
	imgui.Text("Active Effects:")
	imgui.Indent()
	// Only show effects that have static shader defines
	SHADER_EFFECTS :: [?]postfx.Post_Effect{
		.Vignette, .Grain, .Exposure, .Chrom_Abbr,
		.Bloom, .Color_Grading, .FXAA, .Tonemap,
	}
	EFFECT_NAMES :: [postfx.Post_Effect]string{
		.Vignette      = "Vignette",
		.Grain         = "Film Grain",
		.Exposure      = "Exposure",
		.Chrom_Abbr    = "Chrom. Abbr",
		.Bloom         = "Bloom",
		.Color_Grading = "Color Grading",
		.FXAA          = "FXAA",
		.Tonemap       = "Tonemap",
		.Dof           = "DoF",
		.Dof_Debug     = "DoF Debug",
		.Auto_Exposure = "Auto-Exposure",
		.Exposure_Debug = "Exposure Debug",
		.Motion_Blur   = "Motion Blur",
		.Motion_Blur_Debug = "MB Debug",
		.Banding       = "Banding",
		.Fog           = "Fog",
		.LUT3D         = "LUT3D",
		.FXAA_Debug    = "FXAA Debug",
		.Stencil_Debug = "Stencil Debug",
		.Bloom_Debug   = "Bloom Debug",
		.Fog_Debug     = "Fog Debug",
		.LUT3D_Debug   = "LUT3D Debug",
		.Vector_Field_Debug = "Vector Field",
		.Luminance_Debug = "Luminance Stops",
	}
	effect_names := EFFECT_NAMES
	active_count := 0
	for effect in SHADER_EFFECTS {
		if effect in p.active_effects {
			imgui.BulletText("%s", effect_names[effect])
			active_count += 1
		}
	}
	if active_count == 0 {
		imgui.TextDisabled("(none)")
	}
	imgui.Unindent()

	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	// --- Cache hit/miss status ---
	cached_program := postfx.shader_cache_find(&p.shader_cache, p.active_effects)
	if cached_program != 0 {
		imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "Status: CACHED (program %d)", cached_program)
	} else {
		imgui.TextColored(imgui.Vec4{1.0, 0.7, 0.3, 1.0}, "Status: MISS — using dynamic branching")
	}

	imgui.Spacing()

	// --- Actions ---
	can_compile := cached_program == 0
	if !can_compile { imgui.BeginDisabled() }
	if imgui.Button("Compile Current") {
		postfx.pipeline_compile_variant(p)
	}
	if !can_compile { imgui.EndDisabled() }
	if cached_program != 0 {
		imgui.SameLine()
		imgui.TextDisabled("(already cached)")
	} else if p.shader_cache.count >= i32(postfx.MAX_CACHED_VARIANTS) {
		imgui.SameLine()
		imgui.TextDisabled("(LRU eviction)")
	}

	imgui.SameLine()
	if imgui.Button("Clear All") {
		postfx.shader_cache_destroy(&p.shader_cache)
	}

	imgui.Spacing()
	imgui.Separator()
	imgui.Spacing()

	// --- Cached variants list ---
	imgui.Text("Cached Variants: %d / %d", p.shader_cache.count, postfx.MAX_CACHED_VARIANTS)
	if p.shader_cache.count > 0 {
		table_flags := imgui.TableFlags_BordersInnerH | imgui.TableFlags_SizingFixedFit | imgui.TableFlags_RowBg
		if imgui.BeginTable("##shader_variants", 3, table_flags) {
			imgui.TableSetupColumn("#", {.WidthFixed}, 25)
			imgui.TableSetupColumn("Program", {.WidthFixed}, 60)
			imgui.TableSetupColumn("Effects", {.WidthStretch})
			imgui.TableHeadersRow()

			for i in 0 ..< p.shader_cache.count {
				variant := &p.shader_cache.variants[i]
				imgui.TableNextRow()
				imgui.TableNextColumn()
				imgui.Text("%d", i + 1)
				imgui.TableNextColumn()
				imgui.Text("%d", variant.program)
				imgui.TableNextColumn()

				// Build effect list string for this variant
				first := true
				for effect in SHADER_EFFECTS {
					if effect in variant.effects {
						if !first { imgui.SameLine(0, 0); imgui.Text(", ") ; imgui.SameLine(0, 0) }
						is_current := (variant.effects == p.active_effects)
						if is_current {
							imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "%s", effect_names[effect])
						} else {
							imgui.Text("%s", effect_names[effect])
						}
						first = false
					}
				}
				if first {
					imgui.TextDisabled("(no effects)")
				}
			}
			imgui.EndTable()
		}
	}
}

// PostFX filtered search entries — called from draw_filtered_view.
@(private)
draw_postfx_filtered :: proc(state: Scene_State, filter: cstring) -> int {
	p := state.postfx
	if p == nil { return 0 }

	match_count := 0

	if fuzzy_match(filter, "Enable Post-FX", "postfx pipeline master toggle") {
		imgui.Checkbox("Enable Post-FX", &p.enabled)
		match_count += 1
	}

	if fuzzy_match(filter, "Exposure", "postfx tone mapping hdr brightness manual") {
		exposure_on := postfx.Post_Effect.Exposure in p.active_effects
		if imgui.Checkbox("Exposure##filt", &exposure_on) {
			postfx.pipeline_toggle(p, .Exposure)
		}
		if imgui.SliderFloat("Exposure##filt_val", &p.exposure.exposure, 0.1, 10.0) {
			p.ubo_dirty = true
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Tonemapping", "postfx tonemap aces filmic curve hdr ldr") {
		tonemap_on := postfx.Post_Effect.Tonemap in p.active_effects
		if imgui.Checkbox("Tonemapping##filt", &tonemap_on) {
			postfx.pipeline_toggle(p, .Tonemap)
		}
		if imgui.SliderFloat("Slope##filt", &p.tonemapper.slope, 0.1, 3.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Toe##filt", &p.tonemapper.toe, 0.0, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Shoulder##filt", &p.tonemapper.shoulder, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Vignette", "postfx border darken edge shadow") {
		vignette_on := postfx.Post_Effect.Vignette in p.active_effects
		if imgui.Checkbox("Vignette##filt", &vignette_on) {
			postfx.pipeline_toggle(p, .Vignette)
		}
		if imgui.SliderFloat("Intensity##vig_filt", &p.vignette.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Smoothness##vig_filt", &p.vignette.smoothness, 0.01, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Film Grain", "postfx noise cinematic film grain texture") {
		grain_on := postfx.Post_Effect.Grain in p.active_effects
		if imgui.Checkbox("Film Grain##filt", &grain_on) {
			postfx.pipeline_toggle(p, .Grain)
		}
		if imgui.SliderFloat("Intensity##grain_filt", &p.grain.intensity, 0.0, 0.2) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Chromatic Aberration", "postfx color fringe lens dispersion ca") {
		ca_on := postfx.Post_Effect.Chrom_Abbr in p.active_effects
		if imgui.Checkbox("Chromatic Aberration##filt", &ca_on) {
			postfx.pipeline_toggle(p, .Chrom_Abbr)
		}
		if imgui.SliderFloat("Strength##ca_filt", &p.chrom_abbr.strength, 0.0, 0.05) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Color Grading", "postfx saturation contrast gamma gain offset lift color correction") {
		cg_on := postfx.Post_Effect.Color_Grading in p.active_effects
		if imgui.Checkbox("Color Grading##filt", &cg_on) {
			postfx.pipeline_toggle(p, .Color_Grading)
		}
		if imgui.SliderFloat("Saturation##filt", &p.color_grading.saturation, 0.0, 2.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Contrast##filt", &p.color_grading.contrast, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Bloom", "postfx glow effect bright threshold hdr") {
		bloom_on := postfx.Post_Effect.Bloom in p.active_effects
		if imgui.Checkbox("Bloom##filt", &bloom_on) {
			postfx.pipeline_toggle(p, .Bloom)
		}
		if imgui.SliderFloat("Intensity##bloom_filt", &p.bloom.intensity, 0.0, 2.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "FXAA", "postfx anti-aliasing antialiasing edge smoothing") {
		fxaa_on := postfx.Post_Effect.FXAA in p.active_effects
		if imgui.Checkbox("FXAA##filt", &fxaa_on) {
			postfx.pipeline_toggle(p, .FXAA)
		}
		if imgui.SliderFloat("Subpixel##fxaa_filt", &p.fxaa.subpix, 0.0, 1.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Motion Blur", "postfx motion blur velocity camera movement") {
		mb_on := postfx.Post_Effect.Motion_Blur in p.active_effects
		if imgui.Checkbox("Motion Blur##filt", &mb_on) {
			postfx.pipeline_toggle(p, .Motion_Blur)
		}
		if mb_on {
			if imgui.SliderFloat("Intensity##mblur_filt", &p.motion_blur.intensity, 0.0, 2.0) { p.ubo_dirty = true }
			if imgui.SliderFloat("Max Velocity##mblur_filt", &p.motion_blur.max_velocity, 0.005, 0.2) { p.ubo_dirty = true }
			samples_f := f32(p.motion_blur.samples)
			if imgui.SliderFloat("Samples##mblur_filt", &samples_f, 2.0, 32.0) {
				p.motion_blur.samples = i32(samples_f)
				p.ubo_dirty = true
			}
			mb_dbg := postfx.Post_Effect.Motion_Blur_Debug in p.active_effects
			if imgui.Checkbox("Debug View##mblur_filt", &mb_dbg) {
				postfx.pipeline_toggle(p, .Motion_Blur_Debug)
			}
		}
		match_count += 1
	}

	if fuzzy_match(filter, "Banding", "postfx banding posterize quantize dither retro") {
		banding_on := postfx.Post_Effect.Banding in p.active_effects
		if imgui.Checkbox("Banding##filt", &banding_on) {
			postfx.pipeline_toggle(p, .Banding)
		}
		if imgui.SliderFloat("Levels##banding_filt", &p.banding.levels, 2.0, 256.0) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "Fog", "postfx fog haze atmosphere scattering density height") {
		fog_on := postfx.Post_Effect.Fog in p.active_effects
		if imgui.Checkbox("Fog##filt", &fog_on) {
			postfx.pipeline_toggle(p, .Fog)
		}
		if imgui.SliderFloat("Density##fog_filt", &p.fog.density, 0.001, 1.0) { p.ubo_dirty = true }
		if imgui.SliderFloat("Start##fog_filt", &p.fog.start, 0.0, 100.0) { p.ubo_dirty = true }
		if imgui.ColorEdit3("Color##fog_filt", &p.fog.color) { p.ubo_dirty = true }
		match_count += 1
	}

	if fuzzy_match(filter, "LUT3D", "postfx lut lookup table color grading 3d film emulation gamut") {
		lut_on := postfx.Post_Effect.LUT3D in p.active_effects
		if imgui.Checkbox("LUT3D##filt", &lut_on) {
			postfx.pipeline_toggle(p, .LUT3D)
		}
		if imgui.SliderFloat("Intensity##lut3d_filt", &p.lut3d.intensity, 0.0, 1.0) { p.ubo_dirty = true }
		match_count += 1
	}

	return match_count
}

// --- Save / Load user presets UI ---
@(private)
draw_postfx_save_load :: proc(p: ^postfx.Pipeline) {
	@(static) save_name_buf: [128]u8
	@(static) load_selected: i32 = -1
	@(static) status_msg: cstring
	@(static) status_timer: f32

	if imgui.TreeNode("Save / Load") {
		imgui.Spacing()

		// --- Save section ---
		imgui.Text("Save current settings:")
		imgui.SetNextItemWidth(200)
		imgui.InputText("##preset_name", cast(cstring)&save_name_buf[0], len(save_name_buf))

		imgui.SameLine()
		name_cstr := cstring(&save_name_buf[0])
		name_str := string(name_cstr)
		save_disabled := len(name_str) == 0
		if save_disabled { imgui.BeginDisabled() }
		if imgui.Button("Save") {
			path := postfx.settings_build_path(postfx.POSTFX_PRESETS_DIR, name_str)
			if postfx.settings_export(p, path, name_str) {
				status_msg = "Saved!"
				status_timer = 2.0
			} else {
				status_msg = "Save failed"
				status_timer = 3.0
			}
		}
		if save_disabled { imgui.EndDisabled() }

		imgui.Spacing()

		// --- Load section ---
		imgui.Text("Load from file:")
		files := postfx.settings_list_files(postfx.POSTFX_PRESETS_DIR, context.temp_allocator)

		if len(files) == 0 {
			imgui.TextDisabled("No saved presets found")
		} else {
			preview: cstring = "Select..."
			if load_selected >= 0 && load_selected < i32(len(files)) {
				preview = fmt.ctprintf("%s", files[load_selected])
			}
			imgui.SetNextItemWidth(200)
			if imgui.BeginCombo("##load_preset", preview) {
				for file, idx in files {
					is_sel := i32(idx) == load_selected
					if imgui.Selectable(fmt.ctprintf("%s", file), is_sel) {
						load_selected = i32(idx)
					}
				}
				imgui.EndCombo()
			}

			imgui.SameLine()
			load_disabled := load_selected < 0 || load_selected >= i32(len(files))
			if load_disabled { imgui.BeginDisabled() }
			if imgui.Button("Load") {
				path := postfx.settings_build_path(
					postfx.POSTFX_PRESETS_DIR, files[load_selected],
				)
				if postfx.settings_import(p, path) {
					status_msg = "Loaded!"
					status_timer = 2.0
				} else {
					status_msg = "Load failed"
					status_timer = 3.0
				}
			}
			imgui.SameLine()
			if imgui.Button("Delete") {
				imgui.OpenPopup("Confirm Delete")
			}
			if load_disabled { imgui.EndDisabled() }

			// Delete confirmation popup
			if imgui.BeginPopupModal("Confirm Delete", nil, {.AlwaysAutoResize}) {
				imgui.Text("Delete preset?")
				if load_selected >= 0 && load_selected < i32(len(files)) {
					imgui.TextColored(
						imgui.Vec4{1.0, 0.8, 0.3, 1.0},
						fmt.ctprintf("%s", files[load_selected]),
					)
				}
				imgui.Spacing()
				if imgui.Button("Yes, delete") {
					path := postfx.settings_build_path(
						postfx.POSTFX_PRESETS_DIR, files[load_selected],
					)
					if postfx.settings_delete(path) {
						status_msg = "Deleted!"
						status_timer = 2.0
						load_selected = -1
					} else {
						status_msg = "Delete failed"
						status_timer = 3.0
					}
					imgui.CloseCurrentPopup()
				}
				imgui.SameLine()
				if imgui.Button("Cancel") {
					imgui.CloseCurrentPopup()
				}
				imgui.EndPopup()
			}
		}

		// --- Status feedback ---
		if status_msg != nil && status_timer > 0 {
			imgui.SameLine()
			imgui.TextColored(imgui.Vec4{0.4, 1.0, 0.4, 1.0}, status_msg)
			status_timer -= imgui.GetIO().DeltaTime
			if status_timer <= 0 {
				status_msg = nil
			}
		}

		imgui.Spacing()
		imgui.TreePop()
	}
}

// ─── Dedicated Motion Blur Debug Tab ───────────────────────────────────────────

@(private)
draw_tab_motion_blur :: proc(state: Scene_State) {
	p := state.postfx
	if p == nil {
		imgui.TextDisabled("Pipeline not initialized")
		return
	}

	// --- Enable / Disable ---
	imgui.TextColored(imgui.Vec4{1.0, 0.8, 0.3, 1.0}, "Motion Blur")
	imgui.Separator()

	mb_on := postfx.Post_Effect.Motion_Blur in p.active_effects
	if imgui.Checkbox("Enable Motion Blur", &mb_on) {
		postfx.pipeline_toggle(p, .Motion_Blur)
	}

	imgui.Spacing()

	// --- Parameters ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Parameters")
	imgui.Separator()

	if imgui.SmallButton("Reset to Defaults") { postfx.pipeline_reset_effect(p, .Motion_Blur) }

	if imgui.SliderFloat("Intensity", &p.motion_blur.intensity, 0.0, 3.0) { p.ubo_dirty = true }
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Blur strength multiplier on velocity vectors\n1.0 = physically correct\n>1.0 = exaggerated (artistic)\n<1.0 = dampened motion")
	}
	if imgui.SliderFloat("Max Velocity (UV)", &p.motion_blur.max_velocity, 0.001, 0.3) { p.ubo_dirty = true }
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Clamp threshold for velocity vectors\nUnit: fraction of screen (0.05 = 5%% of viewport)\nHigher = longer streaks, Lower = caps blur length")
	}
	samples_f := f32(p.motion_blur.samples)
	if imgui.SliderFloat("Samples", &samples_f, 2.0, 32.0) {
		p.motion_blur.samples = i32(samples_f)
		p.ubo_dirty = true
	}
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip("Blur taps along velocity direction\n8 = good balance\n16+ = high quality for fast motion\nMore = smoother, heavier GPU cost")
	}

	imgui.Spacing()

	// --- Synthetic Velocity Injection ---
	imgui.TextColored(imgui.Vec4{1.0, 0.6, 0.2, 1.0}, "Synthetic Velocity (Debug)")
	imgui.Separator()
	imgui.TextWrapped("Inject constant velocity without moving the camera. Tests the full MB pipeline end-to-end.")

	imgui.Checkbox("Enable Injection", &p.motion_blur.inject_enabled)

	if p.motion_blur.inject_enabled {
		imgui.SliderFloat("Direction (deg)", &p.motion_blur.inject_direction, 0.0, 360.0)
		imgui.SliderFloat("Magnitude (UV)", &p.motion_blur.inject_magnitude, 0.0, 0.15)

		// Quick presets
		if imgui.SmallButton("Right") { p.motion_blur.inject_direction = 0.0; p.motion_blur.inject_magnitude = 0.03 }
		imgui.SameLine()
		if imgui.SmallButton("Up") { p.motion_blur.inject_direction = 90.0; p.motion_blur.inject_magnitude = 0.03 }
		imgui.SameLine()
		if imgui.SmallButton("Left") { p.motion_blur.inject_direction = 180.0; p.motion_blur.inject_magnitude = 0.03 }
		imgui.SameLine()
		if imgui.SmallButton("Down") { p.motion_blur.inject_direction = 270.0; p.motion_blur.inject_magnitude = 0.03 }

		if imgui.SmallButton("Slow") { p.motion_blur.inject_magnitude = 0.01 }
		imgui.SameLine()
		if imgui.SmallButton("Medium") { p.motion_blur.inject_magnitude = 0.04 }
		imgui.SameLine()
		if imgui.SmallButton("Fast") { p.motion_blur.inject_magnitude = 0.10 }
		imgui.SameLine()
		if imgui.SmallButton("Max") { p.motion_blur.inject_magnitude = 0.15 }

		// Visual indicator of current velocity vector
		angle_rad := p.motion_blur.inject_direction * math.RAD_PER_DEG
		imgui.Text("Velocity: (%.4f, %.4f) UV", p.motion_blur.inject_magnitude * math.cos(angle_rad), p.motion_blur.inject_magnitude * math.sin(angle_rad))
	}

	imgui.Spacing()

	// --- Debug Visualization ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Debug Visualization")
	imgui.Separator()

	// Exclusive debug mode selector
	mb_dbg := postfx.Post_Effect.Motion_Blur_Debug in p.active_effects
	vf_dbg := postfx.Post_Effect.Vector_Field_Debug in p.active_effects
	current_dbg: i32 = 0  // Off
	if mb_dbg { current_dbg = 1 + p.motion_blur.debug_mode }
	if vf_dbg { current_dbg = 5 }
	debug_modes := [6]cstring{
		"Off",
		"Velocity (RG)",
		"Tile-Max (Heatmap)",
		"Neighbor-Max (Heatmap)",
		"Speed (Heatmap)",
		"Vector Field",
	}
	clamped_dbg := clamp(current_dbg, 0, 5)
	if imgui.BeginCombo("Debug View", debug_modes[clamped_dbg]) {
		for i in i32(0) ..< 6 {
			if imgui.Selectable(debug_modes[i], i == clamped_dbg) {
				// Disable both first, then enable selected
				if .Motion_Blur_Debug in p.active_effects {
					postfx.pipeline_toggle(p, .Motion_Blur_Debug)
				}
				if .Vector_Field_Debug in p.active_effects {
					postfx.pipeline_toggle(p, .Vector_Field_Debug)
				}
				if i >= 1 && i <= 4 {
					postfx.pipeline_toggle(p, .Motion_Blur_Debug)
					p.motion_blur.debug_mode = i - 1
					p.ubo_dirty = true
				}
				if i == 5 { postfx.pipeline_toggle(p, .Vector_Field_Debug) }
			}
			// Per-mode tooltip on hover
			if imgui.IsItemHovered() {
				switch i {
				case 0: // Off
				case 1:
					imgui.SetTooltip("Raw velocity buffer: abs(velocity) x 20\nRed = horizontal motion\nGreen = vertical motion\nBlack = no motion")
				case 2:
					imgui.SetTooltip("Per-tile (16x16 px) maximum velocity magnitude\nBlue->Red heatmap (0 -> max_velocity)\nShows coarse motion map before dilation")
				case 3:
					imgui.SetTooltip("3x3 dilated tile-max velocity\nBlue->Red heatmap\nEnsures blur extends beyond moving object edges")
				case 4:
					imgui.SetTooltip("Per-pixel velocity magnitude heatmap\nBlue->Red (0 -> max_velocity)\nFull resolution — shows exact motion boundaries")
				case 5:
					imgui.SetTooltip("SDF arrow grid (48px spacing)\nArrow direction = motion direction\nArrow color (HSV) = direction angle\nArrow length = velocity magnitude")
				}
			}
		}
		imgui.EndCombo()
	}

	imgui.Spacing()

	// --- Resource Info ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Resources")
	imgui.Separator()

	fx := &p.motion_blur_fx
	imgui.Text("Framebuffer: %dx%d", p.width, p.height)
	imgui.Text("Velocity Tex: %d (RG16F, %dx%d)", p.velocity_tex, p.width, p.height)
	imgui.Text("Tile-Max Tex: %d (RG16F, %dx%d)", fx.tile_max_tex, fx.tile_width, fx.tile_height)
	imgui.Text("Neighbor-Max Tex: %d (RG16F, %dx%d)", fx.neighbor_max_tex, fx.tile_width, fx.tile_height)
	imgui.Text("Tile-Max Program: %d", fx.tile_max_program)
	imgui.Text("Neighbor-Max Program: %d", fx.neighbor_max_program)

	imgui.Spacing()

	// --- GPU Timing ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "GPU Timing")
	imgui.Separator()

	avg, min_v, max_v := postfx.gpu_timer_get_metrics(&p.timers, .Motion_Blur)
	imgui.Text("Avg: %.3f ms | Min: %.3f ms | Max: %.3f ms", avg, min_v, max_v)

	imgui.Spacing()

	// --- Active Effects Bitfield ---
	imgui.TextColored(imgui.Vec4{0.6, 0.8, 1.0, 1.0}, "Effect Bits")
	imgui.Separator()
	imgui.Text("Motion_Blur (bit 10): %s", mb_on ? "ON" : "OFF")
	imgui.Text("Motion_Blur_Debug (bit 11): %s", mb_dbg ? "ON" : "OFF")
	imgui.Text("Vector_Field_Debug (bit 22): %s", vf_dbg ? "ON" : "OFF")
	imgui.Text("Synthetic Inject: %s", p.motion_blur.inject_enabled ? "ACTIVE" : "off")
}

// ─── Performance Mode Widget ───────────────────────────────────────────────────

draw_perf_mode_widget :: proc(state: Scene_State) {
	pm := state.perf
	if pm == nil {
		imgui.TextColored(imgui.Vec4{0.5, 0.5, 0.5, 1.0}, "Performance Mode: N/A")
		return
	}

	imgui.TextColored(imgui.Vec4{1.0, 0.8, 0.3, 1.0}, "Performance Mode")
	imgui.SameLine()
	imgui.TextDisabled("(?)")
	if imgui.IsItemHovered() {
		imgui.SetTooltip(
			"Maximizes system resources for this application.\n\n" +
			"Backends (tried in order):\n" +
			"  1. GameMode — CPU governor 'performance', GPU boost\n" +
			"  2. SCHED_FIFO — Real-time scheduling (needs root)\n" +
			"  3. Nice -10 — Higher process priority\n\n" +
			"Also enables:\n" +
			"  • mlockall — Locks memory, prevents stutter\n" +
			"  • MESA_NO_ERROR — Skips GL validation (restart needed)\n" +
			"  • mesa_glthread — Multi-threaded GL dispatch (restart needed)",
		)
	}
	imgui.Separator()

	active := pm.active
	if imgui.Checkbox("Enable##perf_mode", &active) {
		perf_mode.toggle(pm)
	}
	imgui.SameLine()
	label := perf_mode.backend_label(pm)
	if pm.active {
		imgui.TextColored(imgui.Vec4{0.3, 1.0, 0.3, 1.0}, "[%s]", fmt.ctprintf("%s", label))
	} else {
		imgui.TextDisabled("[%s]", fmt.ctprintf("%s", label))
	}
	if pm.mesa_needs_restart {
		imgui.TextColored(imgui.Vec4{1.0, 0.6, 0.2, 1.0}, "Mesa optimizations apply on next restart")
	}
}
