# Plans Détaillés d'Optimisations — Sprint 5 & Au-Delà (Intel VTune Profiler)

**Date de rédaction** : 17 Août 2026  
**Branche** : `perf/vtune-optimizations`  
**Outils d'Analyse** : Intel VTune Profiler 2026.4 (CPU Hotspots, Memory Access, Threading & Locks), Tracy Profiler v0.13.1, RenderDoc.

---

## 1. Contexte & Problématique d'Équilibre Global des Performances

L'optimisation d'un moteur de rendu 3D haute performance exige une vision systémique rigoureuse : **toute optimisation visant un secteur matériel (CPU, GPU, RAM, VRAM, Bus PCIe) ne doit en aucun cas dégrader un autre secteur par effet de vase communicant** (transfert de coût).

### Bilan Post-Sprint 4
* **CPU Session** : Réduit de **7.462s à 4.420s (-40.8%)**.
* **Store Bound Stalls** : Réduit de **29.8% à 3.5% (-88.3%)**.
* **DRAM Bandwidth Stalls** : Réduit de **40.6% à 2.9% (-92.9%)**.
* **Décodage HDR 4K** : Réduit de **206.18ms à 10.68ms (19.3x plus rapide)**.
* **Goulots Résiduels Identifiés sous VTune** :
  1. `libgallium` (24.7% CPU Hotspots) : validation driver des buffers de sommets/instances.
  2. `DRAM Bound: 44.3%` sur P-core : transfert de textures FBO PostFX haute résolution (64 bpp).
  3. `libGLX_mesa` (9.3% CPU) : synchronisations de swap buffers et clôtures.

---

## 2. Étude Détaillée des 4 Pistes d'Optimisation

---

### 🚀 Piste A : Formats de Textures Haute Efficacité (`GL_R11F_G11F_B10F`)

#### A. Description & Mécanisme Technique
Remplacer le format de texture intermédiaire `GL_RGBA16F` (64 bits par pixel, 4 composantes FP16) par `GL_R11F_G11F_B10F` (32 bits par pixel, 3 composantes FP11/10 sans alpha) sur les cibles de rendu intermédiaires du pipeline PostFX (`scene_color_tex`, `fxaa_tex`, passes Bloom et filtres de post-traitement).

#### B. Gains Espérés
* **Bande Passante Mémoire DRAM / VRAM** : **-50% de débit binaire** lors de l'écriture MRT du shader PBR et de la lecture dans la passe PostFX Composite (de 8 octets/pixel à 4 octets/pixel).
* **Densité de Cache L3/L2 GPU & CPU** : 2x plus de texels par ligne de cache de 64 octets (16 pixels packés au lieu de 8 pixels).
* **Empreinte VRAM** : Division par 2 de la mémoire allouée pour les framebuffers couleur (ex: à 1920x1080, de 16.6 Mo à 8.3 Mo par FBO).
* **Impact VTune Memory Access** : Baisse attendue du `DRAM Bound` de **44.3% à < 20%**.

#### C. Risques Encourus & Effets de Bord Négatifs Possibles
1. **Perte du Canal Alpha** :
   * *Risque* : Si une passe PostFX ou un shader dépend du canal Alpha de `scene_color_tex`.
   * *Analyse Code* : Dans `suckless-odin`, les vecteurs de mouvement sont déjà isolés sur un MRT dédié (`velocity_tex` RG16F) et la profondeur sur `depth_tex` (DEPTH24_STENCIL8). Le canal Alpha de la scène n'est pas utilisé pour des données críticas.
2. **Précision Numérique & Gamut HDR** :
   * *Risque* : R11G11B10F dispose de 6 bits de mantisse pour R/G et 5 bits pour B (contre 10 bits pour FP16). Risque théorique de banding sur les gradients très sombres.
   * *Analyse* : Le format R11G11B10F est le standard de l'industrie (utilisé dans `suckless-vulkan`, Frostbite, Unreal Engine 5) et couvre un range dynamique $> 65000.0$ sans artefact visible grâce au dithering de tonemapping.

