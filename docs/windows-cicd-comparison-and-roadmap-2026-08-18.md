# Analyse Comparative CI/CD Windows & Roadmap de Déploiement (suckless-ogl vs suckless-odin)

Ce document consigne l'analyse technique comparative des pipelines d'intégration et de déploiement continus (CI/CD) pour les cibles Windows entre le projet parent C11 ([`suckless-ogl`](../suckless-ogl)) et son portage moderne en Odin ([`suckless-odin`](./)). Il établit la feuille de route exacte pour l'alignement et la complétion des workflows GitHub Actions.

---

## 1. État des Lieux dans le Projet Parent C11 (`suckless-ogl`)

Dans le projet `suckless-ogl` ([`.github/workflows/main.yml`](../suckless-ogl/.github/workflows/main.yml) et [`.github/workflows/Dockerfile.ci-windows`](../suckless-ogl/.github/workflows/Dockerfile.ci-windows)), l'intégration Windows repose sur une chaîne conteneurisée hautement automatisée :

### 1.1. Image Conteneur Dédiée (`Dockerfile.ci-windows`)
- **Base** : Ubuntu 24.04 hébergée sur GitHub Container Registry (`ghcr.io/yoyonel/suckless-ogl-ci-windows:latest`).
- **Outils préinstallés** :
  - Compilateur croisé MinGW (`gcc-mingw-w64-x86-64`, `g++-mingw-w64-x86-64`).
  - Runtime Wine x86_64 (`wine64`) avec préfixe pré-initialisé (`wineboot --init` dans `/home/ciuser/.wine`).
  - Serveur X virtuel (`xvfb`) et Python 3.
- **Bénéfice** : Élimine les temps d'installation d'environ 25 minutes de paquets `apt-get` à chaque exécution de la CI.

### 1.2. Jobs GitHub Actions Windows
1. **`test-windows`** :
   - Exécuté dans le conteneur `ci-windows`.
   - Cross-compilation des tests unitaires et d'intégration via `toolchain-mingw.cmake`.
   - Exécution sous Wine avec `ctest --output-on-failure`.
2. **`build-production-windows`** :
   - Compilation de l'exécutable release optimisé (`app-Windows-Release.exe`).
   - Upload du binaire Windows dans les artéfacts GitHub Actions.
3. **`release` (Automatisation GitHub Releases)** :
   - Déclenché sur chaque push `master` (publication `Nightly Build`) ou sur tag `v*`.
   - Agrège les binaires Linux (`app-Release`, `app-UltraRelease`, `app-Profiling`) et Windows (`app-Windows-Release.exe`).
   - Publication automatique via `softprops/action-gh-release@v3`.

### 1.3. Outillage Local Steam & Proton
- **Runner Proton** ([`scripts/run_proton.sh`](../suckless-ogl/scripts/run_proton.sh)) : Exécute le binaire Windows sous le runtime officiel Proton de Valve (Flatpak ou natif).
- **Générateur d'Artworks Steam** ([`scripts/generate_steam_assets.sh`](../suckless-ogl/scripts/generate_steam_assets.sh)) : Génère les 5 formats officiels via ImageMagick (Cover 600×900, Hero 1920×620, Banner 460×215, Logo, Icône 64×64).
- **Injecteur Steam** ([`scripts/inject_steam_art.py`](../suckless-ogl/scripts/inject_steam_art.py)) : Détecte `shortcuts.vdf` et injecte automatiquement les grilles pour le client Steam.

---

## 2. État Actuel dans `suckless-odin`

Dans `suckless-odin`, toute la chaîne locale de compilation, de test sous Wine et de packaging est désormais opérationnelle, mais n'est pas encore câblée dans les workflows distants GitHub Actions :

