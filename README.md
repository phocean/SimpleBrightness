# SimpleBrightness

Petit utilitaire macOS de barre de menus : les touches de luminosité (F1/F2) règlent
le **rétroéclairage matériel** de l'écran situé sous le pointeur. En option, la
luminosité est synchronisée entre l'écran interne et les écrans externes compatibles.

Rien d'autre : pas de gestion d'écrans, pas de réseau, pas de télémétrie.

## Fonctionnement

| Situation | Effet de F1/F2 |
|---|---|
| Pointeur sur l'écran interne | Rétroéclairage du MacBook |
| Pointeur sur un Studio Display (ou autre écran Apple) | Rétroéclairage de cet écran |
| MacBook fermé | Écran externe actif |
| Pointeur sur un écran non pris en charge | Touche rendue à macOS (comportement natif) |
| ⌥ + F1/F2 | Rendu à macOS (ouvre les réglages Moniteurs) |
| ⇧⌥ + F1/F2 | Quart de cran, comme macOS |

Incréments : 16 crans, comme macOS. L'OSD de luminosité s'affiche sur l'écran réglé
(ancien style d'OSD, voir *Limitations*).

**Menu** (icône soleil) : un curseur par écran pris en charge, la liste des écrans non
pris en charge, *Synchroniser la luminosité* (et son écart réglable), *Ouvrir à la
connexion*, *Quitter*.

### Synchronisation

- Désactivée par défaut, mémorisée entre les sessions.
- Bidirectionnelle : un changement sur un écran (touches, curseur, Control Center,
  Réglages Système, ajustement automatique) est recopié sur les autres.
- Échelle normalisée 0–100 % : deux écrans à 50 % **n'émettent pas forcément la même
  luminance** (un Studio Display monte à 600 nits, l'écran interne du MacBook Pro à
  1 000 nits en SDR). Pas d'égalisation photométrique dans cette version.
- **Écart des écrans externes** (facultatif, 0 par défaut) : un curseur, visible
  dans le menu quand la synchro est active, place les écrans externes de −30 % à
  +30 % par rapport à l'écran interne. Exemple : à +10 %, l'interne à 60 % donne le
  Studio Display à 70 %. La relation est tenue dans les deux sens, bornée à 0–100 %.
- À l'activation, les écrans s'alignent sur celui qui est sous le pointeur.
- Au lancement, au réveil et au rebranchement, **rien n'est réécrit** : l'alignement
  se fait au prochain changement. Cela évite tout saut de luminosité inattendu.
- Suspendue pendant la veille, quelques secondes après un branchement ou un réveil
  (le temps que les écrans se stabilisent), et quand la session utilisateur n'est
  pas active.
- Auto-luminosité du Studio Display : sur macOS 27.3, capot ouvert, macOS ne réagit
  pas à son capteur, avec ou sans l'app (mesuré à la lampe torche). Capot fermé, une
  réaction a été mesurée. Pour une synchro qui suit la lumière ambiante capot
  ouvert, activez plutôt l'auto-luminosité de l'écran interne : le Studio la suit,
  avec l'écart.
- Au branchement ou au débranchement d'un écran, macOS modifie lui-même légèrement
  la luminosité de l'écran interne (mesuré sans l'app) : ce n'est pas SimpleBrightness.

## Installation