#### D. Garde-fous & Mesures Anti-Transfert de Coût
* **Maintien strict de `velocity_tex` en `RG16F`** : Le calcul de vélocité sub-pixel nécessite une mantisse haute précision et des nombres négatifs signés.
* **Validation de Non-Régression Visuelle** : Comparaison pixel-perfect et calcul de SSIM/PSNR via `tests/gl/test_visual_regression.odin`.
* **Mesure du Framerate & Timers GPU Tracy** : Vérifier que l'unité de filtrage texture de l'iGPU Intel Iris Xe ne subit aucun ralentissement.

#### E. Protocole d'Évaluation & Critères Go / No-Go
* **Métrique Primaire** : VTune Memory Access `DRAM Bound (% Clockticks)` $\rightarrow$ Cible : $< 20.0\%$.
* **Métrique Secondaire** : Durée GPU de la passe `PostFX_Composite` (Tracy GPU) $\rightarrow$ Cible : réduction de $\ge 25\%$.
* **Critère No-Go** : Divergence visuelle $> 0.05\%$ sur les 6 caméras cardinales de test.

---

### 🚀 Piste B : Buffers Persistants Mappés AZDO (*Approaching Zero Driver Overhead*)

#### A. Description & Mécanisme Technique
Dans [`src/rendering/instanced.odin`](../src/rendering/instanced.odin), remplacer la gestion de buffer dynamique standard (`glBufferData` / `glBufferSubData`) par un stockage immuable `glBufferStorage` doté des drapeaux `GL_MAP_WRITE_BIT | GL_MAP_PERSISTENT_BIT | GL_MAP_COHERENT_BIT`.  
Le buffer est partitionné en 3 tranches (Triple-Buffering) et le CPU écrit directement dans la tranche active via son pointeur mémoire permanent sans aucun appel système ni re-binding OpenGL par frame.

#### B. Gains Espérés
* **Overhead Driver OpenGL (`libgallium`)** : Suppression complète des allocations de bounce buffers temporaires et des copies mémoire internes dans le driver Mesa.
* **Hotspots CPU** : Réduction attendue de **15% à 20% du temps CPU dans `func@0x3dbc70` (Gallium)**.
* **Élimination des Pipeline Stalls** : Zéro attente CPU lorsque le CPU soumet de nouvelles transformations d'instances.

#### C. Risques Encourus & Effets de Bord Négatifs Possibles
1. **Pénalité de Lecture CPU sur Mémoire Write-Combining (WC)** :
   * *Risque* : La mémoire mappée persistante GPU est configurée en Write-Combining. Toute opération de **lecture (read)** par le CPU sur ce pointeur provoque un effondrement des performances CPU (stalls de 100 à 200 cycles).
   * *Parade* : Le CPU doit écrire en flux continu sans jamais relire le buffer mappé (`write-only streaming`).
2. **Data Hazard CPU-GPU (Écriture concurrente)** :
   * *Risque* : Si le CPU écrit dans la tranche $k$ pendant que le GPU lit encore la tranche $k$ de la frame précédente, il y aura corruption visuelle ou scintillement.
   * *Parade* : Utilisation d'un ring de 3 tranches synchronisé par des clôtures non-bloquantes `glFenceSync`.
3. **Compatibilité Matérielle** :
   * *Risque* : Nécessite OpenGL 4.4+ (`GL_ARB_buffer_storage`).
   * *Parade* : Le projet cible déjà OpenGL 4.6 Core Profile ; un fallback automatique vers `glBufferSubData` sera maintenu.

#### D. Garde-fous & Mesures Anti-Transfert de Coût
* **Alignement Strict sur 64 Octets** : Les tranches du buffer persistant doivent être alignées sur la taille d'une ligne de cache CPU (`64 bytes`) pour éviter le *false sharing*.
* **Validation Mémoire** : Exécution sous AddressSanitizer et Valgrind pour vérifier l'absence d'out-of-bounds sur le pointeur persistant.

