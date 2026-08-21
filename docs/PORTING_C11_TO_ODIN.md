# Portage suckless-ogl (C11) → suckless-odin

Document de référence exhaustif pour l'état d'avancement, la comparaison architecturale, le tooling, la prise en charge multi-plateforme (Windows / Wine / Proton), l'intégration Steam et les pipelines CI/CD entre le projet legacy C11 (`suckless-ogl`) et son portage moderne en Odin (`suckless-odin`).

---

## 1. Vue d'ensemble et métriques comparatives

| Axe d'analyse | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut & Évolution |
|---|---|---|---|
| **Fichiers source moteur** | 188 (`.c`, `.h`) | 61 (`.odin`) | -67% de fichiers (modularité native Odin sans `.h`) |
| **Lignes de code (SLOC)** | ~30 533 lignes | ~15 526 lignes | ~51% de code en moins (expressivité / abstractions zero-cost) |
| **Shaders GLSL** | 60 fichiers (4 425 loc) | 29 fichiers (3 250 loc) | Architecture de variantes dynamiques avec `#define` |
| **Tests automatisés** | 78 fichiers (~14 478 loc, Unity) | 15 fichiers (5 056 loc) | **183 tests passants** (`unit`, `cli`, `shader`, `gl/xvfb`) |
| **Effets Post-Processing** | 13 effets | 14 effets + A/B split + Stops EV | 100% porté + contrôles temps réel ImGui |
| **Interface & Contrôles** | ~67 raccourcis clavier + overlay minimal | Dear ImGui dockable + Fuzzy search + 11 touches clés | UI graphique complète + recherche instantanée `Ctrl+F` |
| **Support Windows / Cross-compil** | MinGW + Wine + CPack + `package_win.sh` | Windows amd64 natif + MinGW/LLD + Wine (`task build-win`, `test-win`, `package-win`) | ✅ 100% Porté (Cross-compilation, Wine tests, Packaging standalone) |
| **Écosystème Steam & Proton** | Runner Proton + Artworks Steamgrid + Injector | — | ❌ *Écosystème Steam non porté en Odin* |
| **Décodeur HDR & SIMD** | `stb_image` float classique | SIMD AVX2/NEON FP16 direct (10.8× plus rapide) | Traitement streaming mémoire zero-heap |
| **Vérification formelle** | — | Modèle TLA+ + compilateur codegen | Automate `Env_Manager` prouvé sans deadlock par TLC |
| **Profilage & Télémétrie** | Tracy + Apitrace + Perf + Sampler | Tracy (CPU/GPU/PBO) + RenderDoc + VTune + Heaptrack | Profilage GPU temps réel par passe dans l'UI |
| **Build & Tooling** | CMake + Makefile + Justfile (130+ targets) | Taskfile (35+ targets) + Docker CI | Automatisation unifiée sans dépendances complexes |

---

## 2. Statut détaillé par sous-système moteur

### Légende
- ✅ **Porté** — Fonctionnel, niveau ISO ou supérieur au code C11
- 🟡 **Partiel / Différent** — Fonctionnel mais avec une approche architecturale différente ou sous-ensemble ciblé
- ❌ **Non porté** — Présent en C11, absent ou à implémenter en Odin

---

### 2.1. Core Application, Fenêtrage & Session

| Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Notes & Différences |
|---|---|---|---|---|
| Contexte OpenGL 4.4/4.5 Core + GLFW | [`app.c`](../suckless-ogl/src/app.c), [`app_window.c`](../suckless-ogl/src/app_window.c) | [`src/app/app.odin`](../src/app/app.odin), [`src/app/window.odin`](../src/app/window.odin) | ✅ | Configuration GLFW propre, support multi-OS et Wayland |
| Boucle principale (Poll → Update → Render → Swap) | [`app.c`](../suckless-ogl/src/app.c) | [`src/app/app.odin`](../src/app/app.odin) | ✅ | Découplage strict des passes de rendu et de l'UI |
| Toggle Plein écran (`F`) | [`app_input.c`](../suckless-ogl/src/app_input.c) | [`src/app/input.odin`](../src/app/input.odin) | ✅ | Restauration propre des coordonnées et dimensions de fenêtre |
| CLI & Arguments | [`cli.c`](../suckless-ogl/src/cli.c) | [`src/cli.odin`](../src/cli.odin) | ✅ | Support `-h`, `-v`, `--no-postfx`, `--postfx-preset`, `--vsync`, `--benchmark`, `--benchmark-frames`, `--compute-profile` |
| Logging & Debug Output | [`log.c`](../suckless-ogl/src/log.c), [`gl_debug.c`](../suckless-ogl/src/gl_debug.c) | [`src/core/log/log.odin`](../src/core/log/log.odin), [`src/core/gl_debug/gl_debug.odin`](../src/core/gl_debug/gl_debug.odin) | ✅ | Niveaux de log, timestamps, KHR_debug markers / labels, Tracy log |
| Persistance d'état de session | — | [`src/core/session/session.odin`](../src/core/session/session.odin), [`src/app/session.odin`](../src/app/session.odin) | ✅ *(Odin+)* | Sauvegarde/restauration JSON automatique (`session.json`) de 29 paramètres (caméra, postfx, env, UI) |
| Mode Performance | [`perf_mode.c`](../suckless-ogl/src/perf_mode.c) | [`src/core/perf_mode/perf_mode.odin`](../src/core/perf_mode/perf_mode.odin) | ✅ | Mode basse consommation / headless benchmarking |
| Télémétrie & Export de métriques | [`app_metrics.c`](../suckless-ogl/src/app_metrics.c) | [`src/app/telemetry.odin`](../src/app/telemetry.odin) | ✅ | Export métriques de rendu, timings, JSON/CSV |

