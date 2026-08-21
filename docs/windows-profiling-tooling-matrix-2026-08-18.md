# Matrice de Compatibilité du Profilage et Benchmarks (Windows / Wine / Linux)

Ce document détaille l'applicabilité et les contraintes techniques des outils de profilage (Intel VTune, Tracy Profiler, RenderDoc, Valgrind, Callgrind, Heaptrack) et des benchmarks sur les exécutables Windows PE (`suckless-odin.exe`) exécutés sous Wine/Proton par rapport à l'environnement natif Linux ELF et Windows natif.

---

## 1. Tableau Synthétique de Compatibilité

| Outil | Sous Wine / Proton (Linux) | Sur Windows Natif | Statut & Rationale Technique |
|---|---|---|---|
| **RenderDoc** | ✅ **Oui** | ✅ **Oui** | Capture d'appels OpenGL 4.6 via injection DLL Win32 ou hooks pilote graphique Linux hôte. |
| **Tracy Profiler** | ✅ **Oui** | ✅ **Oui** | Protocole réseau TCP (`127.0.0.1:8086`) indépendant de l'OS. Compatible Wine avec `ws2_32.lib`. |
| **Benchmark interne** | ✅ **Oui** | ✅ **Oui** | Drapeaux CLI `--benchmark`, `--benchmark-frames=N`, `--no-postfx`, `--compute-profile` 100% opérationnels. |
| **Intel VTune Profiler** | 🟡 **Partiel (EBS)** | ✅ **Oui (Complet)** | **Wine** : Sampling matériel PMU (Hardware EBS) fonctionnel pour Hotspots / Memory Access / Threading. Callstacks PE/COFF dégradées. **Windows** : 100% supporté avec PDB. |
| **Valgrind (Memcheck)** | ❌ **Non** | ❌ **Non** | Inexistant sur Windows. Sous Wine, `LD_PRELOAD` cible `wine-preloader` et génère un bruit massif de faux positifs sur les stubs ntdll/kernel32. |
| **Valgrind (Callgrind)** | ❌ **Non** | ❌ **Non** | Émulateur d'instructions CPU ciblant uniquement les binaires Linux ELF. |
| **Heaptrack** | ❌ **Non** | ❌ **Non** | `LD_PRELOAD` n'intercepte pas les allocations Win32 (`HeapAlloc`, `RtlAllocateHeap`). Outil strictement Linux ELF. |

---

## 2. Analyse Détaillée par Outil

### 2.1. RenderDoc (Inspection GPU & Passes de Rendu)
- **Fonctionnement sous Wine** :
  Lancer via `renderdoccmd capture wine build/release-win/suckless-odin.exe` ou en injectant via l'interface graphique `qrenderdoc`.
- **Capacités** :
  - Inspection de chaque passe FBO, textures IBL, compute shaders et géométrie.
  - Bit-for-bit identique entre le build Linux natif et le build Windows exécuté sous Wine.

### 2.2. Tracy Profiler (Télémétrie Temps Réel CPU / GPU)
- **Fonctionnement** :
  Le client Tracy intégré dans `suckless-odin.exe` ouvre une socket client vers le serveur GUI `tracy-profiler` (port 8086).
- **Avantages** :
  - Zéro dépendance au runtime OS pour l'analyse des zones de code (`ZoneScoped`).
  - Fonctionne de manière transparente sous Wine, Proton et Windows natif.

### 2.3. Intel VTune Profiler (Hotspots, Memory Access & Locks)
- **Sous Wine (Linux hôte)** :
  - **Mode User-Mode (Pin injector)** : ❌ Échoue sur le dispatcher multi-arch `/usr/lib/wine/wine`.
  - **Mode Hardware EBS (Event-Based Sampling)** : ✅ **Opérationnel** avec `sampling-mode=hw` ou `sampling-and-waits=hw`.
  - Permet de mesurer :
    - *Hotspots CPU* : % de temps passé dans les fonctions critiques et le kernel Linux.
    - *Memory Access* : Bande passante DRAM (GB/s), LLC Misses, Memory Bound pipeline slots.
    - *Threading* : Inactivité des cœurs logiques/physiques et context switches.
  - *Rapport d'analyse empirique complet* : Voir [`docs/windows-vtune-profiling-analysis-2026-08-18.md`](windows-vtune-profiling-analysis-2026-08-18.md).
- **Sur Windows Natif** :
  - Analyse complète avec symboles PDB / CodeView et call stacks complètes au niveau des lignes de code source.

### 2.4. Outils Mémoire Spécifiques ELF (Valgrind, Heaptrack)
- **Contraintes** :
  Ces outils reposent sur l'interposition dynamique `LD_PRELOAD` sur `malloc`/`free`/`mmap` de la `glibc` Linux.
- **Recommandation** :
  Pour toute analyse de fuite mémoire, sanitization ou comptage d'instructions CPU :
  - Utiliser les cibles Linux ELF natives : `task valgrind`, `task profile-heaptrack`, `task profile-callgrind`, `task build-sanitize`.
  - Les correctifs algorithmiques apportés au code Odin profitent directement aux deux plateformes (Linux et Windows).

---

## 3. Guide Pratique des Commandes

### 3.1. Profilage sous Wine / Linux

```bash
# Benchmark interne (200 frames de rendu automatisé sous Wine)
task run-win-release -- --benchmark --benchmark-frames=200

# VTune Hotspots sous Wine (Sampling Hardware PMU)
sudo vtune -collect hotspots -knob sampling-mode=hw -r build/profiling/vtune_win_hotspots -- wine ./build/release-win/suckless-odin.exe --benchmark --benchmark-frames=200

# VTune Memory Access sous Wine (Mesure bande passante DRAM)
sudo vtune -collect memory-access -r build/profiling/vtune_win_mem -- wine ./build/release-win/suckless-odin.exe --benchmark --benchmark-frames=200

# VTune Threading sous Wine
sudo vtune -collect threading -knob sampling-and-waits=hw -r build/profiling/vtune_win_threading -- wine ./build/release-win/suckless-odin.exe --benchmark --benchmark-frames=200
```

### 3.2. Profilage Mémoire & Analyse Stricte (Natif Linux ELF)

```bash
# Fuites mémoires et erreurs d'accès
task valgrind

# Profilage allocations heap
task profile-heaptrack
task profile-heaptrack-gui

# Arbre d'appels et instruction count
task profile-callgrind
task profile-callgrind-gui
```
