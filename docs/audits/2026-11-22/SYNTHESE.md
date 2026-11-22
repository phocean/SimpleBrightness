# Synthèse des trois audits — 22 novembre 2026

Rapports : [audit-codex.md](audit-codex.md) (Codex, gpt-6.1-sol), [audit-claude.md](audit-claude.md) (Claude),
[audit-grok.md](audit-grok.md) (Grok). Consigne commune : [CONSIGNE.md](CONSIGNE.md). Tous en lecture
seule, sans se voir. Aucun constat critique chez aucun des trois.

## Notes

| Axe | Codex | Claude | Grok | Moyenne |
|---|---:|---:|---:|---:|
| Qualité du code | 6 | 7 | 7 | 6,7 |
| Sécurité | 8 | 7 | 7 | 7,3 |
| Architecture | 7 | 6,5 | 8 | 7,2 |

## Constats regroupés

« Vérifié CP » : contrôlé par le chef de projet après les audits (code lu, commande
lancée). Les priorités sont celles du chef de projet.

| # | Constat | Codex | Claude | Grok | Vérifié CP | Priorité | État |
|---|---|:-:|:-:|:-:|---|---|---|
| 1 | Le filtre d'échos (plage `[ancienne, nouvelle]` pendant 2 s) avale un vrai changement externe ; cache et synchro divergent jusqu'au changement suivant | ● | ● | ● | Oui (code) | **P1** | ✅ corrigé |
| 2 | Le build Debug porte `get-task-allow` avec la **même identité de signature** que l'app autorisée : il hérite de l'Accessibilité | | ● | ● | Oui (`codesign`) | **P1** | ✅ corrigé |
| 3 | Stabilisation : les notifications fausses alimentent le cache, F1/F2 partent de cette valeur ; la synchro reprend à 3 s alors que des relectures sont encore prévues à 6 et 10 s | | ● | ● | Oui (code) | **P1** | ✅ corrigé |
| 4 | Échec d'écriture : un échec ancien écrase une demande plus récente ; en synchro, seul l'écran en échec est relu, le groupe diverge | ● | | ● | Oui (code) | **P1** | ✅ corrigé |
| 5 | Une relecture qui échoue dans `updateDisplays` laisse un écran « fantôme » (encore « pris en charge », hors synchro, toujours abonné) | ● | ● | | Oui (code) | **P1** | ✅ corrigé |
| 6 | Garde-fou du `Makefile` : réussit si `codesign` échoue (pas de `pipefail`) | ● | | ● | Oui (rejoué) | **P1** | ✅ corrigé |
| 7 | Désinstallation : l'ouverture à la connexion n'est pas désinscrite, l'échec de `tccutil` est masqué (`\|\| true`), `build/` (build Debug) n'est pas supprimé | ● | ● | ● | Oui (Makefile) | **P1** | ✅ corrigé |
| 8 | Journal debug : position du pointeur en `.public` à chaque F1/F2 | ● | ● | ● | Oui (code) | **P1** (trivial) | ✅ corrigé |
| 9 | Écart + bornage à 0–1 : un cran peut faire −11 % sur l'autre écran au lieu de −6 % | | ● | | Oui (calcul) | P2 | ✅ corrigé |
| 10 | Écrans en miroir + écart : F2 peut **baisser** l'écran interne (0,50 → 0,4625) | ● | | | Oui (calcul) | P2 | ✅ corrigé |
| 11 | Écritures en attente non purgées à la veille, au changement de session ou au débranchement | ● | | | Oui (code) | P2 | ✅ corrigé |
| 12 | Lectures DisplayServices synchrones sur le fil principal, qui sert aussi le tap ; lectures et écritures d'un même écran peuvent se croiser | ● | ● | ● | Oui (code) ; durée non mesurée | P2 | ✅ mesuré, conservé (voir note) |
| 13 | Menu ouvert pendant un (dé)branchement : la liste d'écrans reste figée | | | ● | Oui (code) | P2 | ✅ corrigé |
| 14 | `NaN` non filtré (notification, préférence `syncOffset`) | | ● | | Oui (code) | P2 | ✅ corrigé |
| 15 | Échecs muets : abonnement aux notifications (niveau debug, sans reprise), ouverture à la connexion (case qui se décoche sans explication) | ● | ● | | Oui (code) | P2 | ✅ corrigé |
| 16 | `systemUptime` ne compte pas le temps de veille : une fenêtre d'écho entamée avant la veille reprend au réveil | | | ● | Oui (doc Apple) | P2 (réglé par 1 et 11) | ✅ corrigé |
| 17 | Tests : rien sur `CoalescingWriter`, le décodage des touches, la machine d'états veille/session/stabilisation, ni sur les cas 1, 3, 4, 5, 9, 10 | ● | ● | | Oui | avec chaque correctif | ✅ 37 tests |
| 18 | Architecture : la machine d'états (veille, session, stabilisation, touches) vit dans `AppDelegate`, sans test | | ● | | Oui | P3 | à faire (P3) |
| 19 | Architecture : deux sources de vérité pour « pris en charge » (`DisplayManager` et `BrightnessController`), lectures en double | | ● | | Oui | P3 | à faire (P3) |
| 20 | Architecture : contrats de concurrence tenus par des commentaires (`@unchecked Sendable`, singleton `current` des notifications) | ● | ● | ● | Oui | P3 | ◐ partiel |
| 21 | Architecture : pas encore de routeur multi-backend pour DDC/CI (capacités par écran, écrans sans notifications, débit par écran) | ● | ● | ● | Oui | v2 | v2 |