---

### 2.2. Caméra & Physique

| Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Notes & Différences |
|---|---|---|---|---|
| Caméra FPS (Position, Yaw, Pitch) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | Modèle mathématique identique |
| Physique & Inertie (Accélération, Friction, Verlet) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | Réglages dynamiques exposés dans l'onglet ImGui Camera |
| Lissage souris (Filtre EMA) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | `mouse_smoothing_factor` réglable |
| Lissage de rotation (Interpolation Slerp/Lerp) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | `rotation_smoothing` réglable |
| Head bobbing (Oscillation sinusoïdale de marche) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | Amplitude et fréquence configurables |
| Impulsion molette souris (Vélocité axiale) | [`camera.c`](../suckless-ogl/src/camera.c) | [`src/camera/camera.odin`](../src/camera/camera.odin) | ✅ | Défilement molette accélère la caméra vers l'avant |
| Reset caméra (`Space` / Bouton UI) | [`app_input.c`](../suckless-ogl/src/app_input.c) | [`src/app/input.odin`](../src/app/input.odin), [`src/gui/gui.odin`](../src/gui/gui.odin) | ✅ | Remise aux valeurs par défaut des settings |
| Mode curseur / Mouselook (`C` / `F2`) | [`app_input.c`](../suckless-ogl/src/app_input.c) | [`src/app/input.odin`](../src/app/input.odin) | ✅ | Transition automatique curseur normal/désactivé à l'ouverture de l'UI |

---

### 2.3. Rendu Géométrique & PBR

| Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Notes & Différences |
|---|---|---|---|---|
| Rendu Billboards PBR instanciés (SSBO) | [`billboard_renderer.c`](../suckless-ogl/src/billboard_renderer.c), [`ssbo_rendering.c`](../suckless-ogl/src/ssbo_rendering.c) | [`src/rendering/billboard.odin`](../src/rendering/billboard.odin), [`src/rendering/instanced.odin`](../src/rendering/instanced.odin) | ✅ | Ray-marching analytique sphère + écriture `gl_FragDepth` |
| Anti-Aliasing analytique des silhouettes (Edge AA) | [`scene_render.c`](../suckless-ogl/src/scene_render.c), [`shaders/pbr_ibl_billboard.frag`](../suckless-ogl/shaders/pbr_ibl_billboard.frag) | [`src/rendering/billboard.odin`](../src/rendering/billboard.odin), [`shaders/pbr_billboard.frag`](../shaders/pbr_billboard.frag) | ✅ | `smoothstep` sur discriminant + mode debug heatmap |
| Specular Anti-Aliasing | [`app_input.c`](../suckless-ogl/src/app_input.c) | [`src/rendering/types/types.odin`](../src/rendering/types/types.odin), [`shaders/pbr_billboard.frag`](../shaders/pbr_billboard.frag) | ✅ | Modes Toksvig, Kaplanyan, Geometric, Combined + split preview |
| Tri des sphères CPU (`qsort` & `Radix sort`) | [`billboard_sorter.c`](../suckless-ogl/src/billboard_sorter.c) | [`src/rendering/sorting.odin`](../src/rendering/sorting.odin) | ✅ | Tri par distance caméra pour transparence/profondeur |
| Tri des sphères GPU (Bitonic Compute) | [`shaders/sphere_sort.glsl`](../suckless-ogl/shaders/sphere_sort.glsl) | — | ❌ | Non implémenté en Odin (le Radix CPU est suffisant pour N=100 sphères) |
| Mode Filaire (`Wireframe`) | [`renderer.c`](../suckless-ogl/src/renderer.c) | [`src/scene/scene.odin`](../src/scene/scene.odin), [`src/gui/gui.odin`](../src/gui/gui.odin) | ✅ | Visualisation des quads instanciés via `glPolygonMode` |
| Maillage Icosphère instancié (VBO mesh) | [`icosphere.c`](../suckless-ogl/src/icosphere.c), [`instanced_rendering.c`](../suckless-ogl/src/instanced_rendering.c) | — | ❌ | Le portage Odin s'est concentré sur les billboards analytiques |
| Matériaux PBR JSON (100 presets) | [`material.c`](../suckless-ogl/src/material.c) | [`src/rendering/material.odin`](../src/rendering/material.odin) | ✅ | Chargement direct depuis [`assets/materials/pbr_materials.json`](../assets/materials/pbr_materials.json) |

---

### 2.4. Image-Based Lighting (IBL) & Compute Shaders

| Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Notes & Différences |
|---|---|---|---|---|
| BRDF LUT Compute (Split-Sum 512×512 RG16F) | [`ibl_coordinator.c`](../suckless-ogl/src/ibl_coordinator.c), [`shaders/IBL/spbrdf.glsl`](../suckless-ogl/shaders/IBL/spbrdf.glsl) | [`src/rendering/ibl.odin`](../src/rendering/ibl.odin), [`shaders/IBL/spbrdf.glsl`](../shaders/IBL/spbrdf.glsl) | ✅ | Calcul d'intégration split-sum |
| Irradiance Map Compute (Diffuse IBL 64×64 RGBA16F) | [`ibl_coordinator.c`](../suckless-ogl/src/ibl_coordinator.c), [`shaders/IBL/irmap.glsl`](../suckless-ogl/shaders/IBL/irmap.glsl) | [`src/rendering/ibl.odin`](../src/rendering/ibl.odin), [`shaders/IBL/irmap.glsl`](../shaders/IBL/irmap.glsl) | ✅ | Convolution hémisphérique diffuse |
| Prefilter Map Compute (Specular IBL 1024×1024, 5 mips) | [`ibl_coordinator.c`](../suckless-ogl/src/ibl_coordinator.c), [`shaders/IBL/spmap.glsl`](../suckless-ogl/shaders/IBL/spmap.glsl) | [`src/rendering/ibl.odin`](../src/rendering/ibl.odin), [`shaders/IBL/spmap.glsl`](../shaders/IBL/spmap.glsl) | ✅ | Échantillonnage importance GGX par niveau de rugosité |
| Inspecteur IBL interactif & Zoom texels | — | [`src/gui/gui.odin`](../src/gui/gui.odin) | ✅ *(Odin+)* | Inspection ROI 16×16 texels, lecture RGBA/Luminance, swatch, exposition EV, calcul VRAM |
| Réglage dynamique des Compute Shaders (`Compute Tuning`) | — | [`src/gui/gui_compute.odin`](../src/gui/gui_compute.odin), [`src/core/settings/settings.odin`](../src/core/settings/settings.odin) | ✅ *(Odin+)* | Profils `legacy` vs `optimized`, réglage interactif du nombre d'échantillons et du découpage (slicing) |
| Découpage temporel progressif inter-frames (Slicing) | [`ibl_coordinator.c`](../suckless-ogl/src/ibl_coordinator.c) | [`src/app/compute.odin`](../src/app/compute.odin) | 🟡 | En Odin, dispatch direct configuré avec paramètres de découpage |

---

### 2.5. Skybox & Gestionnaire d'Environnement (`Env_Manager`)

| Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Notes & Différences |
|---|---|---|---|---|
| Rendu Skybox Equirectangulaire | [`skybox.c`](../suckless-ogl/src/skybox.c) | [`src/rendering/skybox.odin`](../src/rendering/skybox.odin) | ✅ | Fullscreen quad avec coordonnées sphériques |
| Conversion et rendu Cubemap | [`skybox.c`](../suckless-ogl/src/skybox.c) | [`src/rendering/skybox.odin`](../src/rendering/skybox.odin) | ✅ | Shaders [`equirect_to_cubemap.*`](../shaders/equirect_to_cubemap.vert) |
| Flou d'environnement réglable (LOD Blur) | [`app_input.c`](../suckless-ogl/src/app_input.c) | [`src/rendering/skybox.odin`](../src/rendering/skybox.odin), [`src/gui/gui.odin`](../src/gui/gui.odin) | ✅ | Choix de la source de flou : Mipmaps classiques ou Prefilter IBL |
| Mode de différence de flou (`Blur Diff`) | — | [`shaders/background_blur_diff.frag`](../shaders/background_blur_diff.frag), [`src/gui/gui.odin`](../src/gui/gui.odin) | ✅ *(Odin+)* | Visualisation A/B de l'écart Mipmap vs IBL avec curseur de gain |
| Chargement asynchrone d'environnement (Thread + PBO) | [`async_loader.c`](../suckless-ogl/src/async_loader.c) | [`src/scene/async_loader.odin`](../src/scene/async_loader.odin) | ✅ | Thread de décodage + upload PBO sans saccade de rendu |
| Décodeur HDR SIMD ultra-rapide | — | [`src/core/simd_utils/simd_utils.odin`](../src/core/simd_utils/simd_utils.odin) | ✅ *(Odin+)* | Décodeur maison streaming SIMD AVX2/NEON FP16 (10.8× plus rapide que `stb_image`) |
| Défilement des environnements (`PgUp` / `PgDn`) | [`env_manager.c`](../suckless-ogl/src/env_manager.c) | [`src/scene/env_manager.odin`](../src/scene/env_manager.odin) | ✅ | Cycle dans le répertoire des maps HDR |
| Transitions visuelles (Crossfade / Blackout) | [`env_manager.c`](../suckless-ogl/src/env_manager.c) | [`src/scene/env_manager.odin`](../src/scene/env_manager.odin) | ✅ | Capture de snapshot écran et fondu enchaîné dynamique |
| Vérification formelle de l'automate d'environnement | — | [`verification/EnvManagerVerification.tla`](../verification/EnvManagerVerification.tla), [`src/scene/env_manager_states.gen.odin`](../src/scene/env_manager_states.gen.odin) | ✅ *(Odin+)* | Spécification formelle TLA+ prouvée par TLC + générateur de code automate |

---

### 2.6. Pipeline de Post-Processing (PostFX)

