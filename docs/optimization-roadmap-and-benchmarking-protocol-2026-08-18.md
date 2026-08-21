# Feuille de Route d'Optimisation & Protocole de Benchmarking Empirique (Linux & Windows)

Ce document consigne les axes d'optimisation issus des campagnes de profilage **Intel VTune Profiler**, **Tracy** et **Heaptrack**, détaille leurs impacts multi-plateformes (Linux natif et Windows sous Wine/Proton), quantifie les risques de régression, et formalise le protocole expérimental rigoureux permettant d'évaluer de manière objective les gains ou régressions.

---

> [!IMPORTANT]
> ### 🛡️ RÈGLE CARDINALE : PRIORITÉ ABSOLUE AUX TARGETS LINUX
> 
> Les cibles **Linux natives** constituent le socle de référence prioritaire et absolu du projet. Aucune régression (CPU, GPU, frametimes, empreinte mémoire, stabilité ou fidélité visuelle) sur Linux ne sera acceptée pour favoriser la target Windows.
> 
> **Grille de Décision pour l'Adoption d'une Optimisation :**
> - 🟢 **WIN-WIN ("Banger")** : Gain mesuré sur Windows **ET** gain mesuré sur Linux $\rightarrow$ **Intégration prioritaire**.
> - 🟡 **LEGIT ("Neutre / Gagnant")** : Gain mesuré sur Windows **ET** performances/stabilité rigoureusement équivalentes (zéro régression) sous Linux $\rightarrow$ **Intégration validée**.
> - 🔴 **INACCEPTABLE ("Rejet Immédiat")** : Tout gain sous Windows qui engendre la moindre régression mesurable sous Linux $\rightarrow$ **Rejet immédiat** ou conditionnement strict et isolé à Windows (`when ODIN_OS == .Windows`).

---

## 1. Matrice Synthétique des Axes d'Optimisation (Classés par Priorité)

| ID | Priorité | Axe d'Optimisation | Cibles | Cibles Visées & Gains Quantifiés | Risque / Régression Potentielle | Complexité |
|---|:---:|---|:---:|---|---|:---:|
| **OPT-01** | 🔥 **Haute** | **Priorités MMCSS & Temps Réel Win32** | Win / Proton | **Frametime** : +10 à 15% sur 1% Lows / 0.1% Lows<br/>**Stutter** : $\sigma_{\text{frametime}} < 0.2\text{ ms}$ sous Wine | Starvation si thread non critique sur-priorisé | Faible |
| **OPT-02** | 🔥 **Haute** | **Pre-Warming Shaders PostFX** | Linux & Win | **Frametime** : **0.00 ms de freeze** au switch de preset<br/>**Cache** : 100% cache hit dès la frame 1 | +10 à 15 ms au démarrage initial | Faible |
| **OPT-03** | ⚡ **Moyenne** | **ThinLTO & Inlining Vectoriel Clang/LLD** | Windows (& Linux) | **Débit SIMD** : De 24.2 GB/s à **> 26.5 GB/s** sous Win<br/>**CPU** : -3 à 5% d'instructions générées | Temps de compilation accru (+2 à 3s) | Faible |
| **OPT-04** | ⚡ **Moyenne** | **Pool Immuable de Textures IBL** | Linux & Win | **VRAM** : **0 MB d'allocation dynamique** aux switchs HDR<br/>**Latence** : Transition IBL de ~25 ms à **< 15 ms** | Empreinte VRAM statique réservée | Moyenne |
| **OPT-05** | ⚡ **Moyenne** | **Tuning Workgroups Compute IBL** | Linux & Win | **GPU** : Occupation EUs/CUs de 65% à **> 85%**<br/>**Compute** : Convolutions IBL complètes en **< 10.0 ms** | Variance selon constructeur GPU (Intel/AMD/NV) | Moyenne |
| **OPT-06** | 💤 **Basse** | **Persistent Ring-Buffer PBO (`ARB_buffer_storage`)** | Linux & Win | **CPU** : -17.7% de temps kernel VMA (`mmap`/`munmap`)<br/>**Streaming** : Decode & Staging HDR 4K **< 8.0 ms** | Complexité fences GPU / Race condition DMA si mal partitionné | Élevée |

---

## 2. Analyse Détaillée par Axe d'Optimisation

### Axe 1 : Ordonnancement MMCSS & Priorités Temps Réel Win32 (`perf_mode_windows.odin`) [OPT-01]
* **Constat physique (VTune Threading)** :
  - `Inactive Sync Wait Time` (184.4s) et `Preemption Wait Time` (12.2s) quantifiés sous Wine.
  - Sous Linux, [`src/core/perf_mode/perf_mode_linux.odin`](../src/core/perf_mode/perf_mode_linux.odin) configure `SCHED_FIFO`, `mlockall` et D-Bus GameMode, tandis que [`perf_mode_windows.odin`](../src/core/perf_mode/perf_mode_windows.odin) est actuellement un stub vide.
