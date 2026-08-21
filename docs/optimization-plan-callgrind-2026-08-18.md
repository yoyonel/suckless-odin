# Plans d'Optimisation Profiling Callgrind & Valgrind

**Date :** 2026-08-18  
**Statut :** Planifié / En cours  
**Contexte :** Optimisations guidées par le profiling Callgrind (`task profile-callgrind`), Heaptrack et Valgrind sur `suckless-odin`.

---

## 1. Métriques de Référence (Baseline Callgrind)

Profil capturé sur session interactive normalisée (initialisation + cycle HDR x2 + mouvement caméra) :
* **Total Instructions CPU (`Ir`)** : 1,759,368,117 (100.0%)
* **Top Hotspots identifiés** :
  1. `decode_scanline_slice` : **681.87 M Ir (38.76%)** (Décodage Radiance HDR RLE)
  2. `__memset_avx2_unaligned_erms` : **79.89 M Ir (4.54%)** (Micro-runs RLE dans la libc)
  3. `libgallium / libGLX_mesa` : **109.04 M Ir (6.20%)** (Mesa LLVMpipe driver)
  4. `fast_hdr_decode_fp16_threaded` : **43.52 M Ir (2.47%)** (Thread orchestration)
  5. `__memcpy_avx_unaligned_erms` : **39.45 M Ir (2.24%)** (Micro-runs raw dans la libc)
  6. `overlay::append_text_vertices` : **16.16 M Ir (0.92%)** (Tessellation texte à chaque frame)
  7. `_int_malloc` / `free` : **29.91 M Ir (1.70%)** (Allocations mémoire transitoires)

---

## 2. Plans Détaillés par Piste d'Amélioration

---

### 🎯 Plan A : Turbo-Inlining RLE & Vectorisation Pure FP16

* **Fichier cible** : [`deps/simd_utils.c`](../deps/simd_utils.c)
* **Composant** : Décodeur Radiance RGBE 4K multi-threadé (`decode_scanline_slice`).

#### 1. Description Technique & Modifications
1. **Inlining des micro-runs RLE (`memset` / `memcpy` inline)** :
   * Remplacer les appels `memset(chan + x, val, run)` par des écritures inlinées 64-bit (`uint64_t v64 = val * 0x0101010101010101ULL;`) pour les paquets $\ge 8$ octets et terminaison scalaire.
   * Remplacer les appels `memcpy(chan + x, ptr, run)` par des transferts 128-bit `_mm_loadu_si128` / `_mm_storeu_si128` pour les paquets $\ge 16$ octets, 64-bit pour $\ge 8$, et terminaison scalaire.
   * Élimine l'overhead des prologues/épilogues PLT libc sur 33.5M de micro-runs par image 4K.
2. **Suppression du tableau intermédiaire pile & Vectorisation directe** :
   * Supprimer le buffer scalaire temporaire `float f_rgba[32]` sur la pile (responsable de pénalités *Store-to-Load Forwarding*).
   * Charger directement les 8 octets R, G, B, E dans des registres XMM vectoriels.
   * Déballer en float 32-bit via `_mm256_cvtepu8_epi32` + `_mm256_cvtepi32_ps`.
   * Multiplier par l'exposant vectorisé et entrelacer RGBA directement dans les registres YMM via `_mm256_unpacklo_ps` / `_mm256_unpackhi_ps` avant `_mm256_cvtps_ph` et streaming stores `_mm_stream_si128`.

#### 2. Risques de Régressions & Mitigations
* **Risque 1 (Buffer Overflow)** : Écritures 64-bit / 128-bit non alignées au-delà de la scanline (`scanline_channels[4]` de 8192 octets).
  * *Mitigation* : Garde stricte `x + run <= w` et fallback octet par octet pour les queues $< 8$ octets.
* **Risque 2 (Corrupteur de données / Décalage de canaux)** : Mauvais entrelacement SIMD des canaux R, G, B, E $\rightarrow$ distorsion de couleurs ou NaN/Inf.
  * *Mitigation* : Validation bit-à-bit stricte avec les tests unitaires et décodeur de référence.

#### 3. Gains Espérés
* **Suppression des appels PLT/libc `memset`/`memcpy`** : Économie de **~120 millions d'instructions CPU**.
* **Suppression des stalls STLF** : Réduction de `decode_scanline_slice` de **681M à < 400M Ir** (~40% de gain).
* **Temps de décodage HDR 4K** : Réduction estimée de **~15 ms à ~8-10 ms**.

#### 4. Protocole Anti-Régression
```bash
task test-simd          # Validation unitaire bit-for-bit (scalar vs multi-threaded SIMD)
task valgrind-xvfb      # Vérification mémoire Memcheck (0 invalid read/write, 0 leak)
```

#### 5. Protocole d'Évaluation des Gains
```bash
task profile-callgrind  # Chute du total Ir et disparition de memset/memcpy du TOP 5
task profile-tracy      # Réduction de la durée 'Async Loader: Decode File'
```

---

### 🎯 Plan B : Caching des Uniforms & Dirty-Checking Text Overlay

* **Fichier cible** : [`src/rendering/overlay.odin`](../src/rendering/overlay.odin)
* **Composant** : Rendu de l'overlay texte de debug / HUD (`overlay_render`, `append_text_vertices`).

#### 1. Description Technique & Modifications
1. **Caching des Uniform Locations (`loc_projection`, `loc_atlas`)** :
   * Ajouter `loc_projection: i32` et `loc_atlas: i32` dans la structure `Text_Overlay`.
   * Résoudre les emplacements une seule fois dans `overlay_init()` au lieu d'appeler `gl.GetUniformLocation` 2 fois par frame avec des chaînes C.
