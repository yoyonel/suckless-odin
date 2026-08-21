# Analyse des Bottlenecks GPU et Écarts de Performance : C11 vs. Odin

**Date :** 3 juin 2026  
**Auteur :** Antigravity AI  
**Plateforme :** Bazzite Linux (Fedora) — GPU hybride Nvidia GTX 950M (architecture Maxwell) + Intel iGPU sous Wayland.

---

## 1. Contexte et Symptômes

Lors de l'exécution comparée des deux implémentations du moteur de rendu OpenGL :
* **suckless-ogl (C11)** : L'utilisation du GPU Nvidia atteint **99 %** de sa capacité avec un framerate élevé et fluide.
* **suckless-odin (Odin)** : L'utilisation du GPU plafonne autour de **90 %** avec un framerate significativement plus faible, pour un rendu visuel équivalent.

Cette documentation analyse les causes de ce plafonnement (GPU capping/under-utilization) et propose des solutions concrètes pour retrouver les performances de la version C11.

---

## 2. Facteurs Explicatifs Majeurs

### 🔍 A. Configuration de l'Offloading PRIME Hybride (Optimus)
Le premier facteur de différence réside dans la configuration de l'offloading graphique sur le PC portable.

Dans le fichier `.env`, les variables requises pour le PRIME Render Offload d'NVIDIA et le débrayage du VSync sont absentes :
```env
# Configuration requise mais absente de l'environnement actif
__NV_PRIME_RENDER_OFFLOAD=1
__GLX_VENDOR_LIBRARY_NAME=nvidia
__VK_LAYER_NV_optimus=NVIDIA_onl
vblank_mode=0
__GL_SYNC_TO_VBLANK=0
```

> [!IMPORTANT]
> **Impact sur les performances :**
> Sans ces variables, l'application lancée via `task run` s'exécute par défaut sur le chipset intégré Intel (iGPU) ou utilise un mode de copie hybride inefficace. MangoHud affiche alors soit la charge de l'iGPU (qui sature en fonction des limites thermiques du CPU), soit des statistiques de copie, ce qui explique le framerate faible et la sous-utilisation du dGPU Nvidia.

---

### 🔍 B. Présentation de la Swap Chain : Wayland Natif vs. XWayland
La version Odin utilise GLFW 3.4+ (`vendor:glfw`), qui privilégie un backend **Wayland natif** sous Linux. La version C11 utilise quant à elle potentiellement le backend **X11** hérité.

* **Sous Wayland Natif (Odin) :** La présentation des buffers est étroitement contrôlée par le compositeur Wayland. Même si le VSync est désactivé côté application (`glfw.SwapInterval(0)`), le compositeur impose des barrières de synchronisation. Sans support du tearing explicite (`wp_tearing_control_v1`), le pilote Nvidia bride la file de présentation, laissant le GPU inactif pendant que le compositeur traite la frame précédente. Cela crée un plafond artificiel à ~90% d'utilisation GPU.
* **Sous X11 / XWayland (C11) :** Le pilote Nvidia peut forcer le rafraîchissement asynchrone sans retenue via `__GL_SYNC_TO_VBLANK=0`, saturant le GPU à 99 %.

---

### 🔍 C. Surcharge du Profiler Tracy (`glQueryCounter`)
Si l'application Odin est compilée ou exécutée avec le profiler actif (`task build-profile` ou `task run-profile`) :

> [!WARNING]
> **Overhead du pilote Nvidia propriétaire :**
> Les requêtes de temps GPU émises par Tracy (`glQueryCounter`) insèrent des commutations de contexte très lourdes au niveau du pilote Nvidia. Ces commutations bloquent temporairement le processeur de commandes graphiques, créant des "micro-bulles" d'inactivité sur le GPU, visibles sous forme de trous dans la timeline. Cela empêche le GPU d'atteindre 99 % d'occupation.

---

### 🔍 D. Compute Shaders et Barrières Mémoire (`glMemoryBarrier`)
Le portage Odin a modernisé le pipeline Post-FX en introduisant des **Compute Shaders** pour l'exposition automatique (`auto_exposure.odin`) et le flou de mouvement (`motion_blur.odin`).

* **Synchro stricte dans Odin :** L'implémentation Odin utilise des barrières mémoires explicites (combinant `TEXTURE_FETCH` et `IMAGE_ACCESS`) après chaque dispatch.
* **Impact de l'architecture Maxwell (GTX 950M) :** Les opérations de Compute et les barrières associées forcent l'invalidation des caches du GPU et figent le pipeline d'exécution graphique. La version C11, en exploitant des passes classiques de fragment shaders (rasterization ping-pong FBO), tirait parti des unités matérielles fixes du GPU (ROPs) et de la compression de couleur (DCC), évitant ces barrières bloquantes.

---

### 🔍 E. Mode de Compilation (Debug vs. Ultra-Release)
Par défaut, `task run` compile le code Odin en mode **Debug** (qui inclut des assertions de type, des vérifications de limites d'index et aucune optimisation).

```
Odin Debug Mode:
[CPU: State/Bounds/Type checks] --(Lent)--> [Soumission GL] ----(GPU attend le CPU)----> [GPU Usage: 90%]
```

> [!NOTE]
> En mode Debug, le processeur met beaucoup plus de temps à soumettre les commandes OpenGL. Le GPU passe de courtes périodes d'attente à vide (starvation), ce qui réduit son taux d'utilisation global et effondre le framerate.

---

## 3. Plan d'Action pour Restaurer les Performances

Pour éliminer ces bottlenecks et retrouver une utilisation optimale à 99 % sur la GTX 950M, appliquez les étapes suivantes :

### 📋 Synthèse des Actions

| Source du Bottleneck | Action Corrective | Impact Attendu |
| :--- | :--- | :--- |
| **Offloading GPU** | Compléter le fichier `.env` avec les variables PRIME d'Nvidia. | Transition immédiate sur la GTX 950M (+300% FPS). |
| **Wayland Sync** | Exécuter l'application sous XWayland via la variable `GLFW_PLATFORM=x11` ou activer le tearing Wayland. | Débrayage complet du VSync, GPU à 99% d'usage. |
| **Build overhead** | Utiliser exclusivement le mode Ultra-Release pour les mesures de frametime (`task br-ultra`). | Élimination des vérifications CPU, soumission instantanée. |
| **Tracy Profiling** | Lancer la version release classique (`task run-release`) sans Tracy. | Suppression des overheads liés aux requêtes `glQueryCounter`. |

---

> [!TIP]
> **Commande recommandée pour le benchmark de performance pure :**
> ```bash
> GLFW_PLATFORM=x11 task br-ultra
> ```
