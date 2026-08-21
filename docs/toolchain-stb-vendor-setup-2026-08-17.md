# Résolution de l'environnement de build : Compilation des bibliothèques C `vendor:stb` d'Odin

**Date** : 17 Août 2026  
**Contexte** : Reprise de projet / Mise à jour du toolchain Odin (`odin-linux-amd64-nightly+2026-08-06`)  
**Statut** : Résolu  

---

## 1. Symptôme & Erreur

Lors de l'exécution des tests unitaires ou de la compilation (`task test-unit` ou `odin test tests/`), le compilateur Odin s'arrête avec des paniques à la compilation (*compile-time panics*) dans les packages `vendor/stb/*` :

```text
/path/to/odin/vendor/stb/truetype/stb_truetype.odin(18:3) Error: Compile time panic: Could not find the compiled STB libraries, they can be compiled by running `"/path/to/odin/vendor/stb/src/build_stb.sh"`
	#panic("Could not find the compiled STB libraries, they ... 
/path/to/odin/vendor/stb/image/stb_image_write.odin(17:3) Error: Compile time panic: Could not find the compiled STB libraries, they can be compiled by running `"/path/to/odin/vendor/stb/src/build_stb.sh"`
/path/to/odin/vendor/stb/rect_pack/stb_rect_pack.odin(19:3) Error: Compile time panic: Could not find the compiled STB libraries, they can be compiled by running `"/path/to/odin/vendor/stb/src/build_stb.sh"`
/path/to/odin/vendor/stb/image/stb_image_resize.odin(17:3) Error: Compile time panic: Could not find the compiled STB libraries, they can be compiled by running `"/path/to/odin/vendor/stb/src/build_stb.sh"`
/path/to/odin/vendor/stb/image/stb_image.odin(18:3) Error: Compile time panic: Could not find the compiled STB libraries, they can be compiled by running `"/path/to/odin/vendor/stb/src/build_stb.sh"`
task: Failed to run task "test-unit": exit status 1
```

---

## 2. Cause racine

Les distributions binaires de nightly Odin ou les toolchains installés manuellement dans `~/.local/share/` ou mis à jour via gestionnaire ne distribuent pas toujours les archives binaires statiques C pré-compilées (`.a`) pour la cible locale (`linux_amd64`) dans `vendor/stb/lib/linux/`.

Dans `suckless-odin`, les modules suivants dépendent directement de `vendor:stb` :
- `vendor:stb/image` : Chargement des textures HDR/LDR (`stbi_loadf_from_memory`, `stbi_load`)
- `vendor:stb/image_write` : Sauvegarde des captures et des références de régression visuelle (`stbi_write_png`)
- `vendor:stb/truetype` & `vendor:stb/rect_pack` : Génération de l'atlas de glyphes de l'overlay texte HUD

---

## 3. Solution / Procédure de résolution

Exécuter le script de build C officiel fourni dans l'arborescence du compilateur Odin actif :

```bash
# Identifier le répertoire racine d'Odin
ODIN_ROOT="$(odin root)"

# Compiler les wrappers statiques C pour STB
"${ODIN_ROOT}/vendor/stb/src/build_stb.sh"
```

Ce script compile :
- `stb_image.c` -> `stb_image.a`
- `stb_image_write.c` -> `stb_image_write.a`
- `stb_image_resize2.c` -> `stb_image_resize2.a`
- `stb_rect_pack.c` -> `stb_rect_pack.a`
- `stb_truetype.c` -> `stb_truetype.a`
- `stb_vorbis.c` -> `stb_vorbis.a`

---

## 4. Vérification & Validation

Après exécution du script, valider l'ensemble du pipeline via Task :

```bash
# 1. Vérification statique & lint
task lint

# 2. Compilation des cibles de build
task build
task build-release
task build-strict

# 3. Validation de la suite de tests
task test-unit      # 70/70 tests OK
task test-cli       # 13/13 tests OK
task test-shader    # 12/12 tests OK
task test-gl        # Tests OpenGL complets OK
```

Toutes les recettes `task` s'exécutent désormais avec un code de retour `0`.