| Capacité | Implémentation Locale Odin | Intégration CI GitHub Actions |
|---|---|---|
| **Compilation Dépendances Windows** | [`scripts/build_win_deps.sh`](../scripts/build_win_deps.sh) (`task build-win-deps`) | ❌ Absent |
| **Cross-Compilation Exécutable Windows** | [`scripts/build_win.sh`](../scripts/build_win.sh) (`task build-win`, `build-win-release`) | ❌ Absent |
| **Tests Automatisés sous Wine** | [`scripts/test_win.sh`](../scripts/test_win.sh) (`task test-win` — 104 tests) | ❌ Absent |
| **Packaging Distribution Standalone** | [`scripts/package_win.sh`](../scripts/package_win.sh) (`task package-win` — `.tar.zst` et `.zip`) | ❌ Absent |
| **Validation Intégrité Sandbox** | [`scripts/run_package_win.sh`](../scripts/run_package_win.sh) (`task run-package-win`) | ❌ Absent |
| **Publication Automatisée Releases** | — | ❌ Absent (seul l'artéfact binaire Linux est sauvegardé) |

---

## 3. Tableau Comparatif Synthétique

| Fonctionnalité CI/CD | `suckless-ogl` (C11) | `suckless-odin` (Odin) | Statut & Écart |
|---|---|---|---|
| **Chaîne de Cross-compilation** | CMake + `toolchain-mingw.cmake` | Odin `-target:windows_amd64` + Clang/LLD-19 statique | ✅ **Supérieur en Odin** (aucun runtime DLL externe requis) |
| **Packaging Standalone** | `scripts/package_win.sh` (`.tar.zst`) | `scripts/package_win.sh` (`.tar.zst` + `.zip`) | ✅ **100% Porté en local** |
| **Test de Distribution Isolé** | `just run-package-win` | `scripts/run_package_win.sh` (`task run-package-win`) | ✅ **100% Porté en local** |
| **Tests Windows en CI** | Job `test-windows` sous Wine | Job `test-windows` dans `ci-windows.yml` | ✅ **100% Intégré & Validé** |
| **Build Release Windows en CI** | Job `build-production-windows` | Job `package-windows` dans `ci-windows.yml` | ✅ **100% Intégré & Validé** |
| **GitHub Releases Automatisées** | Publication assets Linux + Windows sur tag/master | Pipeline multi-plateforme dans `.github/workflows/release.yml` | ✅ **100% Intégré & Validé** |
| **Image Docker CI & GHCR** | `Dockerfile.ci-windows` sur GHCR | `Dockerfile.ci` BuildKit + `.github/workflows/docker-ci-image.yml` | ✅ **100% Intégré & Validé** |
| **Runner Steam Proton** | `scripts/run_proton.sh` | `scripts/run_proton.sh` (`task run-proton`) | ✅ **100% Porté (Section 3.2)** |
| **Steam Grid & Injection Art** | `generate_steam_assets.sh` + `inject_steam_art.py` | `scripts/generate_steam_assets.sh` + `inject_steam_art.py` | ✅ **100% Porté (Section 3.2)** |

---

## 4. Feuille de Route d'Intégration CI/CD pour `suckless-odin`

### Phase 1 : Ajout des Jobs Windows dans `.github/workflows/ci-windows.yml` (Terminé)
1. **Job `test-windows`** :
   - Dépendances runner : `setup-windows-toolchain` (MinGW-w64, Clang-19, LLD-19, Wine64).
   - Étape 1 : Téléchargement / Cache du compilateur Odin via `setup-odin`.
   - Étape 2 : Construction des dépendances (`task build-win-deps`).
   - Étape 3 : Exécution de la suite de tests sous Wine (`task test-win`).

2. **Job `package-windows`** :
   - Construction release optimisée (`task build-win-release`).
   - Génération des archives (`task package-win`).
   - Validation sandbox sous Wine (`task run-package-win`).
   - Upload des archives `suckless-odin-windows-*.{tar.zst,zip}` dans les artéfacts GitHub Actions.

### Phase 2 : Automatisation des GitHub Releases (`.github/workflows/release.yml`) (Terminé)
- Déclenchement sur création de tag `v*` ou événement `workflow_dispatch`.
- Récupération des artéfacts Linux (`suckless-odin-linux-*.tar.zst`) et Windows (`suckless-odin-windows-*.zip`).
- Publication automatique de la Release GitHub avec les notes de version et checksums SHA-256.

### Phase 3 : Écosystème Steam & Proton (Section 3.2) (Terminé)
- Port de `scripts/run_proton.sh` (`task run-proton`) pour valider l'exécution Proton en environnement Steam Deck / Linux Desktop.
- Port de `scripts/generate_steam_assets.sh` et `scripts/inject_steam_art.py` (`task steam-gen-assets`, `task steam-art`).