2. **Dirty-Checking & Mise en cache du Vertex Buffer (VBO)** :
   * Mémoriser l'état affiché (`last_cam_pos`, `last_cam_yaw`, `last_cam_pitch`, `last_fps`, `last_hdr_index`).
   * Si les métriques affichées sont inchangées par rapport à la frame précédente $\rightarrow$ sauter la tessellation STB (`append_text_vertices`) et le transfert `glBufferSubData()`.
   * Exécuter directement `gl.DrawArrays()` sur le VBO déjà présent sur le GPU.

#### 2. Risques de Régressions & Mitigations
* **Risque 1 (Affichage gelé / Stale Text)** : Le dirty-check omet une variable $\rightarrow$ texte désynchronisé.
  * *Mitigation* : Dirty-check exhaustif comparant position, orientation, mode d'overlay et valeur FPS arrondie.
* **Risque 2 (Emplacement uniform invalide)** : Mauvaise location lors du rechargement à chaud des shaders.
  * *Mitigation* : Assertions `assert(loc >= 0)` en mode debug.

#### 3. Gains Espérés
* **Élimination des requêtes OpenGL par frame** : ~1200 appels `glGetUniformLocation`/s évités.
* **Élimination de la tessellation CPU redondante** : Économie de **~16 millions d'instructions CPU** (`append_text_vertices`) sur 99% des frames statiques.
* **Réduction du trafic PCIe** : 0 transfert de buffer de sommets vers la VRAM sur les frames immobiles.

#### 4. Protocole Anti-Régression
```bash
task test-integration-xvfb  # Validation du cycle de vie complet en rendu headless
task test-gl-regression     # Validation de non-régression visuelle du framebuffer
```

#### 5. Protocole d'Évaluation des Gains
```bash
task profile-callgrind      # Baisse de rendering::[overlay.odin]::append_text_vertices
task bench-render           # Mesure du gain sur le frame time moyen et framerate
```

## 3. Bilan des Résultats : Espéré vs. Constaté

### 📊 Bilan Plan A : `deps/simd_utils.c`

| Métrique / Objectif | Gain Espéré (Cible) | Avant Plan A | Après Plan A | Gain Réel | Verdict |
|---|---|---|---|---|---|
| **`decode_scanline_slice` (Ir)** | Réduction **681M $\rightarrow$ < 400M** (-40%) | 681,870,570 Ir | 379,791,128 Ir | **-302.08 M Ir (-44.3%)** | 🟢 **Dépassé** |
| **Total Programme (Ir)** | Économie de **~270M à 300M Ir** | 1,759,368,117 Ir | 1,431,834,025 Ir | **-327.53 M Ir (-18.6%)** | 🟢 **Dépassé** |
| **Temps décodage HDR 4K (8 threads)** | Fourchette cible **8.0 - 10.0 ms** | 9.47 ms | 8.88 ms | **-0.59 ms (+6.2% débit)** | 🟢 **Atteint** |
| **Speedup vs STB `loadf`** | > 10x | 10.17x | 12.45x | **+2.28x plus rapide** | 🟢 **Dépassé** |
| **Sécurité mémoire & parité** | 0 mismatch bit-à-bit, 0 erreur Valgrind | 79/79 tests OK | 79/79 tests OK | **0 mismatch, 0 leak** | 🟢 **Validé** |

### 📊 Bilan Plan B : `src/rendering/overlay.odin`

| Métrique / Objectif | Gain Espéré (Cible) | Avant Plan B | Après Plan B | Gain Réel | Verdict |
|---|---|---|---|---|---|
| **`append_text_vertices` (Ir)** | Élimination de la tessellation (~16M Ir) | 14,991,845 Ir | < 1,000,000 Ir *(Sorti du TOP 15)* | **~ -14.0 M Ir (-93%)** | 🟢 **Dépassé** |
| **Total Programme (Ir)** | Baisse du total d'instructions | 1,431,834,025 Ir | 1,382,264,171 Ir | **-49.57 M Ir (-3.5%)** | 🟢 **Atteint** |
| **Lookups Uniforms OpenGL** | 0 `glGetUniformLocation` par frame | 2 lookups / frame | 0 lookup / frame *(au init)* | **-100% de coût chaîne GL** | 🟢 **Atteint** |
| **Trafic PCIe VBO** | 0 upload VBO si texte statique | `glBufferSubData` / frame | 0 upload / frame statique | **-100% bande passante VBO** | 🟢 **Atteint** |
| **Non-régression visuelle & E2E** | 225 frames rendues sans deadlock | 225 frames | 225 frames | **Scénario validé** | 🟢 **Validé** |

---

### 🏆 Synthèse Globale Cumulée (Plans A + B)

* **Instructions CPU totales (`Ir`)** : **1,759,368,117 $\rightarrow$ 1,382,264,171** (**-377.10 Millions Ir / -21.4% d'instructions CPU économisées**).

---

## 4. Matrice de Suivi d'Exécution

| Piste | Description | Statut | Synthèse des Gains | Non-Régression |
|---|---|---|---|---|
| **Plan A** | Inlining RLE & Vectorisation pure FP16 (`simd_utils.c`) | 🟢 **Complété** | **-302.08 M Ir (-44.3%)** sur scanlines<br>**-327.53 M Ir (-18.6%)** global | ✅ `task test-unit` (79/79)<br>✅ `task valgrind-xvfb` (0 err) |
| **Plan B** | Caching Uniforms & Dirty-Check VBO (`overlay.odin`) | 🟢 **Complété** | **-14.0 M Ir (-93%)** sur overlay<br>**-49.57 M Ir (-3.5%)** global | ✅ `task test-integration-xvfb`<br>✅ `task test-unit` (79/79) |



