#version 450 core

layout(local_size_x = 16, local_size_y = 4, local_size_z = 1) in;

layout(binding = 0) uniform sampler2D envMap;
layout(binding = 1, rgba16f) restrict writeonly uniform image2D irradianceMap;

layout(location = 0) uniform float clamp_threshold;
layout(location = 1) uniform int u_offset_y;
layout(location = 2) uniform int u_max_y;

const float PI = 3.14159265359;
const float TWO_PI = 2.0 * PI;

// Helpers pour le mapping Equirectangulaire
// Helpers pour le mapping Equirectangulaire
vec2 dirToUV(vec3 v)
{
	float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
	vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
	uv *= vec2(1.0 / TWO_PI, 1.0 / PI);
	uv += 0.5;
	return uv;
}

vec3 uvToDir(vec2 uv)
{
	float phi = (uv.x - 0.5) * TWO_PI;
	float theta = (uv.y - 0.5) * PI;
	return vec3(cos(theta) * cos(phi), sin(theta), cos(theta) * sin(phi));
}

void OrthonormalBasis(vec3 n, out vec3 t, out vec3 b)
{
	vec3 up = abs(n.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
	t = normalize(cross(up, n));
	b = cross(n, t);
}

vec3 soft_clamp_smoothstep(vec3 color)
{
	float lum = dot(color, vec3(0.2126, 0.7152, 0.0722));
	float transition_start = clamp_threshold;
	float transition_end = clamp_threshold * 1.5;

	if (lum <= transition_start)
		return color;
	if (lum >= transition_end)
		return color * (transition_end / lum);

	float t =
	    (lum - transition_start) / (transition_end - transition_start);
	float blend = 1.0 - smoothstep(0.0, 1.0, t) * 0.5;
	return color * blend;
}

void main(void)
{
	ivec2 outSize = imageSize(irradianceMap);
	ivec2 pos = ivec2(gl_GlobalInvocationID.x,
	                  gl_GlobalInvocationID.y + u_offset_y);

	if (pos.x >= outSize.x || pos.y >= outSize.y || pos.y >= u_max_y)
		return;

	vec2 uv = vec2(pos) / vec2(outSize);
	vec3 N = normalize(uvToDir(uv));

	vec3 irradiance = vec3(0.0);
	vec3 up, right;
	OrthonormalBasis(N, right, up);

#ifndef SAMPLE_DELTA
#define SAMPLE_DELTA 0.025
#endif
	float sampleDelta = SAMPLE_DELTA;
	float nrSamples = 0.0;

	for (float phi = 0.0; phi < TWO_PI; phi += sampleDelta) {
		for (float theta = 0.0; theta < 0.5 * PI;
		     theta += sampleDelta) {
			// Spherical to cartesian (tangent space)
			vec3 tangentSample =
			    vec3(sin(theta) * cos(phi), sin(theta) * sin(phi),
			         cos(theta));
			// Tangent to world space
			vec3 sampleVec = tangentSample.x * right +
			                 tangentSample.y * up +
			                 tangentSample.z * N;

			// On échantillonne l'envMap d'origine
			vec3 env_color =
			    textureLod(envMap, dirToUV(sampleVec), 0.0).rgb;

			/* Sanitize Input */
			if (any(isnan(env_color)) || any(isinf(env_color)))
				env_color = vec3(0.0);
			env_color =
			    max(env_color, vec3(0.0)); /* No negative light */

			env_color = soft_clamp_smoothstep(env_color);

			irradiance += env_color * cos(theta) * sin(theta);
			nrSamples++;
		}
	}

	irradiance = PI * irradiance * (1.0 / nrSamples);

	/* Sanitize Output */
	if (any(isnan(irradiance)) || any(isinf(irradiance)))
		irradiance = vec3(0.0);
	irradiance = max(irradiance, vec3(0.0));

	imageStore(irradianceMap, pos, vec4(irradiance, 1.0));
}
