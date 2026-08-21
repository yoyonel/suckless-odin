# Guide du Développeur : Étendre l'Automate et la Spécification TLA+

Ce guide pratique explique pas-à-pas comment ajouter un nouvel état ou modifier la logique de transition de l'automate de l'application.

Pour illustrer la méthodologie sans aucun prérequis mathématique, nous étudions ici un scénario d'évolution concret : **l'intégration d'un fondu sonore (Audio Crossfade)** lors du changement d'environnement.

---

## 1. Description du Scénario d'Évolution

Actuellement, notre séquence de transition graphique est la suivante :
$$\text{Idle} \longrightarrow \text{Loading} \longrightarrow \text{Wait\_IBL} \longrightarrow \text{Fade\_In} \longrightarrow \text{Idle}$$

Nous souhaitons insérer un nouvel état appelé **`Audio_Fade`** juste après la fin des calculs de lumière (`Wait_IBL`), mais avant d'afficher visuellement la nouvelle scène (`Fade_In`). Pendant cet état, le moteur va atténuer l'ancienne musique et lancer la nouvelle. Une fois le fondu audio terminé, la transition graphique (`Fade_In`) pourra démarrer.

La nouvelle séquence visée est :
$$\text{Idle} \longrightarrow \text{Loading} \longrightarrow \text{Wait\_IBL} \longrightarrow \textbf{Audio\_Fade} \longrightarrow \text{Fade\_In} \longrightarrow \text{Idle}$$

---

## 2. Étape 1 : Mise à jour de la Spécification Formelle TLA+

Le fichier [EnvManagerVerification.tla](EnvManagerVerification.tla) est notre unique source de vérité. Nous allons y déclarer ce nouvel état et ses flèches de transition autorisées.

### A. Déclarer le nouvel état

Dans la définition de l'ensemble des états de transition globaux (`TransitionStates`), ajoutez `"Audio_Fade"` :

```tla
TransitionStates == { "Idle", "Loading", "Wait_IBL", "Audio_Fade", "Fade_Out", "Fade_In" }
```

### B. Définir les transitions autorisées (Flèches)

Dans la table des transitions autorisées (`TransitionTransitions`), nous déclarons les chemins légitimes :

1. Remplacer la transition directe `<< "Wait_IBL", "Fade_In" >>` (devenue obsolète).
2. Ajouter le passage de `Wait_IBL` à `Audio_Fade`.
3. Ajouter le passage de `Audio_Fade` à `Fade_In`.
4. Permettre l'annulation de la transition depuis `Audio_Fade` vers `Idle` en cas d'interruption.

```tla
TransitionTransitions == {
    << "Idle", "Loading" >>,
    << "Loading", "Idle" >>,
    << "Loading", "Wait_IBL" >>,
    << "Wait_IBL", "Audio_Fade" >>,  \* Nouvelle flèche 1
    << "Audio_Fade", "Fade_In" >>,   \* Nouvelle flèche 2
    << "Audio_Fade", "Idle" >>,      \* Nouvelle flèche d'annulation
    << "Fade_Out", "Fade_In" >>,
    << "Fade_In", "Idle" >>,
    ...
}
```

### C. Écrire le comportement de l'action

Nous devons expliquer comment l'automate progresse.

D'abord, lorsque les calculs IBL sont terminés (`IBL_Complete_Crossfade`), nous modifions la destination de `Wait_IBL` pour aller vers `"Audio_Fade"` au lieu de `"Fade_In"` :

```tla
IBL_Complete_Crossfade ==
    /\ transition_state = "Wait_IBL"
    /\ ibl_state = "Done"
    /\ ibl_state' = "Idle"
    /\ transition_state' = "Audio_Fade"  \* Destination mise à jour
```

