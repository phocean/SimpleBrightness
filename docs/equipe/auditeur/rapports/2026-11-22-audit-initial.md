# Audit initial SimpleBrightness — 2026-11-22

## 1. Périmètre

- Dépôt sans commit (`master` vide, tout est non suivi) : l'audit porte sur l'arbre de travail du 22/11 (sources, tests, `project.yml`, README, `docs/FAISABILITE.md`). Il n'y a pas de commit de base.
- Absents du dépôt : `AGENTS.md`, `docs/equipe/DECISIONS.md`, `docs/equipe/auditeur/A_FAIRE.md`. Les exigences viennent du brief du chef de projet et du README.
- Compilation Swift 6 sans avertissement. `xcodebuild … test` : 13 tests passent.
- Je n'ai pas lancé l'app et n'ai pas touché à la luminosité. Ce qui dépend du matériel est marqué « à confirmer ».

Vérifié et correct :
- `CoalescingWriter` : verrou correct, une seule boucle par écran, aucune activité au repos.
- Aucun keyUp avalé sans son keyDown : l'ensemble `consumed` s'en charge et `stop()` le vide.
- Pas de boucle infinie de synchro trouvée : le filtre d'échos et le seuil de 0,002 font converger.
- Rien n'est écrit au lancement.
- Tous les `assumeIsolated` s'exécutent sur le thread principal.
- Une seule rétention forte : la minuterie, via le `[weak self]` imbriqué, retient l'`AppDelegate`. Il vit aussi longtemps que l'app, donc c'est sans effet.

## 2. Constats

### Importants (S2)

**I1. Un écho tardif écrase la valeur en cache par une valeur périmée : crans perdus, voire recul.** À confirmer sur matériel (dépend de la latence de l'écho).
- Preuve : `BrightnessController.swift:143-145` écrit `values[display] = value` même quand c'est un écho. `step()` (`:109`) calcule le cran suivant à partir de ce cache.
- Scénario : l'utilisateur appuie trois fois de suite sur F2 (0,5 → 0,5625 → 0,625 → 0,6875). L'écho de 0,5625 arrive ensuite et remet le cache à 0,5625. Le quatrième appui écrit 0,625 : la luminosité baisse et l'OSD recule.
- Effets secondaires : pendant un glissement, le libellé % du curseur clignote (`BrightnessSliderView.swift:56`). Si l'écho arrive après 1,5 s (fenêtre comptée à la soumission, `:166`, pas à l'écriture), il passe pour un changement externe et la valeur périmée est propagée aux autres écrans.
- Correction : ne pas mettre à jour le cache sur un écho, sauf si la valeur est égale à la dernière valeur soumise pour cet écran.

**I2. Un échec d'écriture est avalé : le cache, le curseur et l'OSD ne correspondent plus à l'écran.**
- Preuve : `CoalescingWriter.swift:51` (`_ = write(...)`). `apply()` met le cache à jour avant l'écriture (`BrightnessController.swift:168-170`). Rien ne relit la valeur ensuite.
- Scénario : le Studio Display renvoie une erreur (USB pas prêt après le réveil). L'OSD affiche 60 % mais l'écran reste à 40 %. Les appuis suivants partent du faux cache. En synchro, `propagate` (`:157`) saute cet écran, qu'il croit déjà aligné.
- Correction : en cas d'échec, relire la valeur matérielle sur le thread principal, corriger le cache et notifier `onValueChanged`.