| Effet / Fonctionnalité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut | Contrôles & Spécificités |
|---|---|---|---|---|
| **Scene FBO HDR + MRT** (Color RGBA16F + Velocity RGBA16F + Depth/Stencil) | [`postprocess_init.c`](../suckless-ogl/src/postprocess_init.c) | [`src/rendering/postfx/pipeline.odin`](../src/rendering/postfx/pipeline.odin) | ✅ | Architecture MRT ping-pong avec FBOs dédiés |
| **Exposition Manuelle** | [`postprocess_input.c`](../suckless-ogl/src/postprocess_input.c) | [`src/rendering/postfx/pipeline.odin`](../src/rendering/postfx/pipeline.odin) | ✅ | Slider temps réel EV 0.1 → 10.0 |
| **Tonemapping Filmique** | [`shaders/postprocess/tonemap.glsl`](../suckless-ogl/shaders/postprocess/tonemap.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Paramètres Slope, Toe, Shoulder, Black Clip, White Clip |
| **Vignettage** | [`shaders/postprocess/vignette.glsl`](../suckless-ogl/shaders/postprocess/vignette.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Intensité, progressivité (smoothness), rondeur |
| **Grain Argentique** (`Film Grain`) | [`shaders/postprocess/grain.glsl`](../suckless-ogl/shaders/postprocess/grain.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Intensité, taille de texel, animation temporelle |
| **Aberration Chromatique** | [`shaders/postprocess/chromatic_aberration.glsl`](../suckless-ogl/shaders/postprocess/chromatic_aberration.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Décalage spectral radial R/G/B |
| **Color Grading** | [`shaders/postprocess/color_grading.glsl`](../suckless-ogl/shaders/postprocess/color_grading.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Saturation, Contraste, Gamma, Gain, Offset |
| **Bloom** (Pyramide multi-niveaux) | [`effects/fx_bloom.c`](../suckless-ogl/src/effects/fx_bloom.c) | [`src/rendering/postfx/bloom.odin`](../src/rendering/postfx/bloom.odin) | ✅ | Prefilter soft-knee, downsampling 13-tap, upsampling 9-tap bicubic, mode Bloom Debug |
| **FXAA 3.11** | [`shaders/postprocess/fxaa.glsl`](../suckless-ogl/shaders/postprocess/fxaa.glsl) | [`src/rendering/postfx/fxaa_prepass.odin`](../src/rendering/postfx/fxaa_prepass.odin), [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Pré-passe luminance dans alpha, seuillage de contours, mode FXAA Debug |
| **Auto-Exposition / Adaptation visuelle** | [`effects/fx_auto_exposure.c`](../suckless-ogl/src/effects/fx_auto_exposure.c) | [`src/rendering/postfx/auto_exposure.odin`](../src/rendering/postfx/auto_exposure.odin) | ✅ | Shaders compute réduction luminance (single-pass / downsample) + adaptation temporelle |
| **Depth of Field** (Profondeur de champ) | [`effects/fx_dof.c`](../suckless-ogl/src/effects/fx_dof.c) | [`src/rendering/postfx/dof.odin`](../src/rendering/postfx/dof.odin) | ✅ | Distance focale, plage de netteté, bokeh anamorphic ratio, DoF Debug |
| **Flou de Mouvement** (`Motion Blur`) | [`effects/fx_motion_blur.c`](../suckless-ogl/src/effects/fx_motion_blur.c) | [`src/rendering/postfx/motion_blur.odin`](../src/rendering/postfx/motion_blur.odin) | ✅ | Compute tile-max + neighbor-max velocity, reconstruction multidirectionnelle, 4 vues de debug |
| **Banding / Quantification** | [`shaders/postprocess/banding.glsl`](../suckless-ogl/shaders/postprocess/banding.glsl) | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | 5 modes (Linear, Dithered, Perceptual, Channel, Luminance), dither strength |
| **Brouillard Volumétrique / Distance** (`Fog`) | [`shaders/postprocess/fog.glsl`](../suckless-ogl/shaders/postprocess/fog.glsl) | [`shaders/postfx/fog_common.glsl`](../shaders/postfx/fog_common.glsl), [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ | Atténuation exponentielle + gradient de hauteur + Fog Debug mask |
| **LUT 3D Color Grading** | [`effects/fx_lut3d.c`](../suckless-ogl/src/effects/fx_lut3d.c) | [`src/rendering/postfx/lut3d.odin`](../src/rendering/postfx/lut3d.odin) | ✅ | Parseur `.cube` (16³ à 64³), texture 3D trilinéaire, mode Debug delta |
| **Visualisation des Stops de Luminance** | — | [`shaders/postfx/postfx.frag`](../shaders/postfx/postfx.frag) | ✅ *(Odin+)* | Fausse couleur de luminance style Filament (gris moyen 18% = Cyan) |
| **Écran Scindé A/B par effet** (`A/B Split`) | — | [`src/gui/gui_postfx.odin`](../src/gui/gui_postfx.odin), [`src/rendering/postfx/glasbey_palette.odin`](../src/rendering/postfx/glasbey_palette.odin) | ✅ *(Odin+)* | Ligne de séparation interactive par effet, colorée via palette maximale Glasbey (CIELAB) |
| **Presets de Post-Processing** | [`postprocess_presets.c`](../suckless-ogl/src/postprocess_presets.c) | [`src/rendering/postfx/presets.odin`](../src/rendering/postfx/presets.odin), [`src/rendering/postfx/settings_io.odin`](../src/rendering/postfx/settings_io.odin) | ✅ | Presets intégrés (Default, Subtle, Cinematic, Vibrant, Clean) + Sauvegarde/Chargement JSON |
| **Cache de Spécialisation de Shaders** | — | [`src/rendering/postfx/shader_cache.odin`](../src/rendering/postfx/shader_cache.odin) | ✅ *(Odin+)* | Compilation de variantes avec `#define` statiques éliminant le branchement dynamique |

---

### 2.7. Sous-systèmes non portés (Spécifiques C11)

| Fonctionnalité C11 | Fichiers C11 (`suckless-ogl`) | Statut | Rationale & Décision |
|---|---|---|---|
| **Simulation N-Body gravitationnelle O(N²)** | [`src/nbody/`](../suckless-ogl/src/nbody), [`src/scene_nbody.c`](../suckless-ogl/src/scene_nbody.c) | ❌ | Démo physique interactive N-Body du projet C. Non requis pour le moteur PBR/IBL central. |
| **Rendu de traînées de particules** (`Trails`) | [`src/trail_renderer.c`](../suckless-ogl/src/trail_renderer.c), [`shaders/trail.*`](../suckless-ogl/shaders/trail.vert) | ❌ | Lié au système N-Body. |
| **VFX d'ondes de choc** (`Shockwaves`) | [`src/shockwave.c`](../suckless-ogl/src/shockwave.c), [`shaders/shockwave.*`](../suckless-ogl/shaders/shockwave.vert) | ❌ | Lié aux collisions N-Body. |
| **Light Probes / GI 1-Bounce (Harmoniques Sphériques SH9)** | [`src/light_probes.c`](../suckless-ogl/src/light_probes.c), [`src/sh_math.c`](../suckless-ogl/src/sh_math.c) | ❌ | Grille 3D de sondes SH9 avec worker pthread. |
| **Support Manette / Gamepad** | [`src/gamepad_input.c`](../suckless-ogl/src/gamepad_input.c) | ❌ | Non prioritaire vis-à-vis du workflow clavier/souris + GUI. |
| **Registre de Keybindings déclaratif & Notifications Toast** | [`src/app_binding.c`](../suckless-ogl/src/app_binding.c), [`src/action_notifier.c`](../suckless-ogl/src/action_notifier.c) | ❌ | Remplacé avantageusement par la GUI Dear ImGui interactive + tooltips d'aide intégrés. |

---

## 3. Plateformes, Cross-Compilation, Windows & Écosystème Steam

Un pan majeur de l'infrastructure de `suckless-ogl` concerne la portabilité Windows, l'exécution via Wine/Proton, et l'intégration complète avec le client Steam (Steam Deck / Desktop).

### 3.1. Prise en charge Windows & Cross-Compilation

| Capacité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Écart / À faire en Odin |
|---|---|---|---|
| **Cross-compilation MinGW / LLD** | [`toolchain-mingw.cmake`](../suckless-ogl/toolchain-mingw.cmake), cible `just build-win` | [`scripts/build_win.sh`](../scripts/build_win.sh), [`scripts/build_win_deps.sh`](../scripts/build_win_deps.sh), cibles `task build-win`, `task build-win-release`, `task build-win-ultra` | ✅ Porté : compilation Odin `-target:windows_amd64 -build-mode:obj` + édition de liens statique via Clang/LLD avec GLFW, ImGui, STB, SIMD AVX2. |
| **Exécution via Wine** | `just run-win` (`wine build-win/app.exe`) | `task run-win`, `task run-win-release` | ✅ Porté : exécution transparente de `suckless-odin.exe` sous Wine. |
| **Tests unitaires & intégration sous Wine** | `just test-win`, `just test-win-unit` (ctest + Wine) | [`scripts/test_win.sh`](../scripts/test_win.sh), cibles `task test-win`, `task test-win-unit`, `task test-win-cli`, `task test-win-shader` | ✅ Porté : exécution automatisée de 104 tests (79 unit, 13 cli, 12 shader) sous Wine. |
| **Packaging Windows & Déploiement** | [`scripts/package_win.sh`](../suckless-ogl/scripts/package_win.sh) (`package-win` → `tar.zst` rsyncable) | [`scripts/package_win.sh`](../scripts/package_win.sh), cible `task package-win` | ✅ Porté : génération autonome `tar.zst` (rsyncable) et archive `.zip` intégrant binaire `.exe`, shaders et assets. |
| **CI Windows (Container Docker & Workflows)** | [`.github/workflows/Dockerfile.ci-windows`](../suckless-ogl/.github/workflows/Dockerfile.ci-windows) | [`.github/workflows/ci.yml`](.github/workflows/ci.yml), [`.github/workflows/release.yml`](.github/workflows/release.yml) | ✅ Porté : jobs `test-windows` et `package-windows` dans `ci.yml`, pipeline de publication release multi-plateforme dans `release.yml`. |

### 3.2. Écosystème Steam & Proton

Voir le guide d'intégration complet : [`docs/steam-integration-and-proton-guide.md`](docs/steam-integration-and-proton-guide.md).

| Capacité | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Écart / À faire en Odin |
|---|---|---|---|
| **Runner Steam Proton (Flatpak / Natif)** | [`scripts/run_proton.sh`](../suckless-ogl/scripts/run_proton.sh), cible `just run-proton` | [`scripts/run_proton.sh`](scripts/run_proton.sh), cible `task run-proton` | ✅ Porté : exécution automatisée sous Proton Experimental (Flatpak ou natif) dans un sandbox `/tmp` avec préfixe dédié. |
| **Gestion du préfixe Proton** | Création automatique de `compatdata/suckless-ogl` | [`scripts/run_proton.sh`](scripts/run_proton.sh) | ✅ Porté : isolation complète du `STEAM_COMPAT_DATA_PATH` dans le bac à sable de release. |
| **Génération des Artworks Steam (Steam Grid)** | [`scripts/generate_steam_assets.sh`](../suckless-ogl/scripts/generate_steam_assets.sh), cible `just steam-gen-assets` | [`scripts/generate_steam_assets.sh`](scripts/generate_steam_assets.sh), cible `task steam-gen-assets` | ✅ Porté : génération ImageMagick de Cover (600×900), Hero (1920×620), Banner (460×215), Logo transparent (800×300) et icônes `.png` / `.ico`. |
| **Injection automatique d'artworks Steam** | [`scripts/inject_steam_art.py`](../suckless-ogl/scripts/inject_steam_art.py), cible `just steam-art` | [`scripts/inject_steam_art.py`](scripts/inject_steam_art.py), cible `task steam-art` | ✅ Porté : scan automatique de `shortcuts.vdf` Steam Flatpak/Natif et injection directe dans le dossier grid du compte utilisateur. |



### 3.3. Outils et Visionneuses autonomes

| Outil | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Écart / À faire en Odin |
|---|---|---|---|
| **Viewer KTX autonome** (`ktx_viewer`) | [`src/ktx_viewer.c`](../suckless-ogl/src/ktx_viewer.c), cibles `build-ktx-viewer`, `run-ktx-viewer` | — | Outil dédié à l'inspection et à la validation des textures compressées KTX2. Non porté en Odin. |

---

## 4. CI/CD, Tests de Stress, Profilage & Assurance Qualité

### 4.1. Stratégie de Tests et Validation

| Type de Test | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Comparaison & Avantages |
|---|---|---|---|
| **Tests Unitaires & CLI** | Framework Unity (60+ tests C) | Moteur de test natif Odin (92 tests unit/cli) | Odin exécute les tests sans binaire de test lourd séparé (`odin test`). |
| **Tests de Shaders CPU** | Parsing & includes manuels | Validation CPU complète (12 tests) | Détection des boucles d'include, limites de profondeur (16). |
| **Tests OpenGL Headless (GPU)** | CTest + Xvfb (`test-integration`) | 79 tests GL headless sous Xvfb (`tests/gl/`) | Validation bit-for-bit des pipelines IBL, compute, FBOs et régression visuelle multi-vues. |
| **Fuzzer de Chaos Temporel** | — | [`tests/gl/test_gl_chaos.odin`](../tests/gl/test_gl_chaos.odin) | *(Odin+)* Injection de mutations aléatoires d'états GL pour traquer les fuites et corruptions. |

### 4.2. Tests de Stress et Scénarios Dédiés

| Scénario de Stress | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Statut |
|---|---|---|---|
| **Stress Fullscreen / Windowed** | [`scripts/test_stress_fullscreen.sh`](../suckless-ogl/scripts/test_stress_fullscreen.sh) (100 toggles rapides X11/Wine) | [`scripts/test_stress_fullscreen.sh`](../scripts/test_stress_fullscreen.sh) (`task stress-fullscreen`) | ✅ Porté et fiabilisé avec isolation Xvfb par défaut et synchronisation événementielle. |
| **Stress Fullscreen sous ASan** | Cible `just stress-fullscreen-asan` | Cible `task stress-fullscreen-asan` (`lsan.supp`) | ✅ Porté, 50 cycles sous AddressSanitizer sans aucune fuite ni corruption de framebuffer. |
| **Stress Asynchrone sous TSan / ASan** | [`scripts/test_stress_envmap.sh`](../suckless-ogl/scripts/test_stress_envmap.sh) (30 switches HDR sous ThreadSanitizer) | [`scripts/test_stress_envmap.sh`](../scripts/test_stress_envmap.sh) (`task stress-envmap`, `task stress-envmap-sanitize`) | ✅ Porté, validation des transitions d'états `Env_Manager` sans blocage ni data races. |
| **Benchmark de sortie anticipée** | — | Cible `task bench-early-exit` (`xdotool` Escape) | ✅ *(Odin+)* Mesure du temps de startup et d'arrêt propre du moteur. |

### 4.3. Profilage, Traçage et Télémétrie

| Outil de Profilage | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Comparaison |
|---|---|---|---|
| **GPU Profiler en direct** | Ping-pong queries custom + overlay | [`src/rendering/postfx/gpu_timers.odin`](../src/rendering/postfx/gpu_timers.odin) | Tableau interactif ImGui avec timings par passe (*Avg, Min, Max*) et calcul du % de frame budget. |
| **Tracy Profiler** | [`tracy_manager.c`](../suckless-ogl/src/tracy_manager.c) | [`src/core/tracy/`](../src/core/tracy) | Scopes CPU, zones GPU OpenGL, captures de frame PBO asynchrones, vérification de traces automatique via Python. |
| **Traçage d'API OpenGL (Apitrace)** | [`scripts/test_integration_apitrace.sh`](../suckless-ogl/scripts/test_integration_apitrace.sh), [`scripts/trace_analyze.py`](../suckless-ogl/scripts/trace_analyze.py) | RenderDoc (`task renderdoc`, `task renderdoc-capture`) | C11 utilise Apitrace pour l'analyse des appels GL redondants ; Odin privilégie RenderDoc CLI/GUI et Tracy. |
| **Profilage Système Avancé** | Linux `perf` basique | Intel VTune (Hotspots, Memory, Threading), Heaptrack, Callgrind | Scripts dédiés et cibles Taskfile intégrées dans Odin. Support multi-plateforme analysé dans [`docs/windows-profiling-tooling-matrix-2026-08-18.md`](windows-profiling-tooling-matrix-2026-08-18.md) et [`docs/windows-vtune-profiling-analysis-2026-08-18.md`](windows-vtune-profiling-analysis-2026-08-18.md). |

### 4.4. Garde-fous CI, Analyse Statique & Linting

| Règle / Outil | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Comparaison |
|---|---|---|---|
| **Contrôle de Style & Vet** | Clang-Tidy + Clang-Format + Ruff | Odin `-vet -strict-style -warnings-as-errors` + Ruff + Markdownlint | Vérification stricte intégrée au compilateur Odin en amont du build. |
| **Garde-fou IWYU (Include-What-You-Use)** | [`scripts/iwyu_check.sh`](../suckless-ogl/scripts/iwyu_check.sh), cible `just iwyu` | N/A (Système de packages Odin) | Les imports de packages explicites en Odin éliminent le problème d'include fan-out du C. |
| **Contrôle des suppressions NOLINT** | [`scripts/check_nolint.sh`](../suckless-ogl/scripts/check_nolint.sh) | N/A | Interdiction d'ajouter des `// NOLINT` sans justification en C11. |
| **Vérification Formelle TLA+** | — | [`verification/EnvManagerVerification.tla`](../verification/EnvManagerVerification.tla) | *(Odin+)* Modèle TLA+ prouvé par TLC + vérification CI de la synchronisation du code généré. |

### 4.5. Documentation & Déploiement Statique

| Aspect | C11 (`suckless-ogl`) | Odin (`suckless-odin`) | Comparaison |
|---|---|---|---|
| **Génération du Site de Documentation** | MkDocs Material + Doxygen ([`mkdocs.yml`](../suckless-ogl/mkdocs.yml), `docs.yml`) | Fichiers Markdown dans [`docs/`](.) | C11 dispose d'un pipeline complet déployant un site web statique sur GitHub Pages avec recherche intégrée. |
| **Contrôles d'intégrité de la documentation** | [`scripts/verify_docs.py`](../suckless-ogl/scripts/verify_docs.py), [`tests/test_docs_links.py`](../suckless-ogl/tests/test_docs_links.py), [`tests/test_mermaid_integrity.py`](../suckless-ogl/tests/test_mermaid_integrity.py) | [`scripts/verify_docs_links.py`](../scripts/verify_docs_links.py) (`task test-docs-links`, `task lint`) + Markdownlint CLI v19 | ✅ Porté : validation exhaustive de l'intégralité des 300+ liens relatifs et ancres internes en local et en CI. |

---

## 5. Raccourcis Clavier, Contrôleur Gamepad & Philosophie de Contrôle

Dans le projet C11, l'absence de GUI riche imposait plus de **67 raccourcis clavier distincts**.  
Dans le projet Odin, l'interface Dear ImGui (`F2`) expose l'intégralité des curseurs, sélecteurs et boutons de manière interactive, tout en conservant les raccourcis de navigation et le support complet des **manettes DualShock 4 / DualSense / Logitech / Xbox** (voir le guide dédié : [`docs/gamepad-controller-integration-and-usage-guide.md`](gamepad-controller-integration-and-usage-guide.md)) :

### 5.1. Clavier & Souris
| Raccourci | Action | Implémentation Odin |
|---|---|---|
| `Escape` | Quitter l'application | [`src/app/input.odin`](../src/app/input.odin) |
| `F` | Toggle plein écran | [`src/app/input.odin`](../src/app/input.odin) |
| `F1` | Cycle overlay texte FPS/Métriques (3 modes) | [`src/rendering/overlay.odin`](../src/rendering/overlay.odin) |
| `F2` | Ouvrir / Fermer l'interface Dear ImGui (libère/capture le curseur) | [`src/gui/gui.odin`](../src/gui/gui.odin) |
| `Ctrl+F` | Focus sur la barre de recherche des paramètres UI | [`src/app/input.odin`](../src/app/input.odin) |
| `W` / `A` / `S` / `D` | Déplacement horizontal de la caméra | [`src/app/input.odin`](../src/app/input.odin) |
| `Q` / `E` | Monter / Descendre la caméra | [`src/app/input.odin`](../src/app/input.odin) |
| `C` | Toggle mode caméra (curseur verrouillé/visible) | [`src/app/input.odin`](../src/app/input.odin) |
| `Space` | Réinitialiser la caméra (position, yaw, pitch) | [`src/app/input.odin`](../src/app/input.odin) |
| `Page Up` / `Page Down` | Défiler les environnements HDR (transition fluide) | [`src/scene/env_manager.odin`](../src/scene/env_manager.odin) |
| `F12` | Déclencher une capture de frame RenderDoc | [`src/app/input.odin`](../src/app/input.odin) |
| `Molette Souris` | Impulsion d'accélération dans l'axe de visée | [`src/camera/camera.odin`](../src/camera/camera.odin) |
| `Mouvement Souris` | Orientation de la vue (mouselook avec lissage) | [`src/camera/camera.odin`](../src/camera/camera.odin) |

### 5.2. Manette & Contrôleur Gamepad (DualShock 4, DualSense, Logitech, Xbox)
| Contrôle Gamepad | Action | Implémentation Odin |
|---|---|---|
| **Stick Gauche (X/Y)** | Déplacement horizontal (Strafe gauche/droite & Avancer/Reculer) | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Stick Droit (X/Y)** | Orientation caméra (Yaw & Pitch avec lissage temporel) | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Gâchettes R2 / L2** | Altitude (R2 = Monter $+Y$, L2 = Descendre $-Y$) | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Boutons R1 / L1** | Défiler les cartes HDR (R1 = Suivant, L1 = Précédent) | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Start / Options** | Ouvrir / Fermer le menu Dear ImGui | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Back / Share / Select** | Réinitialiser la position et rotation caméra | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Bouton Y / Triangle** | Cycle de l'overlay de métriques (F1) | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Bouton X / Carré** | Toggle mode caméra | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |
| **Bouton A / Croix** | Toggle mode plein écran | [`src/app/gamepad.odin`](../src/app/gamepad.odin) |

---

## 6. Synthèse de conformité & Feuille de route restante

### 6.1. Tableau de couverture globale

| Domaine | Couverture globale | Statut fonctionnel |
|---|---|---|
| **Core & Windowing** | 100% | ✅ Complet |
| **Caméra & Contrôles** | 100% | ✅ Complet (+ Gamepad DualShock/Logitech/Xbox) |
| **PBR & IBL Pipeline** | 95% | ✅ Complet (seul le slicing multi-frames temps réel diffère) |
| **Skybox & Env Manager** | 100% | ✅ Complet (+ TLA+ et SIMD HDR) |
| **Post-Processing** | 100% | ✅ Complet (+ A/B split, cache variantes, stops EV) |
| **Interface & Profilage** | 120% | ✅ Supérieur au C11 (ImGui, GPU timers, Tracy, Search, RenderDoc, ITT) |
| **Tests & Validation** | 186 tests passants | ✅ Tests unitaires, CLI, shaders et headless GPU (Xvfb) |
| **Windows & Wine Tooling** | 100% | ✅ **Complet** (cross-compilation Clang/LLD, Wine runner, 106 tests Wine, packaging `.tar.zst`/`.zip`) |
| **Écosystème Steam / Proton** | 100% | ✅ **Complet** (assets steamgrid, injection art, runner Proton) |
| **Tests de Stress Dédiés** | 100% | ✅ Complet (`test-chaos`, `stress-fullscreen` 100 cycles, `stress-envmap` 30 cycles, ASan) |
| **Documentation Statique** | 50% | 🟡 Markdown brut (manque pipeline MkDocs/Doxygen avec CI) |

---

### 6.2. Feuille de route des travaux restants

#### Priorité 1 : Écosystème Steam & Déploiement Proton (Prochaine étape majeure)
1. **Intégration Steam & Proton** :
   - Porter `run_proton.sh` (`task run-proton`) pour tester le build Windows sous Proton (Flatpak ou natif).
   - Porter `generate_steam_assets.sh` et `inject_steam_art.py` pour générer et injecter les artworks Steam (Cover, Hero, Banner, Logo, Icône).

#### Priorité 2 : Infrastructure Windows & Déploiement ✅ (COMPLÉTÉ)
- **Cross-compilation Windows dans `Taskfile.yml`** : `task build-win`, `task build-win-release`, `task build-win-ultra`.
- **Exécution et Tests sous Wine** : `task run-win`, `task run-win-release`, `task test-win` (104 tests passants).
- **Packaging & Test de distribution** : `task package-win` (`.tar.zst` et `.zip`), `task run-package-win` (test sandbox).

#### Priorité 3 : Fiabilisation & Tests de Stress ✅ (COMPLÉTÉ)
- **Stress Testing Fullscreen** : `task stress-fullscreen` (100 cycles sous Xvfb) et `task stress-fullscreen-asan` (50 cycles sans fuites ni blocages).
- **Stress Testing Async HDR** : `task stress-envmap` (30 transitions) et `task stress-envmap-sanitize` (20 transitions sans data races sous ASan).
- **Isolation Sandbox Xvfb** : Exécution isolée par défaut pour éviter tout crash de session hôte (XRandR).
- **Suppressions LSan** : Fichier [`lsan.supp`](../lsan.supp) pour éliminer les faux positifs de pilotes graphiques.

#### Priorité 3 : Documentation & Déploiement Statique
- Mettre en place un pipeline MkDocs statique pour le projet Odin avec déploiement GitHub Pages.

#### Priorité 3 : Fonctionnalités Annexes / Démos Spécifiques C11 (Optionnelles)
- **N-Body Gravity Simulation & Particle Trails** : Démo physique spécifique du repo C11.
- **Light Probes SH9 (1-bounce GI)** : Sondes harmoniques sphériques avec grille 3D.
- **GPU Bitonic Sort** : Tri billboard compute (le Radix CPU actuel en Odin effectue le tri en <0.02ms pour 100 sphères).
- **Icosphere VBO Mesh** : Maillage tessellé traditionnel (le rendu billboard analytique étant privilégié).
- **Viewer KTX Standalone** : Binaire autonome pour textures KTX2.