#### E. Protocole d'Évaluation & Critères Go / No-Go
* **Métrique Primaire** : Temps CPU `libgallium` sous VTune CPU Hotspots $\rightarrow$ Cible : passage de 1.09s à $< 0.85\text{s}$.
* **Métrique Secondaire** : Durée de `scene_render_spheres` dans Tracy CPU/GPU zones $\rightarrow$ Cible : $< 0.05\text{ ms}$.
* **Critère No-Go** : Toute augmentation du temps GPU dans Tracy ou détection d'attente bloquante CPU.

---

### 🚀 Piste C : Optimisation Workgroups & Importance Sampling IBL GPU

#### A. Description & Mécanisme Technique
Dans [`shaders/IBL/spmap.glsl`](../shaders/IBL/spmap.glsl) (filtrage spéculaire GGX) et [`shaders/IBL/irmap.glsl`](../shaders/IBL/irmap.glsl) (irradiance diffuse) :
1. **Pré-calcul de la séquence de Hammersley** : Remplacer l'inversion de bits bit-par-bit `bitfieldReverse` exécutée dynamiquement pour chaque échantillon dans le shader par une table de constantes stockée en mémoire partagée (`shared memory`) ou dans un UBO invariant.
2. **Calibration des Tailles de Workgroups** : Adapter `local_size_x` et `local_size_y` (ex: `16x16` = 256 threads ou `8x8` = 64 threads) pour maximiser l'occupation des Execution Units (EU) de l'architecture graphique Intel Xe (SIMD8/SIMD16).

#### B. Gains Espérés
* **Temps de Calcul Total IBL GPU** : Réduction du temps de bake de **210 ms à < 120 ms**.
* **Fluidité par Tranche Interactive** : Réduction de la durée de chaque tranche spéculaire de **14 ms à < 5 ms GPU**, garantissant une cadence 60 FPS ininterrompue même pendant les régénérations d'environnement complexes.

#### C. Risques Encourus & Effets de Bord Négatifs Possibles
1. **Pression sur les Registres VGPR (Register Spilling)** :
   * *Risque* : Une taille de workgroup mal dimensionnée peut forcer le compilateur de shaders Mesa à déverser les registres dans la mémoire cache locale (scratch memory), dégradant les performances GPU.
   * *Parade* : Profilage des shaders avec `intel_gpu_top` et compilation hors-ligne via `glslangValidator`.
2. **Divergence de Calcul IBL** :
   * *Risque* : Modification de l'intégrale Monte-Carlo GGX entraînant une différence de rugosité spéculaire par rapport à la référence.
   * *Parade* : Maintien du nombre d'échantillons à 1024 et validation bit-à-bit sur les textures résultantes.

#### D. Garde-fous & Mesures Anti-Transfert de Coût
* **Vérification de Parité Visuelle** : Comparaison stricte des maps IBL générées avec la baseline via le test de régression visuelle.
* **Aucun Surcoût CPU** : Le précalcul Hammersley est invariant et généré une seule fois à l'initialisation du moteur.

#### E. Protocole d'Évaluation & Critères Go / No-Go
* **Métrique Primaire** : Log `suckless-odin.ibl : IBL environment ready in X.XX ms` $\rightarrow$ Cible : $< 120\text{ ms}$.
* **Métrique Secondaire** : Durée GPU de la zone Tracy `IBL_Specular_Pass` $\rightarrow$ Cible : réduction de $\ge 40\%$.

---

### 🚀 Piste D : PBO Readback Triple-Buffering pour Télémetrie / Tracy

#### A. Description & Mécanisme Technique
Remplacer le Pixel Buffer Object (PBO) unique utilisé pour les captures de miniatures Tracy et les calculs de luminance automatique par un anneau circulaire de 3 PBOs géré de manière asynchrone avec des clôtures OpenGL (`glFenceSync` / `glClientWaitSync`).  
La frame $N$ lit le résultat de la frame $N-2$, garantissant que le transfert DMA asynchrone depuis la VRAM vers la RAM hôte est 100% achevé sans aucun blocage du pipeline GPU.

