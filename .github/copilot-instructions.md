# RTK — Token-Optimized CLI

**rtk** is a CLI proxy that filters and compresses command outputs, saving 60-90% tokens.

## Rule

Always prefix shell commands with `rtk`:

```bash
# Instead of:              Use:
git status                 rtk git status
git log -10                rtk git log -10
cargo test                 rtk cargo test
docker ps                  rtk docker ps
kubectl get pods           rtk kubectl pods
```

## Meta commands (use directly)

```bash
rtk gain              # Token savings dashboard
rtk gain --history    # Per-command savings history
rtk discover          # Find missed rtk opportunities
rtk proxy <cmd>       # Run raw (no filtering) but track usage
```

## Langue de communication

Toujours communiquer en français avec l'utilisateur. Toutes les réponses, explications, documentations, commits et rapports d'artefacts doivent être rédigés en français, sauf si l'utilisateur demande explicitement le contraire.

## Politique de Commit et de Push (Sécurité & Règle Absolue)

- **INTERDICTION STRICTE DE COMMITER ET PUSHER AUTOMATIQUEMENT** :
  - **JAMAIS de `git commit`** sans demande ou autorisation explicite de l'utilisateur.
  - **JAMAIS de `git push`** sans demande ou autorisation explicite de l'utilisateur.
  - Tout commit ou push autonome/proactif est strictement proscrit.

## Utilisation du Taskfile (Go-Task) & Commandes

- **TOUJOURS privilégier `task <nom>`** défini dans `Taskfile.yml` au lieu de commandes manuelles ad-hoc.
- Pour les tests : `task test`, `task test-unit`, `task test-cli`, `task test-shader`, `task test-gl`, `task test-win`.
- Pour les builds : `task build-release`, `task build-win-release`, `task build-profile`.
- Pour les benchmarks & profiling : `task bench-render`, `task profile-tracy`, `task profile-vtune-hotspots`, `task profile-vtune-threading`.

## Benchmarking & Profiling Non-Intrusif

- **NE PAS modifier (ou le strict minimum)** le code source du moteur pour instrumenter des benchmarks.
- S'appuyer systématiquement sur les outils externes et les tâches de profiling du projet (Tracy Profiler, Intel VTune, Heaptrack, Callgrind, Valgrind).

## Validation Locale CI/CD & Environnements ISO Docker

- **JAMAIS de commit/push pour tester ou débugger la CI/CD**.
- Valider systématiquement et formellement tout fix de script, build ou CI en local via une image containerisée Docker/Podman ISO (`ubuntu:24.04`) avant de soumettre les résultats à l'utilisateur.
