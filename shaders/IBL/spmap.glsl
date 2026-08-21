#version 450 core

const float PI = 3.14159265359;
const float TwoPI = 2.0 * PI;
const float Epsilon = 0.00001;
#ifndef SAMPLE_COUNT
#define SAMPLE_COUNT 1024u
#endif
const float InvNumSamples = 1.0 / float(SAMPLE_COUNT);

layout(binding = 0) uniform sampler2D envMap;  // Texture équirectangulaire HDR
layout(binding = 1,
       rgba16f) restrict writeonly uniform image2D prefilteredEnvMap;

layout(location = 0) uniform float roughnessValue;
layout(location = 1) uniform int currentMipLevel;
layout(location = 2) uniform float clamp_threshold;

layout(location = 3) uniform int u_offset_y;
layout(location = 4) uniform int u_max_y;

layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;

// Convertit un vecteur directionnel en coordonnées UV équirectangulaires
vec2 dirToUV(vec3 v)
{
	float phi = (abs(v.z) < 1e-5 && abs(v.x) < 1e-5) ? 0.0 : atan(v.z, v.x);
	vec2 uv = vec2(phi, asin(clamp(v.y, -1.0, 1.0)));
	uv *= vec2(1.0 / TwoPI, 1.0 / PI);
	uv += 0.5;
	return uv;
}

float radicalInverse_VdC(uint bits)
{
	bits = (bits << 16u) | (bits >> 16u);
	bits = ((bits & 0x55555555u) << 1u) | ((bits & 0xAAAAAAAAu) >> 1u);
	bits = ((bits & 0x33333333u) << 2u) | ((bits & 0xCCCCCCCCu) >> 2u);
	bits = ((bits & 0x0F0F0F0Fu) << 4u) | ((bits & 0xF0F0F0F0u) >> 4u);
	bits = ((bits & 0x00FF00FFu) << 8u) | ((bits & 0xFF00FF00u) >> 8u);
	return float(bits) * 2.3283064365386963e-10;  // / 0x100000000
}

vec2 sampleHammersley(uint i)
{
	return vec2(i * InvNumSamples, radicalInverse_VdC(i));
}

vec3 sampleGGX(float u1, float u2, float roughness)
{
	float alpha = roughness * roughness;
	alpha = max(alpha, 0.001); /* Prevent divide by zero */

	float cosTheta = sqrt((1.0 - u2) / (1.0 + (alpha * alpha - 1.0) * u2));
	float sinTheta = sqrt(1.0 - cosTheta * cosTheta);  // Trig. identity
	float phi = TwoPI * u1;

	return vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
}

float ndfGGX(float cosHalfVector, float roughness)
{
	float alpha = roughness * roughness;
	alpha = max(alpha, 0.001); /* Prevent divide by zero */
	float alphaSq = alpha * alpha;

	float denom = (cosHalfVector * cosHalfVector) * (alphaSq - 1.0) + 1.0;
	return alphaSq / (PI * denom * denom);
}

vec3 tangentToWorld(const vec3 v, const vec3 N, const vec3 S, const vec3 T)
{
	return S * v.x + T * v.y + N * v.z;
}

void main(void)
{
	ivec2 outputSize = imageSize(prefilteredEnvMap);
	ivec2 pos = ivec2(gl_GlobalInvocationID.x,
	                  gl_GlobalInvocationID.y + u_offset_y);

	if (pos.x >= outputSize.x || pos.y >= outputSize.y || pos.y >= u_max_y)
		return;

	// Calcul de la direction N à partir des coordonnées de l'image de
	// sortie
	vec2 st = vec2(pos) / vec2(outputSize);
	float phi = (st.x - 0.5) * TwoPI;
	float theta = (st.y - 0.5) * PI;

	vec3 normal;
	normal.x = cos(theta) * cos(phi);
	normal.y = sin(theta);
	normal.z = cos(theta) * sin(phi);
	normal = normalize(normal);

	vec3 viewDir = normal;
	vec3 tangent, bitangent;
	// Utilisation d'une base stable
	vec3 up = abs(normal.z) < 0.999 ? vec3(0, 0, 1) : vec3(1, 0, 0);
	tangent = normalize(cross(up, normal));
	bitangent = cross(normal, tangent);

	vec3 accumulatedColor = vec3(0);
	float totalWeight = 0;

	/* Ensure valid clamp threshold */
	float safeThreshold = max(clamp_threshold, 1.0);

	for (uint i = 0; i < SAMPLE_COUNT; ++i) {
		vec2 u = sampleHammersley(i);
		vec3 H = tangentToWorld(sampleGGX(u.x, u.y, roughnessValue),
		                        normal, tangent, bitangent);
		vec3 L = normalize(2.0 * dot(viewDir, H) * H - viewDir);

		float NoL = max(dot(normal, L), 0.0);
		if (NoL > 0.0) {
			float NoH = max(dot(normal, H), 0.0);
			float VoH = max(dot(viewDir, H), 0.0);
			float pdf = (ndfGGX(NoH, roughnessValue) * NoH) /
			            (4.0 * VoH + 1e-5);

			// Calcul du MIP level pour l'échantillonnage de l'env
			// map d'entrée
			float saTexel = 4.0 * PI /
			                (6.0 * textureSize(envMap, 0).x *
			                 textureSize(envMap, 0).y);
			float saSample =
			    1.0 / (float(SAMPLE_COUNT) * pdf + 1e-5);
			float mipLevel = roughnessValue == 0.0
			                     ? 0.0
			                     : 0.5 * log2(saSample / saTexel);
			float maxMip = max(log2(float(max(textureSize(envMap, 0).x, textureSize(envMap, 0).y))), 0.0);
			if (mipLevel >= 0.0 && mipLevel <= maxMip) {
				// Keep valid mipLevel
			} else if (mipLevel < 0.0) {
				mipLevel = 0.0;
			} else {
				mipLevel = maxMip;
			}

			vec3 envColor =
			    textureLod(envMap, dirToUV(L), mipLevel).rgb;

			/* Sanitize envColor (remove NaNs) */
			if (any(isnan(envColor)) || any(isinf(envColor))) {
				envColor = vec3(0.0);
			}

			/* Clamping "Fireflies" pour éviter les NaNs/Artefacts
			 * avec les cartes HDR très intenses */
			envColor = min(envColor, vec3(safeThreshold));

			accumulatedColor += envColor * NoL;
			totalWeight += NoL;
		}
	}

	vec4 resultColor = vec4(accumulatedColor, 1.0);
	if (totalWeight > 0.0) {
		resultColor = vec4(accumulatedColor / totalWeight, 1.0);
	}

	/* Force clamp to prevent INF/MAX_FLOAT issues in the texture */
	resultColor.rgb = min(resultColor.rgb, vec3(65500.0));

	imageStore(prefilteredEnvMap, pos, resultColor);
}
