# Étude de faisabilité — SimpleBrightness

Environnement de mesure : MacBook Pro M4 14", Apple Studio Display (firmware 17.0),
macOS 27.3 bêta (26C5035r), Xcode 27.2. Mesures faites le 21 novembre 2026 avec des
prototypes ciblés, puis avec l'app signée.

## Fonctionnalités confirmées (testées sur le matériel)

| Point | Méthode | Résultat |
|---|---|---|
| Lire / écrire la luminosité **matérielle** du Studio Display | `DisplayServicesGetBrightness` / `DisplayServicesSetBrightness` (privé) | OK, relecture exacte, rétroéclairage réel modifié |
| Idem pour l'écran interne | même API | OK (`supported=true`, réglé au clavier) |
| Observer les changements | `DisplayServicesRegisterForBrightnessChangeNotifications` (privé) | OK, y compris pour des changements faits par **un autre processus** ; `userInfo["value"]` |
| Se désabonner | `DisplayServicesUnregisterForBrightnessChangeNotifications(display, observer)` | OK |
| Capter F1/F2 sur le clavier du MacBook | `CGEventTap` actif sur `NX_SYSDEFINED`, `NX_KEYTYPE_BRIGHTNESS_UP/DOWN` (2/3) | OK après autorisation Accessibilité |
| Écran sous le pointeur | `CGGetDisplaysWithPoint` sur la position courante | OK sur les deux écrans |
| Capot fermé puis rouvert | `CGDisplayRegisterReconfigurationCallback` | Liste d'écrans mise à jour automatiquement |
| OSD de luminosité | `OSDManager` (privé, `OSD.framework`) | S'affiche, mais c'est **l'ancien** style d'OSD |
| Changements faits par Control Center et par l'auto-luminosité | Notifications DisplayServices | Observés (≈ 60/s pendant une transition) et propagés par la synchro |
| Retrait / retour de l'autorisation en cours d'exécution | `tapDisabledBy*` + `AXIsProcessTrusted`, notification `com.apple.accessibility.api` | Détectés, sans relancer l'app |
| Coût des appels DisplayServices | Mesure de 500 appels | Lecture ≈ 0,04 ms (pic isolé 86 ms sur le Studio), écriture ≈ 0,004 ms (mise en file auprès d'un service système) |

## Plausible mais non vérifié

- Changement rapide d'utilisateur (nécessite un second compte).
- Claviers externes (Magic Keyboard, tiers) : non testés.

## Limitations identifiées

- **Aucune API publique** ne règle la luminosité de l'écran interne ou d'un écran
  Apple sur Apple Silicon : `IODisplaySetFloatParameter` est sans effet. L'usage de
  DisplayServices est donc imposé, isolé dans `Hardware/DisplayServicesBackend.swift`.
- Les notifications de luminosité ne passent **par aucun canal public**
  (ni `DistributedNotificationCenter`, ni Darwin notify) : vérifié.
- **Nouvel OSD de macOS 27** : il est dessiné par Control Center
  (`showDisplayBrightness:value:max:isEnabled:` en interne) sans point d'entrée
  accessible. `DisplayServicesSetBrightnessWithType` (types 0 à 7) ne le déclenche
  pas : testé. Seul l'ancien OSD (`OSDManager`) est disponible. Une imitation
  dessinée par l'app (verre `NSGlassEffectView` sous l'horloge) a été essayée le
  22/11, puis abandonnée à la demande du client au profit de l'ancien OSD.
- Comportement natif de macOS 27.3 : les touches règlent **toujours le même écran**
  quel que soit le pointeur (l'écran interne capot ouvert, le Studio Display capot
  fermé). C'est ce que corrige l'app.
- Rebranchement d'un Studio Display : il réapparaît dans la liste des écrans environ
  **3 s avant** que DisplayServices puisse le lire ; pendant ce temps,
  DisplayServices envoie des valeurs fausses pour l'écran interne (« 100 % » × 28 à
  32). L'app tient la synchro suspendue et relit les valeurs après stabilisation.
- Au (dé)branchement, macOS fait lui-même varier l'écran interne (0,525 → 0,475 →
  0,525, mesuré app arrêtée).
- Un écran tiers (DDC/CI) apparaît « non pris en charge » : hors MVP, volontairement.
- Interception des touches : autorisation **Accessibilité** obligatoire (tap actif).
  Sans elle, macOS garde son comportement natif.
- Mac App Store impossible : API privées et tap actif incompatibles avec le bac à sable.

## Risques techniques

| Risque | Impact | Parade |
|---|---|---|
| Apple retire ou renomme un symbole DisplayServices | Plus de contrôle | Résolution par `dlsym` au lancement : l'app démarre, signale les écrans « non pris en charge », ne plante pas |
| `OSDManager` disparaît | Pas d'OSD | Vérification `responds(to:)`, aucun autre effet |
| Changement de format des événements `NX_SYSDEFINED` | Touches non captées | Les événements non reconnus sont rendus à macOS (comportement natif) |
| Écrans qui arrondissent la valeur (synchro) | Boucle de rétroaction | Filtre d'échos + seuil de convergence, testés (`testRoundingPanelConverges`) |
| Tap désactivé par le système (délai, saisie sécurisée) | Touches natives | Réactivation automatique sur `tapDisabledByTimeout/ByUserInput` |
