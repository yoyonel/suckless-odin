# Antialiasing Spéculaire (Specular Anti-Aliasing) & Correctif GPU Intel/Mesa

**Date :** 8 juin 2026  
**Statut :** Implémenté, Validé & Documenté  

---

## 1. Contexte & Motivation
Sur les surfaces très lisses (faible rugosité) présentant une forte courbure ou des normales à haute fréquence (ex. normales de silhouette ou normales issues d'une texture), le rendu PBR spéculaire standard souffre d'un aliasing géométrique sévère (scintillement, aliasing temporel et sous-échantillonnage des spéculaires). 

Pour résoudre ce problème, nous avons intégré la technique de **Specular Anti-Aliasing (Varef)**, portée depuis le projet historique `suckless-ogl` en C11/OpenGL vers `suckless-odin`.

---

## 2. Description de l'Algorithme (Varef)
L'algorithme adapte dynamiquement la rugosité microfacette ($\alpha = \text{roughness}^2$) en lui ajoutant une variance géométrique $\sigma_{\text{added}}^2$ estimée à partir de la courbure de la surface ou des variations spatiales des normales. 

La rugosité finale filtrée est calculée comme suit :
$$\text{roughness}_{\text{final}} = \sqrt{\max(\text{roughness}^2 + \sigma_{\text{added}}^2, 0.04)}$$

Nous proposons deux modes d'estimation de la variance :
1. **Screen-Space (Dérivées d'Écran) :**
   Estime la variance des normales en utilisant les dérivées partielles d'écran (`dFdx` / `dFdy`) de la normale géométrique $N$ dans le fragment shader :
   $$\sigma_{\text{added}}^2 = 50.0 \times \max(\| \frac{\partial N}{\partial x} \|^2, \| \frac{\partial N}{\partial y} \|^2)$$
2. **Curvature (Courbure Analytique) :**
   Estime la variance de manière analytique à partir de la taille d'un pixel projeté dans le monde et du rayon de la sphère géométrique :
   $$\text{projectedCurvature} = \frac{\text{pixelSizeWorld}}{\text{SphereRadius}}$$
   $$\sigma_{\text{added}}^2 = 50.0 \times \text{projectedCurvature}^2$$

---

## 3. Architecture d'Intégration & Contrôles UI

Les composants modifiés sont les suivants :
- **[types.odin](../src/rendering/types/types.odin) :** Ajout des enums `Specular_AA_Mode` et `Specular_AA_Debug_Mode`.
- **[scene.odin](../src/scene/scene.odin) :** Initialisation et transmission des paramètres et uniforms au shader de rendu (`u_specular_aa_enabled`, `u_specular_aa_mode`, `u_specular_aa_debug_mode`, etc.).
- **[gui.odin](../src/gui/gui.odin) :** Ajout de contrôles interactifs dans l'onglet **Rendering** :
  - **Specular Anti-Aliasing (Varef) :** Activation globale.
  - **Specular AA Mode :** Choix entre *Screen-Space* et *Curvature*.
  - **Debug View :**
    - *Off* : Rendu PBR standard.
    - *Grayscale Variance* : Affiche un masque en niveaux de gris de la variance injectée (visualisation de la zone d'impact de l'AA).
    - *Amplified Difference* : Affiche la différence absolue amplifiée 10x entre le rendu avec et sans AA spéculaire.
  - **A/B Split :** Un séparateur horizontal réglable (Slider 0% à 100%) permettant de comparer côte à côte (gauche avec AA, droite sans AA). Un trait vertical orange (1.5 pixel de large) démarque visuellement la limite.

---

## 4. Analyse & Résolution du Bug GPU Intel/Mesa (Sphères Noires)

### Le Problème
Sur les GPU Intel (tels que Mesa Intel Iris Xe), les sphères avec une rugosité élevée ($\ge 0.4$) apparaissaient complètement noires dans l'application interactive.

### Diagnostic technique
1. Dans le shader compute de préfiltrage spéculaire `spmap.glsl`, le niveau de MIP map d'échantillonnage de la carte d'environnement d'entrée (`mipLevel`) est calculé dynamiquement :
   $$\text{mipLevel} = 0.5 \times \log_2(\frac{\text{saSample}}{\text{saTexel}})$$
2. Pour des valeurs de rugosité élevées, l'échantillonnage GGX est large. Le rapport $\frac{\text{saSample}}{\text{saTexel}}$ devient immense, générant des valeurs de `mipLevel` hors-limites (supérieures au niveau de MIP maximal de la texture, ex. $> 12.0$) ou négatives.
3. Les pilotes graphiques sous Mesa/Linux ont tendance à optimiser et ignorer les fonctions standards GLSL de vérification `isnan(mipLevel)` et `isinf(mipLevel)` sous des paramètres d'optimisation agressive (*fast-math*). 
4. Des valeurs `NaN`/`Inf` non interceptées passaient alors dans `textureLod(envMap, ...)`, provoquant le retour de couleurs corrompues (`NaN`/`Inf`). Le désinfecteur de couleur spéculaire du shader remplaçait ces valeurs invalides par du noir pur (`vec3(0.0)`), rendant les sphères rugueuses complètement noires.

### Correctif apporté
Nous avons éliminé tout recours aux fonctions `isnan()` et `isinf()` pour le filtrage et le clamping de la rugosité et de la variance, en introduisant un **clamping par branchement conditionnel direct** résistant aux optimisations de compilateurs :

Dans [spmap.glsl](../shaders/IBL/spmap.glsl) :
```glsl
float maxMip = max(log2(float(max(textureSize(envMap, 0).x, textureSize(envMap, 0).y))), 0.0);
if (mipLevel >= 0.0 && mipLevel <= maxMip) {
    // Garder le niveau mip valide
} else if (mipLevel < 0.0) {
    mipLevel = 0.0;
} else {
    mipLevel = maxMip;
}
```
Ce code assure que :
- Si `mipLevel` est supérieur à `maxMip` ou s'il est `NaN`/`+Inf` (les comparaisons `>= 0.0` et `<= maxMip` renvoient `false`), il est forcé à `maxMip`.
- Si `mipLevel` est inférieur à `0.0` ou ` -Inf`, il est forcé à `0.0`.

Une logique identique a été appliquée dans [pbr_billboard.frag](../shaders/pbr_billboard.frag) pour valider et brider la variance géométrique :
```glsl
// Sanitize variance and cap it to prevent "exploding" roughness at geometric silhouettes
if (variance >= 0.0 && variance <= 0.1) {
    // Garder la variance valide
} else {
    variance = 0.0;
}
out_variance = variance;
```

---

## 5. Parité des Tests de Non-Régression
Le correctif résout entièrement le problème de rendu noir de manière portable sur tous les pilotes graphiques (y compris Mesa/Intel) tout en conservant une parité stricte avec les images de référence d'origine (`tests/references/ref_*.png`). La suite intégrale de tests visuels (`task test-gl`) affiche **100 % de réussite** sans nécessiter de régénérer ou modifier les ressources de référence.

---

## 6. Persistance de Session & Filet de Sécurité (Safety Net)

### Persistance Specular AA dans `session.json`
Les réglages d'anti-aliasing spéculaire configurés à l'écran sont désormais entièrement persistés dans le fichier `session.json` et restaurés de manière identique d'une session à l'autre :
- Les 5 champs de l'AA spéculaire ont été ajoutés à la structure `Session_State` (`src/core/session/session.odin`).
- La fonction `extract_session_state` extrait l'état actif de la scène.
- La fonction `restore_session_state` réapplique l'état, avec un repli robuste à `0.5` si la position de séparation horizontale (`specular_aa_split_position`) est lue comme nulle ou non-positive.

### Filet de Sécurité de Cohérence UI-Persistence
Pour prévenir tout "trou" futur dans la persistance des nouveaux paramètres d'interface, un filet de sécurité automatisé a été mis en place :
1. **Script de vérification syntaxique (`scripts/check_persistence.py`) :**
   Ce script Python analyse :
   - Les champs pointeurs mutables interactifs déclarés dans la structure `Scene_State` (`src/gui/gui.odin`), à l'exception des états globaux complexes ou transitoires.
   - Les champs sérialisables dans `Session_State` (`src/core/session/session.odin`).
   - L'extraction et la restauration dans `src/app/session.odin`.
   - La couverture de test dans `tests/test_session.odin`.
   Si un champ est déclaré dans l'UI (`Scene_State`) mais qu'il est manquant dans l'une des autres étapes, le script échoue avec un code de retour non-nul en listant précisément l'emplacement de l'omission.
2. **Test automatique (`test_persistence_coverage`) :**
   Ce script est exécuté de manière automatisée lors de la suite de tests unitaires via `tests/test_session.odin` (appel `libc.system` de `check_persistence.py`), garantissant ainsi qu'aucun changement ou omission de persistance ne peut être intégré sans faire échouer `rtk task test`.

