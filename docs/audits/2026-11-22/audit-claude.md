# Audit indépendant de SimpleBrightness (Claude, 22/11/2026)

**Périmètre** : tout le code de `SimpleBrightness/` et `SimpleBrightnessTests/`, plus `project.yml`, `Makefile`, `README.md`, `docs/FAISABILITE.md` et `docs/TESTS-MATERIELS.md`. Je n'ai pas lu les autres rapports d'audit présents dans `docs/`.

**Ce que j'ai exécuté**
- `xcodebuild … test`, avec les données dérivées dans le dossier temporaire : **21 tests, 0 échec**. La compilation en mode Swift 6 (`-swift-version 6`) ne produit aucun avertissement de concurrence.
- `codesign -d` sur les builds existants.
- Des `grep` sur le code.

Je n'ai lancé l'app à aucun moment et je n'ai touché à aucune luminosité.

**Légende** : [V] = vérifié (code lu, commande exécutée), [S] = supposé (raisonnement ou comportement de macOS non mesuré ici).

**Points solides vérifiés**
- Le tap clavier est abonné au seul `NX_SYSDEFINED` (`BrightnessKeyTap.swift:54`), et tout ce qui n'est pas F1/F2 est rendu intact.
- Aucune API réseau, aucun `Process`, aucun fichier écrit en dehors de `UserDefaults` (grep).
- `dlopen` utilise des chemins système absolus.
- Le runtime renforcé est actif et la vérification des bibliothèques n'est pas désactivée.
- Le build Release ne porte pas `get-task-allow`.
- Rien n'est écrit au lancement (testé).
- Aucun minuteur au repos : seuls quatre `asyncAfter` sont prévus, en nombre borné, après un événement.

Aucun constat **critique**.

---

## 1. Qualité du code

### Q1 — Une frappe pendant la stabilisation peut faire sauter la luminosité, à partir d'une valeur fausse — **importante**
- **Preuve [V]**
  - `BrightnessController.swift:164-170` : `hardwareDidChange` met à jour le cache même quand la synchro est suspendue.
  - `AppDelegate.swift:80-92` : `handleKey` ne tient aucun compte de `isSettling` et part de ce cache.
  - `AppDelegate.swift:175-185` : la fenêtre de stabilisation est fixe, 3 s après le dernier rappel de reconfiguration.
  - `docs/FAISABILITE.md` : au rebranchement, DisplayServices envoie environ 30 fois « 100 % » pour l'écran interne.
- **Scénario [S, chemin de code vérifié]** : l'écran interne est à 50 %. On rebranche le Studio Display, puis on appuie sur F1, pointeur sur l'écran interne, à t ≈ 1,5 s. Une notification « 100 % » a écrasé le cache après la relecture faite à 0,6 s. `step` calcule alors 15/16 et **écrit 93,75 %** sur l'écran interne. C'est un saut brutal, interdit par le client.
  - Variante : si la rafale déborde au-delà de 3 s (le délai repose sur une seule mesure), la synchro reprend et propage « 100 % + écart » au Studio.
- **Correction**
  - Pendant `isSettling`, ne pas alimenter le cache par les notifications : ne retenir que les relectures.
  - Dans `handleKey`, si la stabilisation est en cours, relire le matériel avant le pas, ou rendre la touche à macOS.
  - Terminer la stabilisation sur un critère de calme (aucune notification pendant N ms) plutôt que sur un délai fixe.
  - Ajouter un test.

### Q2 — Le filtre d'échos absorbe de vrais changements extérieurs ; cache et synchro divergent durablement — **importante**
- **Preuve [V]** : `BrightnessController.swift:205-220`. Chaque écriture enregistre l'intervalle `[ancienne valeur, nouvelle valeur]` pendant 2 s, et toute notification qui tombe dans cet intervalle est ignorée (`:168`). Rien ne relit le matériel ensuite.
- **Scénario [V par lecture]** : synchro active. F2 fait passer l'écran interne de 0,50 à 0,5625. Dans les 2 s, la luminosité automatique ou Control Center l'amène à 0,53, puis s'arrête. 0,53 est dans [0,49 ; 0,5725], donc la valeur est traitée comme un écho.
  - Le Studio n'est pas réaligné.
  - Le curseur du menu affiche 56 %.
  - Le prochain F1 part de 0,5625 au lieu de 0,53.
  - L'écart persiste jusqu'au prochain changement, ce qui est exactement le cas « auto-luminosité + touches » validé par le test matériel 12.