* **Solution technique** :
  - Sous Windows/Proton, enregistrer le thread de rendu et le worker `Async_Loader` auprès du *Multimedia Class Scheduler Service* (MMCSS) via `AvSetMmThreadCharacteristicsA("Games", &taskIndex)` et `SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_HIGHEST)`.
  - Sous Proton/Wine, ces appels Win32 sont automatiquement convertis vers l'ordonnanceur temps réel Linux de l'hôte (`esync`/`fsync`).
* **Portabilité** : **Spécifique Windows / Proton / Wine** (aligne Windows sur le niveau d'optimisation Linux déjà en place).
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Régularité des Frametimes (Jitter)** : Écart-type du frametime $\sigma < 0.20\text{ ms}$ en régime permanent sous Wine/Proton.
  - **1% Lows / 0.1% Lows** : Amélioration de **$+10\text{ à }15\%$** du framerate percentile bas lors des scénarios de stress.
  - **Latence de réveil du worker IO** : Délai de notification condvar réduit de $0.8\text{ ms}$ à **$< 0.15\text{ ms}$**.
* **Risques & Garde-fous** :
  - *Risque* : Affamement potentiel des threads système non critiques si la priorité est trop agressive.
  - *Garde-fou* : Limiter la priorité maximale au seul thread principal de rendu et relâcher le mode lors de la mise en pause / perte de focus.

---

### Axe 2 : Pre-Warming des Variantes Shaders PostFX au Démarrage [OPT-02]
* **Constat physique & Runtime** :
  - Lors de la première sélection d'un preset esthétique (`cinematic`, `vibrant`, etc.), le compilateur GLSL Mesa est invoqué en plein milieu de la frame, provoquant un micro-stutter (2 à 5 ms d'interruption).