Ensuite, nous déclarons une nouvelle action TLA+ qui représente la fin du fondu sonore (lorsque le volume cible est atteint, l'état passe à `"Fade_In"`) :

```tla
AudioFadeComplete ==
    /\ transition_state = "Audio_Fade"
    /\ transition_state' = "Fade_In"
    /\ UNCHANGED <<ibl_state>>
```

Enfin, nous enregistrons cette nouvelle action dans la liste des choix possibles du système (`Next`) :

```tla
Next ==
    \/ StartTransition
    \/ LoaderFailed
    \/ LoaderSucceeds
    ...
    \/ IBL_Complete_Crossfade
    \/ AudioFadeComplete  \* Nouvelle action enregistrée
    \/ FadeInComplete
```

---

## 3. Étape 2 : Générer automatiquement le code Odin

Une fois le modèle mathématique modifié, le développeur n'a pas besoin d'écrire de structures de données ou de matrices complexes en Odin. Il lui suffit d'exécuter la commande suivante dans son terminal :

```sh
task codegen-states
```

Le script de génération automatique va lire le fichier `.tla`, analyser nos modifications et réécrire le fichier [env_manager_states.gen.odin](../src/scene/env_manager_states.gen.odin) :

1. L'énumération `Transition_State` inclura désormais automatiquement l'élément `Audio_Fade`.
2. La matrice statique booléenne `IS_TRANSITION_VALID` sera recalculée avec les valeurs `true` uniquement sur les flèches que nous avons définies (ex: de `.Audio_Fade` vers `.Fade_In`). Tout autre chemin sera configuré à `false`.

---

## 4. Étape 3 : Écrire le code métier (Odin)

Le développeur peut maintenant implémenter la logique physique du fondu audio dans le fichier principal [env_manager.odin](../src/scene/env_manager.odin).

### A. Traiter l'état dans la boucle de mise à jour

Dans la procédure `env_manager_update` qui est appelée à chaque frame, nous ajoutons le traitement de notre nouvel état :

```odin
env_manager_update :: proc(mgr: ^Env_Manager, scene: ^Scene, dt: f32) {
    ...
    switch mgr.transition_state {
    case .Idle:
        // Rien à faire
    case .Loading:
        env_manager_poll_loader(mgr)
    case .Wait_IBL:
        env_manager_advance_ibl(mgr, scene)
        
    case .Audio_Fade:  // Notre nouvel état
        // Logique métier : baisser le volume de la musique
        mgr.audio_volume = max(0.0, mgr.audio_volume - dt * 2.0)
        
        // Condition de sortie : lorsque le fondu est fini (volume à 0)
        if mgr.audio_volume <= 0.0 {
            // Déclencher la transition vers l'état suivant
            env_manager_set_transition_state(mgr, .Fade_In)
        }
        
    case .Fade_Out:
        ...
    case .Fade_In:
        ...
    }
}
```

### Le filet de sécurité en mode débogage

Si le développeur fait une erreur dans son code de transition (par exemple, s'il tente d'appeler `env_manager_set_transition_state(mgr, .Fade_In)` directement depuis `.Wait_IBL` sans passer par `.Audio_Fade`), l'assertion générée va s'exécuter instantanément en arrière-plan :

```odin
assert(env_manager_validate_transition(mgr.transition_state, new_state), "Viol d'automate : transition transition_state illégale")
```

Le programme s'arrêtera immédiatement avec un message clair, empêchant le développeur d'introduire un bug d'état ou un comportement imprévu en production.

---

## 5. Étape 4 : Valider la sûreté globale du système

Pour s'assurer que l'introduction de cet état `Audio_Fade` ne provoque pas de blocage (par exemple, un scénario où l'application reste bloquée indéfiniment dans le fondu sonore sans jamais pouvoir revenir à l'état `Idle`), le développeur lance le vérificateur formel :

```sh
task formal-verify
```

En moins d'une seconde, l'outil TLC va explorer l'intégralité des combinaisons d'états possibles et confirmer mathématiquement :

* Qu'il n'y a **aucun blocage** (Liveness respectée).
* Que les invariants de sécurité (comme la désactivation de l'IBL lorsque le système est au repos) sont toujours **100% respectés**.