- **Correction** : à la fin de la fenêtre d'écho (une seule tâche différée par écran, annulée à chaque nouvelle écriture), relire une fois le matériel. Si la valeur diffère du cache au-delà de la tolérance, la traiter comme un changement extérieur. Ajouter un test « changement extérieur dans la fenêtre ».

### Q3 — Lectures matérielles synchrones sur le fil principal, qui porte aussi le tap clavier — **mineure, à mesurer**
- **Preuve [V]**
  - `DisplayManager.swift:59` : `supports`, qui appelle `canFn` et `getFn`.
  - `BrightnessController.swift:92` et `:181` : nouvelle lecture du même matériel.
  - `BrightnessKeyTap.swift:65` : la source du tap est sur `CFRunLoopGetMain`.
  - Le commentaire de `CoalescingWriter.swift:10` affirme pourtant que le fil principal reste libre.
- **Scénario [S]** : après chaque reconfiguration, jusqu'à quatre relectures ont lieu (0,6 / 3 / 6 / 10 s). Chacune coûte trois allers-retours DisplayServices par écran (par USB pour le Studio). Si un appel bloque pendant la phase où le Studio « n'est pas prêt », toutes les touches système (volume, lecture, luminosité) attendent le tap. Cela peut aller jusqu'à `tapDisabledByTimeout`, ce qui contredit l'exigence « ne pas monopoliser le clavier ».
- **Correction** : faire les lectures de topologie et de valeurs sur une file en arrière-plan, puis appliquer le résultat sur le fil principal. Mesurer la durée de `getFn` pendant le rebranchement.

### Q4 — `updateDisplays` laisse un état incohérent si la relecture échoue — **mineure**
- **Preuve [V]** : `BrightnessController.swift:91-97`. Dans le `guard … else { continue }`, l'écran est retiré de `displays`, mais `values[display]` conserve l'ancienne valeur et l'abonnement reste actif. `isSupported` (`:69`) répond donc encore `true`.
- **Scénario [S]** : `DisplayManager` réussit sa lecture, puis celle du contrôleur, faite juste après, échoue pendant un rebranchement.
  - F1 cible quand même cet écran (`AppDelegate.swift:86`) et part d'une valeur périmée.
  - Le menu affiche un curseur périmé (`StatusMenuController.swift:63`).
  - L'écran n'est plus synchronisé, car `propagate` parcourt `displays`.
- **Correction** : dans le `else`, faire `values[display] = nil`, `recentWrites[display] = nil` et `stopObserving`.

