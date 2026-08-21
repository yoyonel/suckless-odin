# Guide de Profiling Avancé : Heaptrack, Intel VTune & Callgrind

Ce document décrit l'utilisation des outils de profiling mémoire, CPU et threading intégrés dans `suckless-odin` pour établir des baselines de performances de référence.

---

## 1. Vue d'Ensemble des Outils

| Outil | Type d'Analyse | Métriques Clés | Commandes Linux | Commandes Windows (Wine) | GUI Associé |
|---|---|---|---|---|---|
| **Tracy Profiler** | Timeline Passes & GPU | Zones CPU/GPU, frame time, IBL progressive compute | `task profile-tracy` | `task profile-win-tracy` | `task profile-tracy-gui` |
| **GPU Render Benchmark** | Débit & Frametime | FPS moyen, frametime déterministe (11 passes) | `task bench-render` | `task bench-win-render` | CLI / stdout |
| **Heaptrack** | Mémoire Heap & Allocations | Pic mémoire, nombre d'allocations par frame | `task profile-heaptrack` | N/A (Heap NT interne) | `task profile-heaptrack-gui` |
| **Intel VTune** (Hotspots) | CPU Pur & Hotspots | Top 15 fonctions Odin consommées, temps CPU | `task profile-vtune-hotspots` | N/A (Conflit Pin/Wine) | `task profile-vtune-gui` |
| **Intel VTune** (Memory) | Accès Mémoire & Caches | **L1/L2/L3 Misses**, LLC Misses, DRAM BW | `task profile-vtune-memory` | N/A (PMU Hardware) | `task profile-vtune-gui` |
| **Intel VTune** (Threading) | Concurrence & Verrous | Contentions de sync, temps d'attente | `task profile-vtune-threading` | N/A (PMU Hardware) | `task profile-vtune-gui` |
| **Valgrind Callgrind** | Call Graph & Instructions | Compteurs d'instructions CPU exacts | `task profile-callgrind` | N/A (Binaire ELF) | `task profile-callgrind-gui` |
| **Suite Complète** | Exécution tout-en-un | Profilage automatisé de bout en bout | `task profile-all` | `task profile-win-all` | Tous les GUIs |

---

## 2. Compilation Pré-Requise

Tous les outils de profiling avancés nécessitent un build optimisé conservant la table des symboles et les numéros de ligne (`-o:speed -debug`) :

```bash
task build-relwithdebinfo
```

---

## 3. Profiling des Allocations Mémoire (Heaptrack)

### A. Exécution CLI

```bash
task profile-heaptrack
```

Le script `scripts/benchmark_heaptrack.sh` exécute l'application de manière automatisée avec simulation de changement d'environnement HDR via touches X11/xdotool, enregistre les allocations et affiche un résumé direct :

- **Peak heap memory consumption** (pic d'utilisation du tas).
- **Calls to allocation functions** (nombre total d'allocations).
- **Top hotspots d'allocation** avec stacktraces.

### B. Exploration Graphique

```bash
task profile-heaptrack-gui
```

Permet de visualiser :
- La courbe d'allocation mémoire au fil du temps.
- Les allocations temporaires créées et détruites rapidement.
- Le Flamegraph d'allocation.

---

## 4. Profiling Matériel Intel VTune

> [!NOTE]
> Intel VTune accède aux compteurs matériels du processeur (PMU) et requiert les permissions `sudo`. Les scripts gèrent automatiquement l'ajustement des permissions du répertoire de résultat pour l'utilisateur courant.

### A. Analyse des Accès Mémoire & Cache Misses (L1/L2/L3)

```bash
task profile-vtune-memory
```

Analyse l'efficacité des transferts mémoire CPU $\leftrightarrow$ Mémoire / Caches :
- **L1/L2/L3 Cache Misses** : Mesure l'efficacité de la mise en cache des structures UBO, matrices et buffers.
- **DRAM Bound** : Pourcentage de cycles d'exécution bloqués en attente de données en RAM.
- **Average Latency** : Latence moyenne des accès mémoire en cycles CPU.

### B. Analyse des Hotspots CPU

```bash
task profile-vtune-hotspots
```

Identifie les 15 fonctions les plus coûteuses en temps CPU.

### C. Analyse de Threading & Verrous

```bash
task profile-vtune-threading
```

Mesure l'utilisation des threads (Thread Concurrency), l'efficacité du worker de chargement I/O asynchrone et les contentions éventuelles.

### D. Exploration Graphique VTune

```bash
task profile-vtune-gui
```

Ouvre l'interface `vtune-gui` sur la dernière capture générée pour inspecter le code source annoté et l'assembleur.

---

## 5. Profiling d'Instructions & Call Graph (Callgrind)

### A. Exécution CLI

```bash
task profile-callgrind
```

Génère une trace d'instructions CPU et produit un résumé annoté avec `callgrind_annotate`.

### B. Exploration Graphique

```bash
task profile-callgrind-gui
```

Ouvre le graphe d'appels interactif dans **KCachegrind**.

---

---

## 6. Profiling Temps Réel Nanoseconde (Tracy Profiler)

`suckless-odin` intègre une instrumentation de profiling temps-réel à parité totale avec `suckless-vulkan` et `suckless-ogl` :

1. **Timeline Matérielle GPU (OpenGL 4.6)** : Mesure matérielle nanoseconde via `gl_debug.push_group` / requêtes de timestamps GPU calibrées sur le contexte OpenGL (`Scene_Render`, `Instanced_PBR_Spheres`, `Skybox_Pass`, `PostProcess_Uber`, `IBL:*`).
2. **Timeline CPU Standardisée** : Hiérarchie unifiée (`Total Frame`, `Frame Acquire Swapchain / Poll`, `Frame Scene Update`, `Frame Scene Render`, `Frame Queue Submit & Present`).
3. **Pistes Virtuelles (Fibers Tracy)** :
   * **`Async Status`** : Visualisation macroscopique continue de la machine à états du chargeur HDR (`Async IDLE`, `Async PENDING`, `Async LOADING`, `Async CONVERT`, `Async READY`, `Async FAILED`).
   * **`Hybrid Perf`** : Découpage précis du temps de préparation CPU hôte (`Host (CPU): Luminance`, `Host (CPU): BRDF LUT`, `Host (CPU): Specular`, `Host (CPU): Irradiance`) et des temps d'attente/barrières GPU (`Sync (GPU Wait)`).
4. **Forwarding des Logs du Moteur** : Tous les messages de log (`log_info`, `log_error`, etc.) sont transmis avec coloration sémantique dans l'onglet *Messages* de Tracy.
5. **Plots Numériques en Temps Réel** : Courbes de suivi `FPS`, `Frame Time (ms)` et `IBL Slices Done`.

### A. Capture & Vérification Automatisée

![Automated Tracy Profiler capture and programmatic trace verification](./tracy.png)

```bash
task profile-tracy
```

Le script `scripts/benchmark_tracy.sh` démarre le serveur de capture `tracy-capture`, exécute le scénario interactif 16s avec cycle d'environnements HDR et caméra, puis vérifie programmatiquement la présence de tous les invariants via `scripts/verify_tracy_trace.py`.

### B. Exploration Graphique Tracy

```bash
task profile-tracy-gui
```

---

## 7. Suite Complète de Profiling

Pour lancer l'ensemble des analyses en une seule commande :

```bash
task profile-all
```