Points confirmés sains par les trois : tap limité à `NX_SYSDEFINED`, aucune frappe
ordinaire vue, aucun réseau ni télémétrie ni gamma, API privées isolées et chargées
par chemins absolus, runtime renforcé, Release sans `get-task-allow`, rien d'écrit au
lancement, `assumeIsolated` toujours atteint depuis le fil principal.

## Plan proposé

**Lot P1 (correctifs, avec tests)**
1. Build Debug : identifiant `com.jcbaptiste.SimpleBrightness.debug` et signature de
   développement distincte, pour qu'il ne puisse jamais hériter de l'autorisation.
2. Échos : une relecture du matériel à la fin de la fenêtre d'écho de chaque écran ; si
   la valeur diffère du cache, elle est traitée comme un changement externe.
3. Stabilisation : pendant `isSettling`, les notifications ne touchent plus le cache ;
   la synchro reste suspendue jusqu'à la dernière relecture utile ; F1/F2 relisent le
   matériel avant le pas.
4. Échecs d'écriture : numéro de génération par écran, échecs périmés ignorés ; en
   synchro, relecture du groupe et réapplication de la relation.
5. `updateDisplays` : nouvel état construit à partir des seules lectures réussies,
   remplacement atomique, désabonnement des absents.
6. `Makefile` : `pipefail`, échec si `codesign` échoue ; `uninstall` désinscrit
   l'ouverture à la connexion, ne masque plus `tccutil`, supprime `build/`.
7. Journal : plus de position du pointeur.

**Lot P2** : cas limites de l'écart (9, 10), purge des écritures en attente (11),
lectures hors fil principal (12), menu vivant (13), `NaN` (14), échecs visibles (15).

**Lot P3 / v2** : extraire la machine d'états d'`AppDelegate` (18), une seule autorité
« pris en charge » (19), isolation de concurrence par le compilateur (20), routeur
multi-backend avant DDC/CI (21).

## Correctifs appliqués (lots P1 et P2, 22 novembre 2026)