### Q5 — Avec l'écart, le bornage casse la relation et provoque un saut sur l'autre écran — **mineure**
- **Preuve [V]** : `BrightnessController.swift:191-199`. La cible est bornée à 0–1, puis la propagation inverse repart de la valeur bornée.
- **Scénario [V par calcul]** : écart +10 %, écran interne à 0,95, donc Studio à 1,0 (borné). F1 sur le Studio donne 0,9375, et l'écran interne passe à 0,8375. **Une frappe fait −11 % sur l'écran interne** au lieu de −6 %. Symétrique en bas de plage avec un écart négatif.
- **Correction** : conserver un « niveau de référence » non borné (celui de l'écran interne) et ne borner qu'à l'écriture. Ou, quand la source est bornée, propager depuis la valeur virtuelle. Ajouter un test.

### Q6 — Des erreurs avalées ou invisibles — **mineure**
- **Preuve [V]**
  - `DisplayServicesBackend.swift:103-105` : un échec d'abonnement n'est journalisé qu'en `debug`, et rien ne retente avant la prochaine reconfiguration. Le cache se périme alors en silence, ce qui produit des pas faux et une synchro muette.
  - `LoginItem.swift:20-22` : l'échec de `register` n'est que journalisé. La case se réaffiche décochée sans explication.
  - `AppDelegate.swift:111` : le jeton d'observation n'est pas conservé.
- **Correction** : journaliser l'échec d'abonnement en `error`, avec une nouvelle tentative bornée. Afficher l'échec de l'ouverture à la connexion dans le menu (élément désactivé ou alerte).

### Q7 — Les NaN ne sont filtrés ni dans les notifications ni dans les préférences — **mineure**
- **Preuve [V]**
  - `DisplayServicesBackend.swift:127` : `min(max(NaN,0),1)` vaut `NaN` en Swift, alors que le getter vérifie `isFinite` (`:86`).
  - `Preferences.swift:16-19` : `syncOffset` n'est pas validé, et `setSyncOffset` ne bloque pas non plus `NaN` (`BrightnessController.swift:150`).
- **Scénario [S]**
  - Avec `defaults write … syncOffset -float nan`, toute propagation devient silencieusement inopérante (la comparaison `abs(...) > seuil` est fausse) et le curseur affiche « NaN ».
  - Une notification NaN mettrait NaN en cache ; le pas suivant appellerait `setFn(display, NaN)`.
- **Correction** : `guard value.isFinite` dans le rappel, `isFinite` sinon 0 à la lecture de la préférence, et `precondition` dans `apply`.

### Q8 — Tests manquants ou fragiles — **mineure**
- **Preuve [V]** : seul `BrightnessController` est testé (21 tests verts). Ne sont pas couverts :
  - `CoalescingWriter` (fusion, échec, concurrence) ;
  - le décodage `data1` du tap (`BrightnessKeyTap.swift:109-127`), pourtant réductible à une fonction pure ;
  - la machine d'états veille/session/stabilisation (`AppDelegate`, voir A1) ;
  - les cas Q1, Q2, Q4 et Q5.
- Trois faux backends et trois faux writers sont quasi identiques. `FailingBackend.setBrightness` n'est jamais appelé, donc son nom est trompeur. La suite `BrightnessControllerAuditTests` est un fourre-tout.
- **Correction** : un seul faux partagé, des tests du writer avec une horloge et une file injectées, un parseur de touche testé, et les cas listés ci-dessus.

### Q9 — Lisibilité : champs morts et commentaire inexact — **mineure**
- **Preuve [V]**
  - `Press.location` et `Press.isRepeat` (`BrightnessKeyTap.swift:22-24`) ne servent qu'au journal ; `handleKey` relit le pointeur (`AppDelegate.swift:85`).
  - Les constantes 0,6 / 3 / 6 / 10 s sont dans le code (`AppDelegate.swift:175`).
  - Le commentaire de `CoalescingWriter.swift:10` est contredit par Q3.
- **Correction** : utiliser `press.location` ou supprimer ces champs, et nommer les délais.

---

## 2. Sécurité

### S1 — Le build Debug/test hérite de l'autorisation Accessibilité et porte `get-task-allow` — **importante**
- **Preuve [V]**
  - `project.yml:15-16` : signature *Developer ID Application* pour **toutes** les configurations.
  - `project.yml:33-37` : `CODE_SIGN_INJECT_BASE_ENTITLEMENTS: NO` en Release seulement.
  - `Makefile:18-19` : `make test` produit un build Debug dans `build/`.
  - `codesign -d --entitlements -` sur `build/DerivedData/Build/Products/Debug/SimpleBrightness.app` montre `get-task-allow = true`, le même identifiant `com.jcbaptiste.SimpleBrightness` et la même exigence désignée (`anchor apple generic … subject.OU = "26N2RN6N67"`) que le build installé.
  - Le build de test lancé ici porte en plus `temporary-exception.files.absolute-path.read-only /`.
- **Scénario [S, comportement standard de TCC]** : TCC rattache l'autorisation Accessibilité à l'exigence désignée, qui est la même pour les deux builds. Un code malveillant déjà exécuté sous l'utilisateur lance le build Debug resté dans `build/`. Il s'y attache avec `task_for_pid`, permis par `get-task-allow` sur un Mac de développeur, et y injecte du code. Il obtient ainsi l'Accessibilité, donc l'observation et le pilotage de toute l'interface, sans aucune invite. Le garde-fou du `Makefile` ne protège que Release.
- **Correction**
  - En Debug, un identifiant distinct (`…SimpleBrightness.debug`) et une signature *Apple Development* ou ad hoc, pour que l'exigence désignée diffère.
  - À défaut, `CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO` partout et `make clean` après les tests.
  - À terme, héberger les tests dans une cible qui n'est pas l'app.

### S2 — La notification `com.apple.accessibility.api` peut être émise par n'importe qui — **mineure (information)**
- **Preuve [V]** : `AppDelegate.swift:108-120`.
- **Scénario** : un processus tiers peut poster cette notification distribuée. L'effet se limite à un appel `AXIsProcessTrusted()` et à une éventuelle création du tap si l'autorisation existe déjà. Aucune élévation n'est possible et le coût est négligeable.
- **Correction** : aucune nécessaire. Le commentaire pourrait le préciser.

### S3 — Désinstallation et distribution incomplètes — **mineure**
- **Preuve [V]**
  - `make uninstall` (`Makefile:28-32`) ne désinscrit pas l'élément d'ouverture à la connexion (`SMAppService`) : il compte sur l'utilisateur (README) et laisse une entrée orpheline dans Réglages › Ouverture.
  - Il ne supprime pas `build/`, qui contient le build Debug de S1.
  - `spctl -a -vv /Applications/SimpleBrightness.app` répond `rejected, Unnotarized Developer ID` : c'est attendu et documenté, mais tout envoi à un tiers sera bloqué.
- **Correction** : quitter l'app via une option qui appelle `SMAppService.mainApp.unregister()`, ou documenter `sfltool`. Faire `rm -rf build` dans `uninstall`. Automatiser `notarytool` et `stapler` dans une cible `make release`.

**Journaux et données personnelles [V]** : pas de nom d'écran journalisé (`DisplayManager.swift:61`). Seules les coordonnées du pointeur sont publiques, au niveau `debug` (`BrightnessKeyTap.swift:128`), qui n'est pas persisté par défaut. Aucune touche ordinaire n'est vue. Rien à signaler au-delà.

**API privées [V]**
- `dlsym` avec un échec propre (`DisplayServicesBackend.swift:53-70`).
- Les `unsafeBitCast` reposent sur des signatures documentées. Celle de l'OSD a été vérifiée contre l'encodage de type cité (`BrightnessOSD.swift:12-17`), et j'ai contrôlé qu'elle correspond paramètre par paramètre (`q`, 5×`I`, `B`).
- Risque résiduel [S] : une signature C modifiée par Apple serait un comportement indéfini sans détection possible. C'est inhérent au choix imposé.

---

## 3. Architecture

### A1 — `AppDelegate` concentre la logique la plus fragile, sans aucun test — **importante**
- **Preuve [V]** : `AppDelegate.swift:20-26` et `:164-236`. Veille, écrans en veille, session, stabilisation, suspension, autorisation, choix de la cible clavier et bascule de la synchro vivent dans le délégué, sous forme de booléens et de `DispatchWorkItem` sur la vraie horloge.
- **Scénario** : c'est précisément cette zone qui a déjà produit le bug du test matériel 16 (Studio resté « non pris en charge »), et Q1 en découle. Aucune régression n'y est détectable avant un essai matériel.
- **Correction** : extraire un `SystemStateMonitor` ou `SuspensionPolicy` (état explicite, horloge et ordonnanceur injectés) et un `KeyCommandHandler` (résolution de la cible, pas, OSD), testables unitairement. `AppDelegate` se limiterait au câblage.

### A2 — Deux sources de vérité pour « pris en charge », et des lectures en double — **mineure**
- **Preuve [V]**
  - `DisplayManager.swift:59` : `backend.supports`.
  - `BrightnessController.swift:69`, `:92` : `values != nil`.
  - L'UI combine les deux (`StatusMenuController.swift:63`), le clavier n'utilise que le second (`AppDelegate.swift:86`).
- **Scénario** : voir Q4 ; chaque relecture interroge aussi deux fois le matériel (Q3).
- **Correction** : `DisplayManager` reste purement topologique (public, sans backend) et `BrightnessController` est l'unique autorité sur la prise en charge.

### A3 — L'abstraction de backend n'est pas prête pour DDC/CI — **mineure aujourd'hui, importante pour la v2**
- **Preuve [V]**
  - Un seul backend est injecté dans `BrightnessController` (`:35`), dans `DisplayManager` (`:20`) et dans la fermeture du writer (`AppDelegate.swift:36`).
  - `onChange` n'a qu'un seul abonné (`BrightnessBackend.swift:29`).
  - L'observation est obligatoire dans le protocole (`:24-25`), alors que DDC/CI n'a pas de notifications.
  - L'intervalle de 25 ms (`CoalescingWriter.swift:29`) est global, alors qu'il faut environ 50 à 100 ms par bus I²C pour DDC.
- **Scénario** : ajouter DDC/CI forcerait à toucher le contrôleur, le writer, le gestionnaire d'écrans et le délégué. L'absence de notifications rendrait de plus le filtre d'échos et la synchro bidirectionnelle sans objet pour ces écrans, sauf à ajouter de l'interrogation, que le client exclut.
- **Correction**
  - Un `BrightnessRouter` (composite) qui choisit le backend par écran.
  - Des capacités déclarées (`canNotify`, `minWriteInterval`, `readCost`).
  - Un writer paramétré par écran.
  - Une synchro unidirectionnelle (interne vers DDC) pour les écrans sans notifications.

### A4 — Contrats de concurrence tenus par des commentaires plutôt que par le compilateur — **mineure**
- **Preuve [V]**
  - `DisplayServicesBackend` est `@unchecked Sendable`, avec `onChange` et `observed` mutables non isolés (`:27`, `:47-49`) ; seul le commentaire de `:47` les protège.
  - Même chose pour `CoalescingWriter.onFailure` (`:25`).
  - Le protocole mélange des E/S `Sendable` et une observation `@MainActor` (`BrightnessBackend.swift:11-29`).
  - `Unmanaged.passUnretained(self)` est passé à des rappels C jamais désinscrits (`DisplayManager.swift:30-31`, `BrightnessKeyTap.swift:60`), ce qui ne tient que parce que les objets vivent aussi longtemps que l'app.
  - Les `MainActor.assumeIsolated` sont corrects [V] : on y arrive toujours via `DispatchQueue.main` ou la boucle principale.
- **Correction**
  - Scinder le protocole en `BrightnessIO: Sendable` (sans état) et `@MainActor BrightnessObserving`.
  - Marquer `onChange` et `observed` comme `@MainActor`.
  - Ajouter un `deinit` qui désinscrit, ou documenter et garantir la durée de vie (`static let shared`).

---

## Notes globales

| Axe | Note |
|---|---|
| Qualité du code | **7 / 10** : code clair, court, bien commenté, tests utiles et verts. Deux défauts de logique réels (Q1, Q2) dans les cas limites de la synchro. |
| Sécurité | **7 / 10** : surface minimale et bien tenue (tap restreint, pas de réseau, runtime renforcé, Release propre). Le build Debug signé à l'identique avec `get-task-allow` ouvre une voie vers l'autorisation Accessibilité. |
| Architecture | **6,5 / 10** : couches matériel/logique/UI nettes et API privées bien isolées. La machine d'états du cycle de vie est enfermée dans `AppDelegate`, il y a deux autorités sur la prise en charge, et le backend unique n'est pas prêt pour DDC/CI. |

## Trois recommandations prioritaires

1. **Séparer l'identité du build Debug/test** : bundle ID `.debug` et signature *Apple Development* ou ad hoc, pour qu'aucun binaire avec `get-task-allow` ne puisse hériter de l'autorisation Accessibilité (S1). Supprimer `build/` à la désinstallation.
2. **Fiabiliser le cache de luminosité** : ignorer les notifications pendant la stabilisation et relire avant un pas (Q1), relire une fois en fin de fenêtre d'écho (Q2), nettoyer l'état quand une lecture échoue (Q4). Chaque correctif avec son test unitaire.
3. **Extraire de `AppDelegate` la politique veille/session/stabilisation et la gestion des touches** dans des types testables à horloge injectée (A1), et faire de `BrightnessController` l'unique autorité sur la prise en charge (A2). C'est aussi la base nécessaire pour un futur routeur multi-backend (A3).