**I3. Pendant 2 s après le réveil, F1/F2 retrouvent le comportement natif que l'app doit corriger.**
- Preuve : `AppDelegate.swift:68` rend la touche à macOS tant que `isSleeping` est vrai. `isSleeping` ne repasse à faux que 2 s après `didWake` (`:154-156`).
- Scénario : l'utilisateur ouvre le capot, met le pointeur sur l'écran interne et appuie sur F1. C'est le Studio Display qui change (comportement natif décrit dans `FAISABILITE.md`). La synchro est suspendue, donc ce changement n'est jamais propagé : les écrans restent décalés alors que « Synchroniser » est coché.
- Correction : ne plus bloquer les touches pendant ce délai (la liste d'écrans est déjà à jour via `screensDidWake`, `:162`), ou relire puis réaligner à la levée de la suspension si la synchro est active.

**I4. Interrogation toutes les 2 s, sans fin, si l'utilisateur refuse l'autorisation Accessibilité.**
- Preuve : `AppDelegate.swift:91-101`. La minuterie répétée n'a pas de borne et tourne aussi pendant la veille et quand la session est inactive. Le garde `isSessionActive` est dans le bloc (`:94`), donc il ne l'arrête pas.
- Scénario : le README présente « sans Accessibilité » comme une configuration valide (curseurs et synchro seuls). Dans ce cas, le processus se réveille toutes les 2 s pendant toute la session. C'est contraire à l'exigence « pas de polling, pas de CPU au repos ».
- Correction : observer la notification distribuée `com.apple.accessibility.api`, ou ne vérifier qu'à l'ouverture du menu et pendant une durée limitée après « Autoriser… ».

**I5. La synchro n'est pas suspendue pendant la veille des écrans seule (sans veille système).** À confirmer.
- Preuve : `AppDelegate.swift:148-175` n'observe ni `screensDidSleepNotification` ni l'atténuation avant mise en veille.
- Scénario : macOS atténue l'écran interne avant la veille, ou sur batterie avec « Assombrir légèrement l'écran ». Si DisplayServices signale cette baisse, le Studio Display la recopie, puis remonte au réveil. Ce sont deux sauts de luminosité que l'utilisateur n'a pas demandés.
- Correction : vérifier sur matériel si ces notifications existent. Si oui, suspendre aussi entre `screensDidSleep` et `screensDidWake`.

### Mineurs (S3)

**M1. Course au réveil.** Le `asyncAfter` de `AppDelegate.swift:154` n'est jamais annulé.
- Scénario : capot rouvert puis refermé en moins de 2 s. Au réveil suivant, le bloc en attente s'exécute aussitôt : la suspension est levée et les écrans sont relus avant d'être stabilisés.
- Autre coût : chaque réveil déclenche trois rechargements complets (`:157`, `:163`, et la reconfiguration `:39`). Chacun relit les écrans et se désabonne puis se réabonne.

**M2. Lectures DisplayServices synchrones sur le thread principal, celui du tap clavier.** À confirmer (durée d'une lecture USB).
- Preuve : `DisplayManager.swift:59` (`supports` fait une lecture) et `BrightnessController.swift:80` (une seconde lecture). Chaque écran est donc lu deux fois par rechargement.
- Scénario : pendant ce temps, le tap (`BrightnessKeyTap.swift:58`) bloque toutes les touches système, volume et lecture compris. Au-delà du délai, macOS désactive le tap. L'app le réactive, mais l'appui en cours suit le comportement natif.

**M3. État incohérent si une lecture échoue au rechargement.**
- Preuve : `BrightnessController.swift:80`. Un écran déjà connu dont la lecture échoue est retiré de `displays`, mais `values`, `recentWrites` et l'abonnement restent.
- Effet : `isSupported` répond vrai, donc F1/F2 agissent sur cet écran, alors que la synchro l'ignore.
- Correction : traiter cet écran comme un écran retiré.

**M4. La fenêtre d'écho peut avaler un vrai changement externe.**
- Preuve : `BrightnessController.swift:166,177`.
- Scénario : à l'activation de la synchro, le Studio Display passe de 0,1 à 0,9. Pendant 1,5 s, tout changement fait dans le Centre de contrôle entre 0,09 et 0,91 sur cet écran est classé comme écho et n'est pas propagé. Les écrans restent décalés jusqu'au changement suivant.

**M5. Le curseur peut rester figé pendant que le menu est ouvert.** À confirmer.
- Preuve : `BrightnessSliderView.swift:61-67`. `isDragging` passe à vrai au clic et ne repasse à faux que si l'action reçoit un `leftMouseUp`.
- Scénario : sans cette action finale, le bouton du curseur ne suit plus F1/F2 ni la synchro tant que le menu reste ouvert.

**M6. Erreurs muettes côté utilisateur.**
- `LoginItem.swift:20-22` : « Ouvrir à la connexion » échoue sans message.
- `BrightnessKeyTap.swift:42` : `isRunning` vaut `tap != nil`. Si l'utilisateur retire l'autorisation Accessibilité alors que l'app tourne, le menu ne propose plus « Autoriser… ». À confirmer.

**M7. Tests et documentation.**
- Aucun test pour `CoalescingWriter`, la logique keyDown/keyUp, un échec d'écriture ou un écho périmé (I1, I2).
- `testRoundingPanelConverges` vérifie seulement `rounds < 10`, pas que les valeurs finales sont alignées.
- Le README renvoie à `docs/TESTS-MATERIELS.md`, qui n'existe pas.
- `Press.location` et `Press.isRepeat` ne servent qu'au journal.

## 3. Suggestions de fonctionnalités

1. **Indiquer quand la synchro est rompue** : marque dans le menu si les écrans diffèrent alors que la synchro est active, avec une action « Réaligner ». Coût : petit.
2. **Décalage par écran pour la synchro** : corriger l'écart de luminance (600 et 1 000 nits) signalé dans le README. Coût : moyen.
3. **Section « État » dans le menu** : touches actives ou non, synchro suspendue. Utile pour comprendre les cas I3 et I4. Coût : petit.

## 4. Synthèse pour le client

L'app ne réécrit rien au lancement et la synchronisation ne s'emballe pas.
Deux défauts peuvent faire afficher une luminosité fausse : un appui rapide peut faire reculer d'un cran, et un échec d'écriture n'est pas signalé.
Juste après le réveil, les touches retrouvent pendant 2 s leur comportement d'origine. Sans l'autorisation Accessibilité, l'app vérifie cette autorisation toutes les 2 s, sans fin.