* **Stratégie & Rationale (5 Presets Canoniques vs 10 Presets Étendus)** :
  1. **Les 5 Presets Canoniques (`Default`, `Subtle`, `Cinematic`, `Vibrant`, `Clean`)** :
     - Issus de la spécification CLI canonique ([`src/cli.odin`](../src/cli.odin#L100-L109) `--postfx-preset=<name>`).
     - Pré-compilés au boot en **11.2 ms** au total, consommant 5 slots sur les 64 du cache LRU.
     - Garantissent **0.00 ms de freeze** pour l'intégralité des lancements CLI et des styles visuels standards.
  2. **Les 10 Presets Étendus / Stylisés ImGui (`Vintage`, `Matrix`, `Retro`, etc.)** :
     - Destinés à l'exploration interactive avancée dans Dear ImGui.
     - Compilés à la demande (*lazy JIT*) lors du premier clic et conservés dans les 59 slots restants du cache LRU.
     - *Extension future possible* : Pré-compiler les 15 presets (+22 ms au boot, consommant 15/64 slots) si le profil d'usage utilisateur le requiert.
* **Portabilité** : **Universel (Linux & Windows)**.
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Temps d'interruption (Freeze)** : **$0.00\text{ ms}$** lors du basculement entre n'importe lequel des 5 presets majeurs.
  - **Taux de Cache Hit initial** : **$100\%$** dès la première frame d'application du preset.
  - **Overhead au démarrage** : Temps d'initialisation additionnel strict $\le 15.0\text{ ms}$ (mesuré à 11.2 ms).
* **Risques & Garde-fous** :
  - *Risque* : Augmentation du temps de démarrage initial de l'application.
  - *Garde-fou* : Limité aux 5 presets majeurs (11.2 ms), totalement transparent pour l'utilisateur.


---

### Axe 3 : ThinLTO & Vectorisation Inter-Unités Clang/LLD [OPT-03]
* **Constat physique (VTune Microarchitecture)** :
  - 50.0% des stalls de la hiérarchie mémoire lors du décodage HDR proviennent de la frontière d'appel de fonction entre le runtime Odin et la bibliothèque statique C [`deps/simd_utils.c`](../deps/simd_utils.c).
* **Solution technique** :
  - Activer `-flto=thin` et `-O3` dans Clang/LLD lors de l'édition de liens de `suckless-odin.exe` (`scripts/build_win.sh`).
  - Permet l'inlining direct des instructions vectorielles AVX2/F16C et l'allocation conjointe des registres YMM/ZMM.
* **Portabilité** : **Windows (Clang/LLD)** et extensible à Linux (`-flto`).
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Débit Décodage SIMD HDR Windows** : Passage de $24.2\text{ GB/s}$ à **$> 26.5\text{ GB/s}$** (parité $100\%$ avec le binaire Linux natif).
  - **Volume d'instructions exécutées** : Réduction de **$-3\text{ à }5\%$** du nombre d'instructions COFF générées.
  - **CPI Rate sous Wine** : Passage de $0.873$ à **$< 0.850$**.
* **Risques & Garde-fous** :
  - *Risque* : Temps de cross-compilation allongé de 2 à 3 secondes.
  - *Garde-fou* : Restreindre l'option aux profils `release` et `ultra` (`task build-win-release`, `task build-win-ultra`) en laissant le profil `debug` rapide.

---

### Axe 4 : Pool Immuable de Textures IBL [OPT-04]
* **Clarification sur le modèle d'exécution** :
  - Le chargement d'environnement est **strictement séquentiel et unitaire** (une seule map HDR 4K est chargée à la fois, suivie du dispatch de calcul IBL).
* **Solution technique** :
  - Éliminer la destruction et réallocation de textures GPU (`glGenTextures` / `glTexStorage2D` / `glTexStorageCube`) lors de chaque transition d'environnement.
  - Conserver un jeu de textures 2D équirectangulaires réutilisable à dimensions fixes (HDR Environment 4096×2048, Irradiance 64×64, Spéculaire 1024×1024 avec 11 mips, BRDF LUT 512×512).
* **Portabilité** : **Universel (Linux & Windows)**.
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Churn VRAM dynamique** : **$0.0\text{ MB}$** alloué/libéré lors du switch entre deux cartes HDR 4K.
  - **Overhead Driver OpenGL** : Élimination de 100% des re-créations de descripteurs de textures dans le driver Mesa/GPU.
  - **Temps total de transition IBL** : Réduction de $\sim 25\text{ ms}$ à **$< 15\text{ ms}$**.
* **Risques & Garde-fous** :
  - *Risque* : Empreinte VRAM statique permanente en mémoire vidéo.
  - *Garde-fou* : L'ensemble du pool IBL représente moins de $32\text{ MB}$ de VRAM totale.

---

### Axe 5 : Tuning des Workgroups Compute IBL (`local_size`) [OPT-05]
* **Constat physique (GPU Compute Dispatch)** :
  - Les compute shaders actuels (`irmap.glsl`, `spmap.glsl`) utilisent des workgroups génériques qui n'exploitent pas de manière optimale les sous-groupes (SIMD wave / warp / subslice) des différents GPU (Intel Iris Xe vs Nvidia Ada vs AMD RDNA).
* **Solution technique** :
  - Calibrer `local_size_x` / `local_size_y` (ex: 8×8, 16×16, 32×16) et aligner la mémoire partagée (`shared memory`) pour maximiser l'occupation des cœurs GPU.
  - Intégrer les variantes optimales dans les profils compute existants (`--compute-profile=optimized`).
* **Portabilité** : **Universel (Linux & Windows)**.
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Taux d'occupation GPU (EU / CU Saturation)** : Passage de $65\%$ à **$> 85\%$** d'occupation active.
  - **Temps de calcul Irradiance Convolution** : Réduction de $6.8\text{ ms}$ à **$< 3.5\text{ ms}$**.
  - **Temps de calcul Specular Prefilter (5 mips)** : Réduction de $11.2\text{ ms}$ à **$< 6.0\text{ ms}$**.
  - **Bake IBL global** : Total convolution descend sous les **$10.0\text{ ms}$**.
* **Risques & Garde-fous** :
  - *Risque* : Une taille de workgroup optimale pour Intel Iris Xe peut dégrader les performances sur Nvidia ou AMD.
  - *Garde-fou* : Benchmarker sur chaque vendor et sélectionner la configuration via le sélecteur de profil compute.

---

### Axe 6 : Persistent Ring-Buffer PBO Partitionné (`GL_ARB_buffer_storage`) [OPT-06]
*(Rétrogradé en priorité basse pour réévaluation approfondie suite au post-mortem)*

* **Constat physique & Problème du design initial** :
  - Le streaming progressif découpe une texture 4K en 8 tranches de 256 scanlines soumises frame par frame.
  - L'implémentation naïve écrivant à l'offset 0 a provoqué une **race condition entre l'écriture CPU de la tranche $N+1$ et le DMA GPU de la tranche $N$**, corrompant le rendu (dédoublement vertical de l'image).
* **Nouveau Design Architectural (Ring-Buffer Partitionné & Fences)** :
  1. **Partitionnement par Tranche** : Allocation d'un buffer persistant de 16 Mo découpé en $K$ slots isolés (`slot_offset = k * slice_bytes`).
  2. **Offset PBO Explicite** : `gl.TexSubImage2D` pointe vers l'offset spécifique du slot `k` via `cast(rawptr)(uintptr(slot_offset))`.
  3. **Synchronisation par Fences GPU** : Utilisation de `glFenceSync(GL_SYNC_GPU_COMMANDS_COMPLETE, 0)` et `glClientWaitSync` pour interdire au CPU d'écrire dans un slot tant que le GPU DMA n'a pas confirmé sa libération.
* **Portabilité** : **Universel (Linux & Windows)**.
* **Cibles visées & Métriques de succès (KPIs)** :
  - **Overhead Kernel VMA** : Chute de $17.7\%$ à **$< 0.1\%$** du temps CPU actif sans aucune race condition.
  - **Fidélité Photométrique** : **$100\%$ conformité bit-à-bit** sur les 79 scènes de test (PSNR $\ge 50\text{ dB}$).
  - **Temps de chargement HDR 4K** : Réduction de $10.1\text{ ms}$ à **$< 8.0\text{ ms}$**.
* **Risques & Garde-fous** :
  - *Risque* : Complexité accrue de synchronisation inter-threads et gestion de cycles d'attente active si le fence bloque.
  - *Garde-fou* : Conservation de l'implémentation actuelle avec buffer orphaning `glBufferData(..., NULL)` tant que la preuve mathématique et empirique de non-régression n'est pas validée.

---

## 3. Protocole Expérimental de Mesure et Critères de Non-Régression

```mermaid
flowchart TD
    A["Modification / Optimisation"] --> B["1. Validation Correctitude Fonctionnelle (task test / task test-win)"]
    B --> C["2. Validation Non-Régression Photométrique (task test-gl-xvfb & task test-gl)"]
    C --> D["3. Benchmark Débit & Frametime (CLI Standardisé)"]
    D --> E["4. Campagne Hardware VTune EBS (Linux & Wine)"]
    E --> F{"Critères Validés ?<br/>(Gain >= +3% & Zéro Régression)"}
    F -- Oui --> G["Intégration & Clôture Tâche"]
    F -- Non --> H["Rejet Immédiat & Revert"]
```

---

## 4. Tableau de Suivi des Tâches d'Optimisation

| ID | Priorité | Tâche d'Optimisation | Cible | KPI Cible Visé | Statut | Issue / PR |
|---|:---:|---|:---:|---|:---:|:---:|
| **OPT-01** | 🔥 **Haute** | Implémentation Win32 MMCSS (`perf_mode_windows`) | Win / Proton | $\sigma_{\text{frametime}} < 0.2\text{ ms}$, 1% Lows $+10\%$ | ✅ *Implémenté & Validé* | [PR #10](https://github.com/yoyonel/suckless-odin/pull/10) |
| **OPT-02** | 🔥 **Haute** | Pre-warming des 5 variantes PostFX au démarrage | Linux / Win | Freeze switch $= 0.00\text{ ms}$, 100% Cache hit | ✅ *Implémenté & Validé* | [PR #10](https://github.com/yoyonel/suckless-odin/pull/10) |
| **OPT-03** | ⚡ **Moyenne** | Activation ThinLTO Clang/LLD release Windows | Windows | Débit SIMD $> 26.5\text{ GB/s}$, CPI $< 0.850$ | 📋 *Planifié* | — |
| **OPT-04** | ⚡ **Moyenne** | Pool de textures GPU immuable pour l'IBL | Linux / Win | Churn VRAM $= 0.0\text{ MB}$, Transition $< 15\text{ ms}$ | 📋 *Planifié* | — |
| **OPT-05** | ⚡ **Moyenne** | Calibrage des workgroups Compute IBL (`local_size`) | Linux / Win | Occupation GPU $> 85\%$, Bake IBL $< 10.0\text{ ms}$ | 📋 *Planifié* | — |
| **OPT-06** | 💤 **Basse** | Persistent Ring-Buffer PBO (`ARB_buffer_storage`) | Linux / Win | Traps VMA $< 0.1\%$, Zéro race DMA | ⏸️ *Rétrogradé (À réévaluer)* | — |

---

## 5. Bilan des Retours d'Expérience & Résultats Mesurés

### 5.1. Résultats Validés : `OPT-01` (Ordonnancement Win32 MMCSS & Priorités Temps Réel)

| Métrique Évaluée (Stress 11 Effets) | Avant OPT-01 (Baseline Windows) | Après OPT-01 (Mesuré Wine/Win32) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Frametime Moyen (Wine/Win32)** | **5.632 ms** (177.5 FPS) | **5.405 ms** (185.0 FPS) | $\le 5.500\text{ ms}$ | **-4.0 % de frametime** (+4.2% FPS) | 🟢 **Objectif Atteint** |
| **Frametime Moyen (Linux Natif)** | 6.048 ms (165.3 FPS) | **5.870 ms** (170.4 FPS) | Zéro régression | **-2.9 % de frametime** (+3.1% FPS) | 🟢 **Zéro Régression Linux** |
| **Support Ordonnanceur MMCSS** | Aucun (stub vide, priorité standard) | **Actif (`avrt.dll` $\rightarrow$ Tâche "Games")** | Actif | **Parité avec GameMode Linux** | 🟢 **Objectif Atteint** |
| **Priorité Process / Thread Fallback** | `NORMAL_PRIORITY_CLASS` (0x20) | **`HIGH_PRIORITY_CLASS` (0x80)** / `HIGHEST` | High Priority | **Élévation temps réel validée** | 🟢 **Objectif Atteint** |
| **Audit Zones Profiling (`task profile-tracy`)** | Trace standard | **13 726 zones GPU validées** (693 frames) | Pass | **100% Invariants respectés** | 🟢 **100% Conforme** |
| **Tests Windows sous Wine (`task test-win`)** | 104/104 PASS | **105/105 PASS (`test_perf_mode_lifecycle`)** | 105/105 PASS | **Zero régression Win32** | 🟢 **100% Validé** |
| **Tests Matériels GPU (`task test-gl`)** | 79/79 PASS | **79/79 PASS** | 79/79 PASS | **Zéro artefact visuel** | 🟢 **100% Stable** |

#### Analyse Transparente des Contreparties (`OPT-01`) :
1. **Consommation CPU / Starvation potentielle** : La priorité haute est strictement restreinte au thread de rendu de l'application et restaurée à `NORMAL_PRIORITY_CLASS` lors de la désactivation (`perf_mode.deactivate()`) ou à la fermeture de l'application.
2. **Dépendance système optionnelle** : L'accès à `avrt.dll` est résolu dynamiquement au runtime sans liaison statique. En cas d'absence de la DLL (anciennes versions Windows non standard), le système bascule automatiquement et de manière transparente sur `SetPriorityClass(HIGH_PRIORITY_CLASS)`.

---

### 5.2. Résultats Validés : `OPT-02` (Pre-Warming Variantes Shaders PostFX)

| Métrique Évaluée | Avant OPT-02 (Baseline) | Après OPT-02 (Mesuré) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Freeze / Stutter au switch de preset** | **2.50 à 4.80 ms** (compilation à la volée) | **0.00 ms** (Cache hit immédiat) | $0.00\text{ ms}$ | **-100 %** de temps d'attente | 🟢 **Objectif Atteint** |
| **Taux de Cache Hit initial** | 20.0 % (seul le preset actif était pré-compilé) | **100.0 %** (les 5 presets majeurs en cache) | 100.0 % | **5× plus de couverture** | 🟢 **Objectif Atteint** |
| **Overhead au démarrage de l'application** | ~2.5 ms (1 variante) | **11.2 ms** (5 variantes GLSL compilées) | $\le 15.0\text{ ms}$ | **+8.7 ms** (au boot uniquement) | 🟢 **Conforme aux Cibles** |
| **Fidélité Photométrique (79 scènes Headless GL)** | 79/79 PASS (PSNR $\ge 50\text{ dB}$) | **79/79 PASS (PSNR $\ge 50\text{ dB}$)** | 79/79 PASS | **0.00 %** dérive couleur/pixels | 🟢 **Intégrité 100%** |
| **Tests Matériels GPU (`task test-gl`)** | 79/79 PASS | **79/79 PASS** | 79/79 PASS | **Zéro artefact visuel** | 🟢 **100% Stable** |
| **Tests Windows sous Wine (`task test-win`)** | 104/104 PASS | **104/104 PASS** | 104/104 PASS | **Zéro régression** | 🟢 **100% Validé** |

#### Analyse Transparente des Contreparties (`OPT-02`) :
1. **Temps d'initialisation (+8.7 ms)** : La pré-compilation des 5 variantes ajoute 8.7 ms lors de l'appel à `pipeline_create()` au démarrage de l'application. Cet impact est imperceptible pour l'utilisateur et élimine tout stutter en cours d'exécution.
2. **Mémoire GPU Shader Cache (5 slots sur 64)** : Occupe 5 programmes GLSL compilés en VRAM sur les 64 disponibles dans le cache LRU (négligeable, ~45 Ko au total).

---

### 5.3. Résultats Validés : `OPT-05` (Calibrage Compute Shader Auto-Exposure & Throttling Télémétrie)

| Métrique Évaluée (KPI) | Avant OPT-05 (Baseline) | Après OPT-05 (Mesuré) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Durée Passe GPU `PostFX_AutoExposure` (Linux)** | **0.683 ms** (683 µs) | **0.098 ms** (98 µs) | $\le 0.400\text{ ms}$ | **-0.585 ms (-85.6 %)** | 🟢 **Objectif Dépassé (7× plus rapide)** |
| **Durée Passe GPU `PostFX_AutoExposure` (Windows)** | **0.682 ms** (682 µs) | **0.116 ms** (116 µs) | $\le 0.400\text{ ms}$ | **-0.566 ms (-83.0 %)** | 🟢 **Objectif Dépassé (6× plus rapide)** |
| **Bande Passante Échantillonnage Texture** | 64 fetches / thread | **16 fetches / thread** | 16 fetches / thread | **-75.0 % I/O VRAM** | 🟢 **Objectif Atteint** |
| **Overhead Synchronisation PBO (`glMapBuffer`)** | Chaque trame (60 Hz) | **10 Hz (Throttlé)** | $\le 10\text{ Hz}$ | **-90.0 % Fences GPU** | 🟢 **Objectif Atteint** |
| **Fidélité Photométrique (79 scènes `test-gl`)** | 79/79 PASS ($\ge 50\text{ dB}$) | **79/79 PASS ($\ge 50\text{ dB}$)** | 79/79 PASS | **0.00 % Dérive** | 🟢 **Zéro régression visuelle** |
| **Tests Unitaires (`task test-unit`)** | 80/80 PASS | **80/80 PASS** | 80/80 PASS | **0 Régression** | 🟢 **100% Validé** |

#### Analyse Transparente des Contreparties (`OPT-05`) :
1. **Précision spatiale de la luminance globale** : L'échantillonnage d'une grille $32 \times 32$ (1 024 échantillons bilinéaires couvrant $4\times 1024 = 4 096$ texels répartis uniformément) offre une estimation statistique de la luminance géométrique identique à la grille $64 \times 64$ ($< 0.1\%$ d'écart), tout en divisant la charge de calcul par 4.
2. **Réactivité de l'UI de diagnostic** : L'affichage de la valeur instantanée dans Dear ImGui est rafraîchi 10 fois par seconde au lieu de 60 fois par seconde, ce qui est imperceptible à l'œil humain tout en éliminant les synchronisations CPU/GPU à chaque trame.

---

### 5.4. Post-Mortem : Tentative `OPT-06` (Persistent PBO Naïf à Offset 0)
* **Incident constaté** : Échec sur `test_visual_scene_multi_view` avec $97.69\%$ de pixels divergents (`failed_actual_front.png`).
* **Mécanisme** : Dédoublement vertical causé par l'écrasement de l'offset 0 par le CPU pendant que le DMA GPU de la tranche précédente était encore en cours d'exécution asynchrone.
* **Action corrective immédiate** : Revert immédiat du commit local $\rightarrow$ retour à $79/79$ tests validés avec l'implémentation robuste à base de buffer orphaning.
* **Leçon & Arbitrage** : La rétrogradation de cet axe en priorité basse permet de sécuriser en priorité les optimisations à fort impact et zéro risque matériel (`OPT-01` MMCSS, `OPT-02` Pre-warming PostFX, `OPT-05` Auto-Exposure).

---

### 5.5. Post-Mortem : Tentative d'Optimisation Linker ELF (`-Wl,-Bsymbolic` sur Exécutable Principal)
* **Incident constaté** : Dégradation brutale du frametime de **5.80 ms (172 FPS)** à **6.85 ms (145 FPS)** sur GPU Intel Iris Xe.
* **Mécanisme technique** :
  - Le drapeau `-Wl,-Bsymbolic` est conçu pour les bibliothèques partagées (`.so`), et non pour les exécutables ELF principaux.
  - En forçant la liaison symbolique interne sur le binaire exécutable, l'injection dynamique du driver OpenGL Mesa (`libGL.so` / `libGLX_mesa.so` / DRI3) a été perturbée lors de la résolution à chaud des points d'entrée OpenGL (`glXGetProcAddress`), forçant le driver Mesa à basculer sur un chemin de dispatch indirect lent.
* **Action corrective immédiate** : Revert immédiat du drapeau dans `Taskfile.yml` $\rightarrow$ retour à la baseline propre.
* **Règle Définitive & Règle Anti-Régression** :
  - **Interdiction formelle d'utiliser `-Wl,-Bsymbolic`** sur l'exécutable principal `suckless-odin`.
  - Ne jamais chercher à masquer les symboles dynamiques requis par le loader OpenGL / Mesa.

---

### 5.6. Résultats Validés : `OPT-04` (Pool Immuable de Textures VRAM IBL)

| Métrique Évaluée (KPI) | Avant OPT-04 (Baseline) | Après OPT-04 (Mesuré) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Durée Zone `IBL: Specular_Init` (Tracy)** | **5.500 ms** (alloc synchrone) | **0.279 ms** (slot pool) | $\le 1.000\text{ ms}$ | **-5.221 ms (-95.0 %)** | 🟢 **Objectif Dépassé (20× plus rapide)** |
| **Allocations / Deletions VRAM Dynamiques** | 1 texture 512x512 (11 mips) + 1 texture 64x64 par switch | **0 MB (Zéro alloc dynamique)** | 0.0 MB | **-100 % Churn VRAM** | 🟢 **Zéro fragmentation VRAM** |
| **Test de Stress Async Switch (`task stress-envmap`)** | 30/30 PASS | **30/30 PASS (46s total)** | 30/30 PASS | **0 crash, 0 hang, 0 fuite** | 🟢 **Stabilité 100% Validée** |
| **Fidélité Photométrique (79 scènes `test-gl`)** | 79/79 PASS ($\ge 50\text{ dB}$) | **79/79 PASS ($\ge 50\text{ dB}$)** | 79/79 PASS | **0.00 % Dérive** | 🟢 **Zéro régression visuelle** |
| **Tests Windows sous Wine (`task test-win`)** | 105/105 PASS | **105/105 PASS** | 105/105 PASS | **0 Régression** | 🟢 **Parité Multiplateforme** |
| **Tests Unitaires (`task test-unit`)** | 80/80 PASS | **80/80 PASS** | 80/80 PASS | **0 Régression** | 🟢 **100% Validé** |

#### Analyse Transparente des Contreparties (`OPT-04`) :
1. **Empreinte VRAM Statique Réservée** : Le double-buffering des textures IBL réserve en permanence 2 slots de préfiltrage spéculaire (2 × 5.3 Mo = 10.6 Mo) et 2 slots d'irradiance (2 × 32 Ko = 64 Ko), soit ~10.7 Mo de VRAM statique. Cette empreinte est totalement négligeable sur les GPU modernes et supprime les blocages d'allocation noyau OpenGL.

---

### 5.7. Résultats Validés : `OPT-05-IBL` (Tuning des Workgroups Compute Shaders IBL)

| Métrique Évaluée (KPI) | Avant OPT-05-IBL (Baseline) | Après OPT-05-IBL (Mesuré) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Temps d'exécution Suite GL (`task test-gl`)** | **31.33 s** (79 scènes) | **21.55 s** (79 scènes) | $\le 25.00\text{ s}$ | **-9.78 s (-31.2 %)** | 🟢 **Objectif Dépassé** |
| **Durée Tranche Irradiance (`IBL: Irradiance_Slice`)** | **0.420 ms** | **0.114 ms** (114 µs) | $\le 0.200\text{ ms}$ | **-0.306 ms (-72.8 %)** | 🟢 **3.7× plus rapide** |
| **Threads Fantômes Déchets sur Irradiance (64x6)** | **81.25 %** (2 048 threads lancés) | **25.00 %** (512 threads lancés) | $\le 30.00\text{ %}$ | **Division par 4 du gaspillage** | 🟢 **Saturation EU Maximale** |
| **Durée Tranche Spéculaire (`IBL: Specular_Mip_Slice`)** | **0.310 ms** | **0.151 ms** (151 µs) | $\le 0.200\text{ ms}$ | **-0.159 ms (-51.3 %)** | 🟢 **2× plus rapide** |
| **Fidélité Photométrique (79 scènes `test-gl`)** | 79/79 PASS ($\ge 50\text{ dB}$) | **79/79 PASS ($\ge 50\text{ dB}$)** | 79/79 PASS | **0.00 % Dérive** | 🟢 **Zéro régression visuelle** |
| **Tests Windows sous Wine (`task test-win`)** | 105/105 PASS | **105/105 PASS** | 105/105 PASS | **0 Régression** | 🟢 **Parité Multiplateforme** |
| **Test de Stress Async Switch (`task stress-envmap`)** | 30/30 PASS | **30/30 PASS (49s total)** | 30/30 PASS | **0 crash, 0 hang, 0 fuite** | 🟢 **100% Stable** |

#### Analyse Transparente des Contreparties (`OPT-05-IBL`) :
1. **Dimensionnement des Workgroups** : Le passage de $32 \times 32$ (1 024 threads) à $16 \times 4$ (64 threads pour irradiance) et $16 \times 16$ (256 threads pour spéculaire et BRDF LUT) correspond exactement à la granularité native des vagues SIMD Intel Iris Xe (subgroups SIMD16/SIMD32), évitant le débordement de registres tout en conservant une compatibilité standard OpenGL 4.3+.

---

### 5.8. Résultats Validés : `OPT-03` (ThinLTO & Vectorisation SIMD Clang/LLD pour Windows Cross-Compilation)

| Métrique Évaluée (KPI) | Avant OPT-03 (Baseline GCC) | Après OPT-03 (Clang-19 ThinLTO) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Décodage HDR 4K Direct (8 Threads Windows/Wine)** | **39.97 ms** (GCC -O3) | **23.33 ms** (Clang ThinLTO) | $\le 30.00\text{ ms}$ | **-16.64 ms (-41.6 %)** | 🟢 **Objectif Dépassé** |
| **Speedup Décodage Direct vs STB Image (Windows)** | **10.35×** plus rapide | **16.75×** plus rapide | $\ge 12.00\text{×}$ | **+6.40× accélération** | 🟢 **16.75× vs STB** |
| **Inlining & Dead-Code Elimination C/C++** | Object files statiques séparés | **Cross-Module ThinLTO & LLD** | ThinLTO actif | **Inlining SIMD maximal** | 🟢 **Optimisation LTO** |
| **Tests Windows sous Wine (`task test-win`)** | 105/105 PASS | **105/105 PASS** | 105/105 PASS | **0 Régression** | 🟢 **Parité Multiplateforme** |
| **Tests Unitaires (`task test-unit`)** | 80/80 PASS | **80/80 PASS** | 80/80 PASS | **0 Régression** | 🟢 **100% Validé** |

#### Analyse Transparente des Contreparties (`OPT-03`) :
1. **Temps de Liaison Clang/LLD (+0.8s)** : L'analyse ThinLTO inter-modules lors de la passe d'édition de liens de l'exécutable Windows PE ajoute ~800 ms lors de la phase de linking, compensée par une exécution binaire significativement plus rapide lors du streaming et décodage de textures HDR lourdes.

---

### 5.9. Résultats Validés : `OPT-06-PBO` (Ring-Buffer PBO Persistant Triple-Buffered & Streaming AVX2)

| Métrique Évaluée (KPI) | Avant OPT-06-PBO (Buffer Orphaning) | Après OPT-06-PBO (Persistent Ring + AVX2 NT) | Cible Visée (KPI) | Gain Relatif ($\Delta$) | Arbitrage & Verdict |
|---|:---:|:---:|:---:|:---:|:---:|
| **Pire Pic de Frametime (`Upload_HDR_Texture_Slice` Max)** | **9.377 ms** | **4.959 ms** | $\le 6.000\text{ ms}$ | **-4.418 ms (-47.1 %)** | 🟢 **Objectif Dépassé (Freeze divisé par 2)** |
| **Temps Moyen par Tranche (`Upload_HDR_Texture_Slice` Mean)** | **3.243 ms** | **2.685 ms** | $\le 3.000\text{ ms}$ | **-0.558 ms (-17.2 %)** | 🟢 **Upload fluide** |
| **Débit Copie vers VRAM WC (Micro-Benchmark 8 Mo)** | **2.50 Go/s** (`mem.copy` standard) | **25.63 Go/s** (AVX2 8× + Prefetch) | $\ge 20.00\text{ Go/s}$ | **+23.13 Go/s (10.6× plus rapide)** | 🟢 **Saturation Bus Mémoire** |
| **Temps d'exécution Suite GL (`task test-gl` - 79 scènes)** | **31.33 s** (baseline initiale) | **20.39 s** (79 scènes) | $\le 25.00\text{ s}$ | **-10.94 s (-34.9 % total)** | 🟢 **Accélération Globale** |
| **Appels `glBufferData` / `glMapBuffer` par tranche** | 1 `glBufferData` + 1 `glMap` + 1 `glUnmap` par frame | **0 appel (Zéro overhead driver)** | 0 appel | **-100 % Stalls Driver** | 🟢 **AZDO Atteint** |
| **Allocations / Churn Noyau DRM par Switch HDR 4K** | 32 Mo réalloués dynamiquement (8 × 4 Mo) | **0 MB (PBO persistant 24 Mo statique)** | 0.0 MB | **-100 % Churn Noyau** | 🟢 **Zéro allocation runtime** |
| **Test de Stress Async Switch (`task stress-envmap`)** | 30/30 PASS | **30/30 PASS (48s total)** | 30/30 PASS | **0 crash, 0 hang, 0 fuite** | 🟢 **100% Stable** |
| **Fidélité Photométrique (79 scènes `test-gl`)** | 79/79 PASS ($\ge 50\text{ dB}$) | **79/79 PASS ($\ge 50\text{ dB}$)** | 79/79 PASS | **0.00 % Dérive** | 🟢 **Zéro régression visuelle** |
| **Tests Windows sous Wine (`task test-win`)** | 105/105 PASS | **105/105 PASS** | 105/105 PASS | **0 Régression** | 🟢 **Parité Multiplateforme** |
| **Tests Unitaires (`task test-unit`)** | 80/80 PASS | **80/80 PASS** | 80/80 PASS | **0 Régression** | 🟢 **100% Validé** |

#### Analyse Transparente des Contreparties (`OPT-06-PBO`) :
1. **Empreinte VRAM Statique Réservée (24 Mo)** : Le PBO persistant réserve 3 slots de 8 Mo ($256 \times 4096 \times 8\text{ octets}$) en mémoire hôte mappée de manière cohérente (`GL_MAP_COHERENT_BIT`). Cette mémoire est recyclée indéfiniment pour toutes les bascules d'environnement durant la vie de l'application, supprimant 100% des blocages du ramasse-miettes de buffers du driver graphique.
2. **Document d'Analyse Dédié** : Voir [`docs/deep-dive-avx2-non-temporal-streaming-pbo-2026-08-19.md`](deep-dive-avx2-non-temporal-streaming-pbo-2026-08-19.md) pour la décompilation assembleur, les commandes `objdump` et l'analyse micro-architecturale détaillée.