Prérequis : macOS 14 ou plus récent, Mac Apple Silicon, Xcode 16+ ;
[XcodeGen](https://github.com/yonaskolb/XcodeGen) seulement pour régénérer le projet.

```bash
make install
```

Cette commande compile en Release, copie l'app dans `/Applications` et la lance.
Le projet `SimpleBrightness.xcodeproj` est versionné : XcodeGen n'est utile que si
`project.yml` change (`make project`).

La signature utilise l'identité *Developer ID Application* de l'équipe définie dans
`project.yml` (`DEVELOPMENT_TEAM`). Pour une autre équipe, modifiez cette valeur. Une
signature stable est importante : macOS rattache l'autorisation Accessibilité à la
signature, et une signature ad hoc la ferait perdre à chaque recompilation. La
notarisation (`xcrun notarytool`) est nécessaire pour distribuer l'app à d'autres
utilisateurs ; elle n'est pas automatisée ici.

## Sécurité et permissions

| Permission | Pourquoi | Sans elle |
|---|---|---|
| **Accessibilité** | Intercepter et consommer F1/F2 (CGEventTap actif) | Curseurs du menu et synchro fonctionnent ; F1/F2 gardent le comportement natif |
| Ouverture à la connexion | Option du menu (SMAppService) | — |

SimpleBrightness demande l'autorisation Accessibilité, seule voie offerte par macOS pour
intercepter F1/F2. **Cette autorisation est large** : macOS ne la limite pas aux
touches de luminosité, elle permettrait en principe d'observer et de piloter toute
l'interface. L'app s'en sert uniquement pour un tap abonné aux événements « système »
(touches multimédia) : elle ne reçoit jamais les frappes ordinaires, rend intacte toute
touche autre que F1/F2 et n'enregistre aucune touche. Cette limite est tenue par le
code (`Input/BrightnessKeyTap.swift`), pas par le système.

Aucun accès réseau, aucune télémétrie, aucun privilège administrateur ni service
système. Seuls trois réglages sont conservés (`syncEnabled`, `syncOffset`, `didPromptAccessibility`).
Les builds Release ne portent pas `get-task-allow` : `make build` refuse sinon, et
refuse aussi si `codesign` échoue. Les builds Debug et de test sont signés ad hoc sous
un autre identifiant (`com.jcbaptiste.SimpleBrightness.debug`) : ils ne peuvent jamais
hériter de l'autorisation accordée à l'app installée.

Au premier lancement, macOS demande l'autorisation. Plus tard : menu ›
*Autoriser les touches de luminosité…*, ou Réglages Système › Confidentialité et
sécurité › Accessibilité (sur macOS 27 : « Contrôle de l'appareil et accès aux
données »). Pour révoquer : même panneau, ou
`tccutil reset Accessibility com.jcbaptiste.SimpleBrightness`. L'app le détecte,
rend F1/F2 à macOS, et reprend la main sans redémarrer si l'autorisation revient.

**Utilisation sans l'autorisation.** Si vous ne voulez que la synchronisation, vous
pouvez refuser l'autorisation : macOS garde F1/F2 et son nouvel OSD, mais règle
toujours l'écran interne (capot ouvert) ; la synchro fait suivre les écrans externes,
avec l'écart. Vous perdez seulement le réglage indépendant de l'écran sous le
pointeur au clavier (les curseurs du menu restent disponibles).

## Désinstallation

1. `make uninstall` (recommandé) : quitte l'app, désinscrit l'ouverture à la
   connexion (tant que l'app est encore là), supprime l'app, ses préférences,
   l'autorisation Accessibilité et les builds locaux. Un échec de `tccutil` arrête la
   commande au lieu de passer inaperçu.
2. À la main : menu › décochez *Ouvrir à la connexion*, *Quitter SimpleBrightness*,
   puis supprimez `/Applications/SimpleBrightness.app` et lancez :

```bash
defaults delete com.jcbaptiste.SimpleBrightness
```

```bash
tccutil reset Accessibility com.jcbaptiste.SimpleBrightness
```

Sans la réinitialisation de l'autorisation, une réinstallation signée par la même
équipe la retrouverait sans la redemander. L'app n'installe rien d'autre : ni démon,
ni extension, ni fichier hors de ses préférences.

## Limitations

- Écrans pris en charge : écran interne et écrans Apple pilotés par DisplayServices
  (Studio Display vérifié). Les écrans tiers DDC/CI sont listés « non pris en charge ».
- **Aucun repli logiciel** : jamais de gamma ni de superposition. Un écran non
  pilotable reste tel quel.
- OSD : l'ancien style. Le nouvel OSD de macOS 27 est dessiné par Control Center sans
  point d'entrée accessible (voir `docs/FAISABILITE.md`).
- Hors Mac App Store : API privées et tap clavier actif sont incompatibles avec le
  bac à sable. Pour distribuer l'app à d'autres Mac, il faut la notariser
  (`xcrun notarytool submit … --wait`, puis `xcrun stapler staple`) ; sinon
  Gatekeeper la bloque.

## API privées utilisées

Isolées et résolues dynamiquement (`dlopen`/`dlsym`) : si un symbole manque, l'app
démarre quand même et l'indique au lieu de planter.

| API | Fichier | Rôle | Compatibilité |
|---|---|---|---|
| `DisplayServices.framework` : Get/Set/CanChangeBrightness, (Un)RegisterForBrightnessChangeNotifications | `Hardware/DisplayServicesBackend.swift` | Luminosité matérielle, notifications | Stable depuis macOS 11 ; vérifié sur 27.3. Également utilisé par MonitorControl et Lunar |
| `OSD.framework` : `OSDManager` | `System/BrightnessOSD.swift` | OSD | Cosmétique, facultatif |

Tout le reste est public : CoreGraphics (topologie, pointeur, tap), AppKit,
ServiceManagement, UserDefaults.

## Développement

```bash
make test
```

37 tests unitaires couvrent la logique de synchronisation (échos même tardifs, convergence,
pas de boucle, suspension, rebranchement sans écriture, échec d'écriture même périmé, écart près des bornes,
écrans en miroir, stabilisation, `NaN`), l'écrivain (fusion, annulation, échec) et le
décodage des touches et le calcul des crans. Les tests
matériels sont suivis dans [`docs/TESTS-MATERIELS.md`](docs/TESTS-MATERIELS.md).

Journaux : `log stream --predicate 'subsystem == "com.jcbaptiste.SimpleBrightness"' --level debug`

Architecture :

```
SimpleBrightness/
  App/        AppDelegate (cycle de vie : veille, session, écrans), journaux
  Hardware/   BrightnessBackend (protocole), DisplayServicesBackend (privé),
              BrightnessController (état + synchro), CoalescingWriter (écritures)
  Displays/   DisplayManager (topologie, écran sous le pointeur)
  Input/      BrightnessKeyTap (F1/F2)
  UI/         Menu de barre d'état, curseurs
  System/     OSD (privé), ouverture à la connexion, préférences
```

## Licence

Copyright © 2026 Jean-Christophe Baptiste.

SimpleBrightness est un logiciel libre : vous pouvez le redistribuer et le modifier
selon les termes de la **GNU General Public License version 2**, ou (à votre choix)
de toute version ultérieure, telle que publiée par la Free Software Foundation
(`GPL-2.0-or-later`). Il est distribué sans aucune garantie. Texte complet :
[LICENSE](LICENSE).

Sécurité et signalement de vulnérabilités : [SECURITY.md](SECURITY.md).
