# Audit SimpleBrightness — 22 novembre 2026

Périmètre : arbre de travail (dépôt sans commit), version 0.1.0 (1). Lecture de `README.md`, `docs/FAISABILITE.md`, `docs/TESTS-MATERIELS.md`, `project.yml`, `Makefile`, de tout `SimpleBrightness/` et de `SimpleBrightnessTests/`. `codesign` sur les builds Debug, Release et `/Applications/SimpleBrightness.app`. Recherche de réseau, gamma et télémétrie. L'app n'a pas été lancée, la luminosité n'a pas été modifiée, les tests n'ont pas été rejoués : l'hôte de test est l'app elle-même.

Aucun constat critique. Dix constats, regroupés par axe puis par gravité.

## 1. Qualité du code

Le cœur de synchro est lisible, commenté, et couvert par 21 tests (échos, convergence, suspension, rebranchement sans écriture, écart). Les défauts sont des états qui divergent du matériel dans des fenêtres que ces tests ne construisent pas.

### 1. Intervalle d'écho : un vrai changement est ignoré — importante

Preuve : `SimpleBrightness/Hardware/BrightnessController.swift:205-220` (chaque écriture mémorise tout l'intervalle `[ancienne, nouvelle]` pendant `echoWindow` = 2 s) et `:58` (horloge `ProcessInfo.processInfo.systemUptime`). Le commentaire d'en-tête Apple de `systemUptime` la définit comme le temps passé éveillé depuis le boot. Vérifié dans le code et dans cet en-tête. Non mesuré ici pendant une veille.

Scénario : synchro active, l'écran interne passe de 20 % à 80 % (touche maintenue ou curseur). Pendant deux secondes, toute notification entre 20 % et 80 % sur cet écran est classée écho (`isEcho`), le cache reste à 80 %, la synchro ne propage pas. Un mouvement du Centre de contrôle vers 50 % est donc ignoré. L'appui suivant part de 80 % et saute. Si la veille commence juste après le geste, `systemUptime` ne avance pas pendant le sommeil : la fenêtre de deux secondes reprend au réveil, et la valeur restaurée par macOS, si elle tombe dans l'intervalle, est jetée. Le cache peut rester faux jusqu'au prochain événement hors intervalle. `testRampingPanelIsNotMistakenForExternalChange` fige ce comportement pour les valeurs intermédiaires ; aucun test ne place un changement externe à l'intérieur de l'intervalle, ni une veille.

Correction : ne traiter comme écho qu'une valeur qui se rapproche de la dernière valeur commandée. Purger `recentWrites` à la veille et au réveil. Horloge qui continue de courir pendant le sommeil, ou horodatage mur.

### 2. Échec d'écriture : les écrans synchronisés divergent — importante

Preuve : `BrightnessController.swift:205-213` (le cache est mis à jour avant l'écriture), `:109` et `:191-198` (la synchro envoie tout de suite les autres écrans), `:178-184` (`writeDidFail` ne relit que l'écran en échec). `CoalescingWriter.swift:44-58` signale l'échec plus tard, sans identifiant de valeur, puis enchaîne. Vérifié dans le code. `testFailedWriteRestoresHardwareValue` ne couvre que l'écran source, synchro coupée.

Scénario : synchro active, interne et Studio à 50 %. L'utilisateur demande 80 % sur l'interne. L'interne et le Studio sont déjà à 80 % dans le cache. L'écriture Studio réussit, celle de l'interne échoue. `writeDidFail` remet l'interne à 50 %. Le Studio reste à 80 %. Rien ne les réaligne. Variante pendant un glisser : l'échec d'une valeur ancienne arrive après une valeur plus récente, efface `recentWrites` et relit le matériel trop tôt. Le cache recule, puis l'écho de la valeur récente est pris pour un changement externe et repart en synchro.

Correction : n'envoyer les autres écrans qu'une fois l'écriture source acquittée, ou, à l'échec, relire tout le groupe et réappliquer la relation. Ignorer un échec périmé (génération par écran).

### 3. La synchro reprend à 3 s, les relectures continuent jusqu'à 10 s — importante

Preuve : `SimpleBrightness/App/AppDelegate.swift:171-189`. À 3 s, `isSettling` passe à faux dans le même bloc qui vient d'appeler `reloadDisplays()`. Les passages à 6 s et 10 s restent armés. `BrightnessController.swift:91-96` réécrit le cache avec une lecture brute et garde les `recentWrites` des écrans encore présents. `hardwareDidChange` (`:164-173`) propage dès que la suspension est levée. Les notifications DisplayServices sont renvoyées sur la file principale en asynchrone (`DisplayServicesBackend.swift:129-132`), donc après le bloc qui lève la suspension. Vérifié dans le code. Le test matériel 16 n'a pas montré de saut attribué à l'app : l'effet visible reste à confirmer sur matériel.

Scénario : rebranchement ou réveil. À 3 s la synchro est rouverte alors que le commentaire de `displaysDidChange` prévoit encore des contrôles à 6 s et 10 s. Une notification fausse (« 100 % », documentée dans `docs/FAISABILITE.md` pour ce rebranchement) en file au moment du réabonnement est traitée synchro déjà active et recopie 100 % sur les autres écrans. Dès qu'un écran non pris en charge est dans la liste, `pendingUnsupported` reste vrai : les relectures de 6 s et 10 s ont lieu pendant que l'utilisateur peut déjà agir. Une lecture qui retourne l'ancienne valeur écrase le cache d'un appui fait à 4 s ; l'écho de l'écriture en vol est ensuite avalé par l'intervalle du constat 1. Le prochain cran part de la mauvaise valeur.

Correction : garder `isSuspended` jusqu'au dernier passage utile, et ne lever la suspension qu'après traitement des notifications nées de ce passage. À chaque `updateDisplays` de stabilisation, remplacer le cache sans conserver des `recentWrites` d'avant la relecture.

### 4. Menu ouvert : topologie figée — mineure

Preuve : `StatusMenuController.swift:46-52` reconstruit le menu à l'ouverture et vide les curseurs à la fermeture. `brightnessDidChange` (`:42-44`) ne met à jour que les curseurs déjà créés. Aucun appel depuis `displaysDidChange`.

Scénario : le menu est ouvert, l'utilisateur débranche le Studio Display. La ligne reste. Un glisser appelle `setBrightness` sur un écran déjà retiré de `values`, donc sans effet (`BrightnessController.swift:107`). L'écran rebranché n'apparaît qu'à la réouverture.

Correction : reconstruire le menu s'il est ouvert à la fin de `reloadDisplays`.

## 2. Sécurité

Contrôles qui tiennent. Le tap n'écoute que le type 14 (`BrightnessKeyTap.swift:54`) et ne consomme que les codes 2 et 3. Aucune chaîne `http`, télémétrie ou gamma dans le binaire Release. Release et l'app installée n'ont aucun entitlement (`codesign -d --entitlements -`), runtime durci (`flags=0x10000`), signature Developer ID. Les trois binaires (Debug, Release, `/Applications`) partagent la même exigence désignée : identifiant `com.jcbaptiste.SimpleBrightness`, équipe `26N2RN6N67`.

### 5. Le build Debug hérite de l'Accessibilité et accepte un débogueur — importante

Preuve : `project.yml:11-14` (identité Developer ID pour toutes les configurations), `:28` (même bundle ID), `:36-41` (`CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` seulement en Release). `codesign` sur `build/DerivedData/Build/Products/Debug/SimpleBrightness.app` : `com.apple.security.get-task-allow = true`, même exigence désignée que Release et que `/Applications/SimpleBrightness.app`. Le droit `temporary-exception.files.absolute-path.read-only` sur `/` est aussi présent ; l'app n'est pas sandboxée (`project.yml:35`), ce droit n'ajoute donc pas d'accès disque. L'attachement réel par `task_for_pid` n'a pas été rejoué.

Scénario : l'utilisateur a autorisé l'app installée. Un programme qu'il exécute déjà lance le binaire Debug resté dans `build/` et s'y attache, ce que `get-task-allow` permet. Le processus débogué porte l'autorisation Accessibilité du fait de l'exigence désignée commune. L'injection qui suit pilote l'interface sans nouvelle invite. Le binaire Release, lui, n'a pas ce droit.

Correction : bundle ID et signature de développement distincts pour Debug et pour l'hôte de tests. Réserver Developer ID au Release.

### 6. Désinstallation incomplète, échec masqué — importante

Preuve : `Makefile:25-29`. La recette quitte l'app, supprime le bundle, efface les préférences, puis `tccutil reset … || true`. Aucun `SMAppService.mainApp.unregister()`. Le README (lignes 106-112) demande à l'utilisateur de décocher « Ouvrir à la connexion » avant. `LoginItem.swift:10-22` journalise l'erreur et ne la montre pas dans le menu.

Scénario : « Ouvrir à la connexion » est coché, l'utilisateur lance `make uninstall` sans décocher. L'entrée reste dans Réglages Système. Au prochain login, macOS relance un bundle absent ; une réinstallation au même chemin retrouve l'entrée active. Si `tccutil` échoue (code ignoré), l'autorisation Accessibilité reste attachée à l'exigence désignée du constat 5. `defaults delete` ne retire ni l'entrée de login ni TCC.

Correction : désenregistrer l'entrée tant que le bundle est encore là, et faire échouer la recette si `tccutil` échoue. Après coup, afficher l'état réel (TCC, login) plutôt qu'un succès systématique.

### 7. Position du pointeur écrite en clair dans le journal — mineure

Preuve : `BrightnessKeyTap.swift:128`, `privacy: .public` sur `press.location`. `DisplayManager.swift:61-62` évite au contraire de journaliser les noms d'écrans. Les autres interpolations de luminosité restent au défaut privé d'Logger. Journal réel non capturé.

Scénario : chaque F1/F2 enregistre les coordonnées du pointeur au niveau debug. `log show` sur la machine les restitue. Elles situent l'activité à l'écran. Aucune de ces données ne sort du Mac : aucun canal réseau trouvé.

Correction : retirer `.public` sur la position, ou ne plus la journaliser.

### 8. Le garde-fou `get-task-allow` réussit si `codesign` échoue — mineure

Preuve : `Makefile:15`. `set -o pipefail` est absent. Le statut du pipeline est celui de `grep`. `codesign` envoie ses erreurs vers `/dev/null`.

Scénario : le binaire est absent ou illisible par `codesign`. `grep` ne voit rien, `!` inverse l'échec en succès, `make build` annonce un Release sain. Quand `codesign` réussit et que le droit est présent, le refus fonctionne.

Correction : `pipefail`, et échouer si `codesign` lui-même échoue.

## 3. Architecture

Découpage net : cycle de vie (`AppDelegate`), topologie publique (`DisplayManager`), politique de synchro testable (`BrightnessController`), écritures hors file principale (`CoalescingWriter`), API privées isolées (`DisplayServicesBackend`, `BrightnessOSD`). `BrightnessBackend` est la bonne couture pour un second moteur. Les `MainActor.assumeIsolated` lus sont précédés d'un passage par la file principale, par une notification posée sur cette file, ou par le run loop principal (source du tap ajoutée à `CFRunLoopGetMain`, `BrightnessKeyTap.swift:65`).

### 9. Un second backend DDC/CI demande un composite qui n'existe pas — mineure

Preuve : le protocole (`BrightnessBackend.swift:12-30`) est par écran, en 0…1, avec `supports`. `AppDelegate.swift:34` instancie `DisplayServicesBackend()` en dur. `DisplayServicesBackend.swift:45` et `:76` : un singleton statique `current` reçoit tous les callbacks ; une seconde instance volerait les notifications de la première. Les erreurs sont un `Bool` (`:21`, `:91-97`). `CoalescingWriter.swift:58` bloque un thread de la file concurrente pendant `minInterval` après chaque écriture.

Scénario : un backend DDC coexiste avec DisplayServices. Sans objet composite, il faut modifier `AppDelegate` et le singleton. Un aller-retour DDC de plusieurs dizaines de millisecondes occupe le thread de drain ; le sleep de 25 ms s'y ajoute. L'échec ne dit pas « écran occupé » ou « non branché », seulement faux, ce qui empêche le constat 2 de décider.

Correction : un `CompositeBackend` qui route `supports` / lecture / écriture / observation, créé hors du singleton DisplayServices. Erreur typée. Pour DDC, limiter le débit sans dormir sur le thread qui enchaîne les écrans.

### 10. Lecture et écriture DisplayServices se croisent — mineure, supposé

Preuve : `setBrightness` est appelé depuis la file du writer (`CoalescingWriter.swift:40-53`, `AppDelegate.swift:36`). `brightness(of:)` l'est sur l'acteur principal (`BrightnessController.swift:92` et `:181`, `DisplayServicesBackend.swift:79-87`). Les deux touchent le même écran via `getFn` / `setFn`. Vérifié que les appels se croisent. Non vérifié que la framework privée supporte ce croisement : les tests matériels de la synchro ont réussi sans exercer cet échec.

Scénario : relecture de stabilisation ou `writeDidFail` pendant qu'un `setBrightness` du même écran est encore dans DisplayServices. Si l'API privée n'est pas réentrante, valeur fausse ou plantage. Le singleton et l'absence de file série par écran empêchent de le garantir.

Correction : sérialiser get et set d'un même écran sur la file du writer, et ne relire qu'entre deux écritures.

## Notes

| Axe | Note |
|---|---|
| Qualité du code | **7 / 10** |
| Sécurité | **7 / 10** |
| Architecture | **8 / 10** |

La politique « rien écrire au lancement » est tenue pour le chemin explicite : `setSyncEnabled(_, reference: nil)` (`AppDelegate.swift:50-51`, test `testRestoringSyncAtLaunchDoesNotAlign`). Le Release vérifié est propre. Les trous sont des fenêtres d'état et l'identité partagée du build Debug.

## Recommandations

1. Resserrer le filtre d'écho sur la valeur commandée, le purger à la veille, et ne rouvrir la synchro qu'après la dernière relecture de stabilisation.
2. Donner au Debug un bundle ID et une signature distincts de l'app qui détient l'Accessibilité. Faire échouer `make build` quand `codesign` échoue.
3. À l'échec d'une écriture, réaligner tout le groupe synchronisé. Faire de `make uninstall` la désinstallation réelle : login item, puis `tccutil` dont l'échec est visible.
