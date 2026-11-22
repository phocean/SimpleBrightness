# Politique de sécurité

## Versions prises en charge

Seule la dernière version publiée reçoit des correctifs de sécurité.

| Version | Prise en charge |
|---|---|
| 0.1.x | ✅ |

## Signaler une vulnérabilité

Merci de **ne pas** ouvrir de ticket public pour une vulnérabilité.

Utilisez le signalement privé de GitHub : onglet **Security** du dépôt ›
**Report a vulnerability**. Indiquez :

- la version de SimpleBrightness et de macOS, le modèle de Mac et des écrans ;
- les étapes pour reproduire, et ce qu'un attaquant obtient ;
- si possible, une preuve de concept.

Vous recevrez un accusé de réception sous 7 jours. Le correctif et sa publication
sont coordonnés avec vous ; votre contribution est mentionnée dans les notes de
version si vous le souhaitez.

## Périmètre et modèle de menace

SimpleBrightness est un utilitaire local de barre de menus. Points sensibles, et ce
que l'app fait pour les tenir :

| Sujet | Ce qui est en place |
|---|---|
| **Autorisation Accessibilité** | Nécessaire pour intercepter F1/F2. Elle est large : macOS ne la limite pas aux touches de luminosité. L'app ne s'en sert que pour un tap abonné aux seuls événements « système » (`NX_SYSDEFINED`, touches multimédia) : elle ne reçoit jamais les frappes ordinaires, rend intacte toute touche autre que F1/F2, et n'enregistre aucune touche (`SimpleBrightness/Input/BrightnessKeyTap.swift`). |
| **API privées** | `DisplayServices.framework` (luminosité) et `OSD.framework` (OSD), chargés par `dlopen` depuis leur chemin système absolu ; aucun autre code chargé dynamiquement. |
| **Signature** | Release : Developer ID, horodatée, notarisée par Apple, runtime renforcé, **aucun** droit (entitlement) ; `make build` refuse un build qui porterait `get-task-allow` ou dont la signature ne se vérifie pas. Debug et tests : signés ad hoc sous un autre identifiant, ils ne peuvent pas hériter de l'autorisation de l'app installée. |
| **Réseau, données** | Aucun accès réseau, aucune télémétrie, aucune mise à jour automatique. Seules données conservées : quatre préférences (`syncEnabled`, `syncOffset`, `menuBarIconMode`, `didPromptAccessibility`). Les journaux ne contiennent ni noms d'écrans ni position du pointeur. |
| **Privilèges** | Aucun droit administrateur, aucun démon ni service système. L'ouverture à la connexion passe par `SMAppService`. |
| **Désinstallation** | `make uninstall` retire l'ouverture à la connexion, l'app, ses préférences et l'autorisation Accessibilité (`tccutil reset`). |

Hors périmètre : un attaquant qui exécute déjà du code avec vos droits sur le Mac
(il peut alors faire bien plus que régler la luminosité), et les défauts propres à
macOS ou aux API privées d'Apple.

## Audits

Trois audits indépendants (qualité, sécurité, architecture) ont été menés le
22 novembre 2026 ; rapports et suites données dans
[`docs/audits/2026-11-22/`](docs/audits/2026-11-22/SYNTHESE.md).

## Signature des commits

Les commits de ce dépôt sont signés avec une clé SSH enregistrée sur GitHub.
