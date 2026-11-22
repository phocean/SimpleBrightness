# Consigne d'audit — SimpleBrightness (22 novembre 2026)

Tu es auditeur indépendant. Trois auditeurs (Codex, Claude, Grok) reçoivent cette même
consigne et travaillent sans se voir. **Lecture seule** : ne modifie aucun fichier, ne
lance pas l'app, ne change aucune luminosité, n'exécute rien qui touche au matériel.
Tu peux lire tout le dépôt et lancer des commandes d'analyse (grep, lecture, `git`,
`xcodebuild … test` si ton bac à sable le permet).

## Le produit

SimpleBrightness (dépôt courant) : utilitaire macOS de barre de menus, Swift 6 / AppKit,
macOS 14+, Apple Silicon, hors Mac App Store. Il remplace BetterDisplay pour une seule
chose : la **luminosité matérielle**.
- F1/F2 règlent l'écran sous le pointeur (CGEventTap actif limité à `NX_SYSDEFINED`,
  autorisation Accessibilité).
- Synchronisation facultative et bidirectionnelle entre écran interne et écrans
  externes, avec un écart réglable (−30 % à +30 %).
- Menu : un curseur par écran, synchro, écart, ouverture à la connexion, quitter.

Lis d'abord `README.md`, `docs/FAISABILITE.md`, `docs/TESTS-MATERIELS.md`, puis le code
dans `SimpleBrightness/` et les tests dans `SimpleBrightnessTests/`, ainsi que
`project.yml` et `Makefile`.

Exigences du client : luminosité matérielle uniquement (jamais de gamma ni de
superposition), pas de boucle de rétroaction, pas d'interrogation agressive, CPU nul au
repos, pas de modification brutale de luminosité au lancement ni au rebranchement, ne
pas monopoliser le clavier, aucun réseau, aucune télémétrie, pas de privilèges
administrateur, dépendances minimales, API privées isolées et documentées.

## Décisions déjà prises (ne pas les reproposer, sauf défaut grave)

- API privée DisplayServices : imposée, aucune API publique ne pilote ces écrans.
- Ancien OSD système (`OSDManager`, privé) : choix du client après essai d'un OSD maison.
- L'app traite toujours F1/F2 elle-même (choix du client).
- Écrans tiers DDC/CI : hors périmètre de cette version.
- Distribution hors App Store, signature Developer ID.

## Ce que tu dois produire

Un rapport **en français**, concis, en trois parties.

1. **Qualité du code** : bugs (courses, états incohérents, fuites, erreurs avalées),
   lisibilité, duplication, tests manquants ou fragiles.
2. **Sécurité** : surface d'attaque, autorisation Accessibilité, API privées
   (dlopen/dlsym, `unsafeBitCast`), signature et droits, journaux, données
   personnelles, désinstallation.
3. **Architecture** : découpage des modules, frontières (privé/public,
   matériel/logique/UI), testabilité, concurrence Swift 6 (`@MainActor`,
   `assumeIsolated`, `@unchecked Sendable`), capacité à accueillir un second
   backend (DDC/CI) plus tard.

Pour chaque constat : **gravité** (critique / importante / mineure), **preuve**
(`fichier:ligne`), **scénario concret** qui produit le défaut, **correction
proposée**. Distingue ce que tu as vérifié de ce que tu supposes. Pas plus de
20 constats en tout, triés par gravité. Termine par une note globale sur 10 pour
chacun des trois axes, et trois recommandations prioritaires.