| # | Ce qui a changé | Où | Test |
|---|---|---|---|
| 1 | Relecture du matériel à la fermeture de la fenêtre d'écho ; un écart est traité comme un changement externe | `BrightnessController.scheduleReconcile` | `testExternalChangeInsideEchoRangeIsReconciled` |
| 2 | Debug et tests signés ad hoc, identifiant `…SimpleBrightness.debug` : exigence désignée = empreinte, aucun héritage de l'autorisation | `project.yml` | vérifié par `codesign -d -r-` |
| 3 | Notifications ignorées pendant la stabilisation ; synchro suspendue jusqu'à la dernière relecture utile (0,6 s, 3 s, puis 6 et 10 s seulement si un écran reste non pris en charge ou non observé) ; F1/F2 relisent le matériel avant le pas | `AppDelegate.runSettlePass`, `BrightnessController.isSettling`, `refresh` | `testNotificationsIgnoredWhileSettling`, `testRefreshReadsHardwareBeforeStep` ; sur matériel : fermeture du capot, relectures à 0,6 et 3 s puis arrêt |
| 4 | Numéro de génération par écriture ; échec périmé ignoré ; en synchro, le groupe est réaligné sur la valeur réelle | `CoalescingWriter`, `writeDidFail` | `testStaleWriteFailureIsIgnored`, `testCurrentWriteFailureRealignsTheGroup`, `testFailureReportsItsGeneration` |
| 5 | Nouvel état construit à partir des seules lectures réussies, remplacé d'un bloc ; tout écran absent est oublié (cache, échos, abonnement, écritures en attente) | `updateDisplays`, `forget` | `testUnreadableDisplayIsDroppedCompletely` |
| 6 | Le garde-fou vérifie la signature et échoue si `codesign` échoue | `Makefile` | `make install` passé |
| 7 | `make uninstall` désinscrit l'ouverture à la connexion (option `--unregister-login-item` de l'app), ne masque plus `tccutil`, supprime `build/` | `Makefile`, `LoginItem` | option essayée sur le build Debug |
| 8 | Plus de position du pointeur dans les journaux ; décodage des touches extrait et testé | `BrightnessKeyTap.decode` | `KeyDecodingTests` |
| 9, 10 | Synchro par un **niveau** commun non borné (celui de l'écran interne) : un pas de touche déplace le niveau une seule fois | `setLevel`, `step` | `testStepNearTheTopKeepsTheRelation`, `testMirroredStepWithOffsetNeverGoesBackwards` ; sur matériel : « pas de saut » près du maximum |
| 11 | Écritures en attente purgées à la veille, au changement de session et au retrait d'un écran | `AppDelegate`, `forget` | `testCancelPendingDropsQueuedWrites` |
| 12 | Mesuré : lecture ≈ 0,04 ms (pic isolé 86 ms), écriture ≈ 0,004 ms. Lectures conservées sur le fil principal (rares, hors chemin des touches sauf pendant une stabilisation) ; lectures et écritures sérialisées par un verrou dans le backend | `DisplayServicesBackend.ioLock` | mesure du 22/11 |
| 13 | Menu ouvert reconstruit à chaque changement d'écrans | `StatusMenuController.displaysDidChange` | sur matériel : « menu à jour » |
| 14 | `NaN` rejeté (notification, préférence, réglages) | contrôleur, backend, `Preferences` | `testNaNIsRejected` |
| 15 | Échec d'abonnement journalisé en erreur et retenté pendant la stabilisation ; échec de l'ouverture à la connexion affiché dans une alerte | backend, `LoginItem`, menu | `testFailedObservationIsReported` |
| 16 | Échos oubliés avant la veille | `resetEchoes` | `testResetEchoesCancelsReconcile` |
| 20 | `onChange` et l'état d'observation isolés sur le MainActor par le compilateur ; le singleton des notifications reste (P3) | backend | compilation Swift 6 |

À revérifier sur matériel : débranchement et rebranchement réels du Studio Display avec
cette version (le contrôle du 22/11 n'a exercé que la fermeture du capot).