#### B. Gains Espérés
* **Élimination Totale des Sync Stalls** : Suppression de tout appel bloquant `glReadPixels` ou `glGetTexImage` dans le thread de rendu principal.
* **Fluidité Maximale** : Frametime stable sans pic de latence (frametime jitter) lors de l'activation du profiling Tracy.

#### C. Risques Encourus & Effets de Bord Négatifs Possibles
1. **Latence de Retour d'Information (2 Frames de Décalage)** :
   * *Risque* : Le calcul de la luminance automatique (Auto-Exposure) reçoit la moyenne d'exposition avec 2 frames de décalage (~33 ms).
   * *Analyse* : L'adaptation temporelle de l'œil humain (*Eye Adaptation Speed*) utilise déjà une interpolation exponentielle sur plusieurs centaines de millisecondes ; un décalage de 33 ms est totalement invisible et mathématiquement négligeable.
2. **Consommation Mémoire** :
   * *Risque* : Allocation de 3 buffers au lieu d'un.
   * *Analyse* : Pour une miniature Tracy de $160 \times 120$ en RGBA8, la mémoire totale est de $3 \times 76.8\text{ Ko} = 230\text{ Ko}$ (impact nul sur la RAM).

#### D. Garde-fous & Mesures Anti-Transfert de Coût
* **Clôtures Non-Bloquantes** : Appel systématique de `glClientWaitSync` avec un timeout de 0 ns. Si la clôture n'est pas encore signalée, la frame en cours réutilise la valeur précédente sans bloquer le CPU.

#### E. Protocole d'Évaluation & Critères Go / No-Go
* **Métrique Primaire** : Disparition complète de tout stall de synchronisation dans le Top 20 VTune Hotspots.
* **Métrique Secondaire** : Écart-type du frametime (Frame Pacing) sous Tracy $\rightarrow$ Stabilité $\ge 99.5\%$.

---

## 3. Matrice de Synthèse & Tableau Comparatif des Risques / Gains

| Piste d'Optimisation | Cible Primaire | Gain Espéré | Risque Identifié | Stratégie Anti-Transfert de Coût | Outil de Validation Clé |
|---|---|---|---|---|---|
| **Piste A (FBO R11G11B10F)** | Mémoire / DRAM | **-50% bande passante DRAM**, -50% VRAM FBOs | Perte canal Alpha / Banding HDR | Maintien `velocity_tex` en RG16F, validation PSNR/SSIM | VTune Memory Access + Visual Regression |
| **Piste B (AZDO Persistent SSBO)** | Driver OpenGL / CPU | **-15% à -20% temps CPU Gallium** | WC reads lents / Data hazard concurrent | Écriture strictly write-only, triple buffering avec fences GPU | VTune CPU Hotspots + Tracy GPU zones |
| **Piste C (IBL Workgroups & Hammersley)** | GPU Compute | **Bake IBL de 210ms $\rightarrow$ < 120ms** | VGPR register spilling | Calibration workgroups pour Intel Xe, validation bit-à-bit | Log IBL timing + Tracy GPU |
| **Piste D (PBO Triple-Buffering)** | Sync CPU-GPU | **0 stall de synchronisation readback** | Latence de 2 frames sur Auto-Exposure | Fences non-bloquantes timeout=0, lissage temporel | VTune Locks & Waits + Frametime stability |

---

## 4. Recommandation d'Ordonnancement pour le Sprint 5

Il est recommandé d'exécuter ces pistes dans l'ordre suivant :
1. **Étape 1 : Piste A (Formats R11G11B10F)** $\rightarrow$ Attaque directe du goulot mémoire principal (`DRAM Bound: 44.3%`).
2. **Étape 2 : Piste B (AZDO Persistent Mapped Buffers)** $\rightarrow$ Attaque du goulot driver principal (`libgallium: 24.7%`).
3. **Étape 3 : Piste C (Optimisation Compute IBL)** $\rightarrow$ Réduction du temps de calcul GPU de régénération d'environnement.
4. **Étape 4 : Piste D (PBO Triple-Buffering)** $\rightarrow$ Lissage parfait des readbacks de diagnostic.
