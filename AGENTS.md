# Agent Instructions & Absolute Safety Guardrails

## 🚨 RÈGLE ABSOLUE : INTERDICTION DE COMMIT ET DE PUSH AUTOMATIQUES

1. **JAMAIS de `git commit`** sans demande ou autorisation explicite et directe de l'utilisateur.
2. **JAMAIS de `git push`** sans demande ou autorisation explicite et directe de l'utilisateur.
3. **Aucune action proactive de versioning** : l'agent prépare le code, exécute les tests, documente les changements, mais s'arrête strictement avant toute commande `git commit` ou `git push`.
4. **Images de référence** : Interdiction totale de modifier ou régénérer `tests/references/ref_*.png` sans validation humaine.

---

## 🛠️ RÈGLE D'OUTILLAGE : PRIORITÉ ABSOLUE AUX TASKS (Taskfile.yml)

1. **Pas de commandes shell manuelles ad-hoc** : Ne pas réinventer ou exécuter de scripts shell manuels quand une task `Taskfile.yml` existe.
2. **Utiliser systématiquement `task <nom>`** :
   - Tests : `task test`, `task test-unit`, `task test-cli`, `task test-shader`, `task test-gl`, `task test-gl-xvfb`, `task test-win`
   - Builds : `task build`, `task build-release`, `task build-win-release`, `task build-profile`
   - Benchmarks : `task bench-render`, `task bench-search`, `task bench-compare`
   - Profiling : `task profile-tracy`, `task profile-heaptrack`, `task profile-vtune-hotspots`, `task profile-vtune-threading`
   - Packaging : `task package`, `task package-win`, `task package-linux`

---

## 📊 RÈGLE DE BENCHMARKING & PROFILING NON-INTRUSIF

1. **Non-intrusion dans le code source** : Interdiction formelle de modifier le code source de l'application (ou strict minimum justifié et pré-validé) pour de simples besoins de benchmark ou de mesure.
2. **Outils externes fiables prioritaires** : S'appuyer sur les outils et pipelines de profilage externes éprouvés :
   - **Tracy Profiler** (`task profile-tracy`, `deps/tracy/csvexport`)
   - **Intel VTune Profiler** (`task profile-vtune-hotspots`, `task profile-vtune-threading`)
   - **Heaptrack** (`task profile-heaptrack`)
   - **Callgrind** (`task profile-callgrind`)
   - **Valgrind Memcheck** (`task valgrind`, `task valgrind-xvfb`)

---

## 🐳 RÈGLE DE VALIDATION LOCALE CI/CD & DOCKER (ZÉRO GUESSWORK)

1. **Interdiction formelle de commiter/pusher pour tester la CI** : Ne jamais utiliser le repository remote et GitHub Actions comme terrain d'essai ou environnement de test interactif.
2. **Validation ISO Locale obligatoire (Docker / Containers)** :
   - Tout fix ou changement lié à la CI/CD, aux scripts de build, aux paquets système ou à la cross-compilation doit être validé formellement en local dans un conteneur Docker/Podman répliquant strictement l'image vierge de la CI (`ubuntu:24.04`).
   - Présenter systématiquement les résultats de validation Docker locale à l'utilisateur avant toute demande d'autorisation de commit/push.
