# Rapport d’audit — SimpleBrightness

**Date : 22 novembre 2026 — Audit indépendant en lecture seule**

Périmètre : documentation demandée, sources de `SimpleBrightness/`, 21 tests unitaires, `project.yml`, projet Xcode et `Makefile`. Aucun fichier modifié, aucune application lancée, aucun accès au matériel effectué. Les rapports des autres auditeurs n’ont pas été consultés.

Le dépôt ne possède pas de commit `HEAD` ; tous les fichiers sont non suivis. Empreinte SHA-256 agrégée des sources Swift, tests, configurations projet et Makefile examinés : `ff47b2522f39e2f6fcc699689eb616516c276adc31379a72e358fb7d3150727b`.

Les constats reposent sur la lecture du code. Deux calculs ont été rejoués séparément en mémoire, et le garde de signature a été testé avec un échec simulé. Aucun test XCTest ni build exécuté. Les validations matérielles mentionnées dans le dépôt restent des résultats déclarés, non reproduits ici.

**Aucun constat critique.** Les constats importants précèdent les constats mineurs.

## 1. Qualité du code

### 1 — Importante : le filtre d’échos masque des changements réels

**Preuve :** `SimpleBrightness/Hardware/BrightnessController.swift:29`, `:164`, `:205`, `:215`.

Toute notification comprise dans une plage parcourue par une écriture récente, avec une tolérance de 1 %, est ignorée pendant deux secondes. Le filtre ne distingue pas un écho d’un changement effectué ailleurs.

**Scénario :** l’app passe de 50 à 80 %. Une seconde après, Control Center ramène réellement l’écran à 60 %. Cette notification appartient à la plage mémorisée `[50 %, 80 %]` : le cache reste à 80 % et l’autre écran ne suit pas. Sans nouvelle notification, l’expiration de la fenêtre ne corrige pas cet état. Ce résultat découle du code et du rejeu arithmétique ; il n’a pas été reproduit matériellement.

**Correction proposée :** rattacher les échos aux écritures effectivement exécutées et à leur progression, fermer leur suivi après acquittement, puis prévoir une réconciliation bornée en cas d’ambiguïté. Ajouter un test de changement externe dans une plage récente.

### 2 — Importante : les écritures en attente survivent aux transitions système

**Preuve :** `SimpleBrightness/Hardware/CoalescingWriter.swift:34`, `:44` ; `SimpleBrightness/App/AppDelegate.swift:171`, `:194`, `:226`.

La suspension empêche de nouvelles propagations, mais ne purge pas le writer. Celui-ci ne connaît ni la session active, ni la veille, ni la génération de topologie.

**Scénario :** pendant un déplacement de curseur, une écriture bloque et une valeur suivante reste en attente. L’utilisateur change de session ou débranche l’écran. La boucle transmet ensuite cette ancienne demande, malgré la suspension du contrôleur. L’absence d’annulation est vérifiée ; l’impact matériel dépend du moment où l’appel en cours se termine.

**Correction proposée :** ajouter une génération de session/topologie et une invalidation des commandes en attente. Contrôler cette génération avant chaque nouvel appel matériel et avant de traiter ses résultats. Un appel matériel déjà engagé doit être traité explicitement comme non annulable.

### 3 — Importante : F2 peut diminuer la luminosité en mode miroir avec écart

**Preuve :** `SimpleBrightness/Hardware/BrightnessController.swift:115`, `:191` ; `SimpleBrightness/Displays/DisplayManager.swift:65` ; `SimpleBrightnessTests/BrightnessControllerTests.swift:148`.

`step` applique successivement la même valeur à chaque cible. Chaque application déclenche sa propre propagation avec écart, qui peut défaire la précédente.

**Scénario :** cibles `[interne, externe]`, valeurs 50 % et 60 %, écart +10 %. F2 calcule 56,25 %. L’application à l’interne place l’externe à 66,25 %, puis l’application à l’externe ramène l’interne à **46,25 %**. Le calcul a été rejoué séparément ; la remontée effective de plusieurs cibles par macOS en miroir n’a pas été testée.

**Correction proposée :** traiter le groupe miroir comme une seule opération, avec une règle explicite de priorité entre miroir et écart. Propager une seule fois depuis la référence choisie. Couvrir les deux ordres de cibles et les écarts positifs et négatifs.

### 4 — Importante : une lecture défaillante laisse un écran fantôme dans le cache

**Preuve :** `SimpleBrightness/Hardware/BrightnessController.swift:80`, particulièrement `:85`, `:92`, `:98`.

Le nettoyage utilise la liste entrante avant les lectures. Si un écran déjà connu figure dans cette liste mais devient illisible, il disparaît de `displays` sans être supprimé de `values` ni désabonné.

**Scénario :** `supports` réussit pendant l’énumération, puis la seconde lecture échoue pendant `updateDisplays`. L’écran est absent de la liste finale mais `isSupported` renvoie toujours vrai. Une notification peut encore être acceptée et les touches peuvent envoyer des écritures vers cet écran. Une actualisation ultérieure qui l’exclut ne le nettoie plus, puisqu’il n’est déjà plus dans `displays`.

**Correction proposée :** construire un nouvel état à partir des seules lectures réussies, puis remplacer atomiquement liste et cache. Désabonner et purger tout ancien écran absent de cet état. Ajouter un test de lecture qui échoue entre détection et chargement.

### 5 — Importante : un ancien échec d’écriture peut écraser une demande plus récente

**Preuve :** `SimpleBrightness/Hardware/CoalescingWriter.swift:53` ; `SimpleBrightness/Hardware/BrightnessController.swift:178`.

Le retour d’échec contient seulement l’identifiant d’écran. Le contrôleur ne peut pas déterminer si cet échec concerne encore la dernière demande.

**Scénario :** une écriture à 80 % échoue ; son traitement attend sur la file principale. Une nouvelle demande à 90 % actualise entre-temps le cache. L’ancien échec relit 50 %, remplace le cache récent et efface tous les échos attendus. La touche suivante repart alors de 50 %, malgré la demande à 90 % en cours. Cet entrelacement est permis par les files ; il n’a pas été exécuté ici.

**Correction proposée :** numéroter les demandes par écran et transmettre leur numéro dans les résultats. Ignorer les échecs dépassés et réconcilier uniquement la demande encore courante.

### 6 — Mineure : les tests ne vérifient pas les principaux entrelacements

**Preuve :** `SimpleBrightnessTests/BrightnessControllerTests.swift:17`, `:40`, `:104`, `:195`, `:204`.

Les writers de test enregistrent seulement les commandes : aucun test n’exerce `CoalescingWriter`. Le test d’échec appelle directement `writeDidFail`. Le test de convergence vérifie surtout le cache, sans maintenir un état matériel simulé distinct et cohérent.

**Scénario :** une régression de coalescence, un échec retardé ou une commande survivant à une suspension laisse les 21 tests actuels inchangés. Le test miroir ne couvre pas l’écart.

**Correction proposée :** ajouter des tests déterministes avec écritures bloquables et acquittements contrôlés. Vérifier séparément commandes, cache et état matériel simulé, notamment pour les constats 1 à 5.

## 2. Sécurité

La surface examinée est limitée : aucun client réseau, télémétrie, lancement de shell par l’app, service privilégié ou dépendance tierce trouvé. Le tap utilise exclusivement le masque `1 << 14`, puis filtre le sous-type et les codes de luminosité. Les frappes ordinaires ne sont pas abonnées.

Les frameworks privés sont chargés par chemins système absolus avec `RTLD_LOCAL`. Leurs usages sont isolés et documentés. Les conversions `unsafeBitCast` restent dépendantes des signatures privées déclarées ; la présence d’un symbole ou d’un sélecteur ne garantit pas la stabilité future de son ABI.

La configuration Release désactive l’injection des droits de développement, également dans le projet Xcode. L’inspection des bundles Release construit et installé n’a affiché aucun entitlement, donc aucun `get-task-allow`. Le bundle installé annonce le hardened runtime. **La confiance de signature n’est toutefois pas validée** : `codesign --verify --strict` retourne `CSSMERR_TP_NOT_TRUSTED` dans cet environnement. Cela ne suffit pas à conclure à une signature défectueuse. La notarisation n’a pas été contrôlée.

### 7 — Mineure : le garde de signature accepte un échec de lecture

**Preuve :** `Makefile:15`.

Le pipeline recherche uniquement le texte `get-task-allow`, sans vérifier que `codesign` a réussi.

**Scénario :** `codesign` échoue et ne produit aucun contenu exploitable ; `grep` ne trouve rien et le garde réussit. Un échec simulé avec `false` confirme un code de sortie final égal à zéro. Aucune présence actuelle de droit dangereux n’a été constatée.

**Correction proposée :** vérifier séparément le succès de l’inspection, puis analyser les droits. Faire également échouer la porte de distribution si la vérification de signature échoue.

### 8 — Mineure : le journal de débogage conserve les événements de luminosité et la position du pointeur

**Preuve :** `SimpleBrightness/Input/BrightnessKeyTap.swift:128` ; `README.md:85`.

Chaque événement reconnu produit un message `debug` contenant le code de touche, la répétition et les coordonnées publiques du pointeur. L’affirmation « n’enregistre aucune touche » est donc trop absolue.

**Scénario :** une collecte de diagnostic incluant le niveau debug révèle les appuis de luminosité, leur répétition et la position du pointeur. Cela ne constitue pas un enregistrement des frappes ordinaires. La conservation effective dépend de la configuration de journalisation ; elle n’a pas été mesurée.

**Correction proposée :** supprimer les coordonnées et le détail par appui, ou les réserver à un diagnostic explicitement activé. Préciser la documentation.

### 9 — Mineure : la désinstallation manuelle omet la révocation Accessibilité

**Preuve :** `README.md:107` ; `Makefile:29`.

L’alternative manuelle propose de supprimer l’app et ses préférences, sans exécuter la réinitialisation TCC prévue par `make uninstall`. Cette dernière masque par ailleurs son éventuel échec avec `|| true`.

**Scénario :** l’utilisateur suit la procédure manuelle puis réinstalle une app portant la même identité de signature. L’autorisation résiduelle peut être retrouvée sans nouveau consentement, comme le précise déjà le README.

**Correction proposée :** inclure explicitement la révocation dans les deux procédures et signaler tout échec de `tccutil`. La désactivation préalable de l’ouverture à la connexion est déjà documentée.

## 3. Architecture

Le découpage est adapté au périmètre : composition dans `AppDelegate`, topologie séparée, logique de synchronisation centralisée, écritures regroupées, interface et API privées isolées. L’injection du backend, du writer et de l’horloge facilite les tests. Aucun mécanisme de gamma ou de superposition de luminosité trouvé.

Les passages par `MainActor.assumeIsolated` examinés sont précédés d’un dispatch sur la file principale, d’une notification configurée sur cette file, ou d’une source de run loop principale. Aucun appel manifestement exécuté sur une file incompatible n’a été identifié.

Le protocole matériel permet d’envisager DDC/CI ultérieurement. Il faudra cependant une composition sélectionnant le backend par écran et un contrat adapté aux backends sans notifications natives.

### 10 — Mineure : l’isolation du backend repose sur des conventions non imposées par Swift

**Preuve :** `SimpleBrightness/Hardware/BrightnessBackend.swift:29` ; `SimpleBrightness/Hardware/DisplayServicesBackend.swift:27`, `:45`, `:48`, `:129`.

`@unchecked Sendable` couvre une classe contenant des propriétés mutables non isolées dans leur déclaration. Les notifications sont routées vers une unique instance statique forte `current`.

**Scénario :** une seconde instance remplace `current` ; les notifications de la première sont alors livrées à la seconde. Un futur appelant peut aussi modifier `onChange` hors du MainActor sans protection du compilateur. L’app actuelle crée une seule instance et configure son callback sur le MainActor : aucune course actuelle n’est démontrée.

**Correction proposée :** isoler explicitement l’état d’observation et le callback sur le MainActor, limiter l’objet partageable aux fonctions matérielles sûres, et associer les notifications à leur instance plutôt qu’à une variable globale.

### 11 — Mineure : les lectures matérielles peuvent bloquer la file qui sert le tap

**Preuve :** `SimpleBrightness/Displays/DisplayManager.swift:36` ; `SimpleBrightness/Hardware/DisplayServicesBackend.swift:79` ; `SimpleBrightness/Hardware/BrightnessController.swift:92`, `:181` ; `SimpleBrightness/System/BrightnessOSD.swift:23`.

Les écritures quittent correctement le fil principal. Les lectures, sondages de capacité et première résolution de l’OSD y restent synchrones.

**Scénario :** pendant une actualisation ou une reprise après échec, un appel privé lent immobilise l’interface et retarde le traitement du tap multimédia. Ce risque augmenterait avec un backend DDC/CI à lectures lentes. Aucun délai excessif n’a été mesuré ici.

**Correction proposée :** placer les sondages et lectures sur un exécuteur matériel compatible avec le backend, puis publier un résultat associé à la génération courante. Garder le traitement du tap court et fondé sur le cache.

### 12 — Mineure : le contrat d’observation ne remonte pas ses échecs

**Preuve :** `SimpleBrightness/Hardware/BrightnessBackend.swift:24` ; `SimpleBrightness/Hardware/DisplayServicesBackend.swift:101`, `:109`.

L’inscription peut échouer, mais `startObserving` ne retourne aucun résultat. L’échec est seulement journalisé en debug. La désinscription retire d’abord l’écran de `observed`, puis ignore le résultat de l’appel privé.

**Scénario :** un écran reste lisible et pilotable, mais son inscription échoue temporairement. Il apparaît pris en charge alors que ses changements externes ne déclenchent aucune synchronisation, jusqu’à une nouvelle actualisation. Une désinscription défaillante rend également le suivi local incertain.

**Correction proposée :** représenter séparément les capacités de lecture, écriture et observation ; remonter leurs erreurs et prévoir une reprise bornée lors des transitions, sans interrogation permanente.

**Notes globales**

| Axe | Note | Appréciation |
|---|---:|---|
| Qualité du code | **6/10** | Code lisible, mais défauts de cohérence et d’ordonnancement dans le cœur fonctionnel. |
| Sécurité | **8/10** | Surface réduite et protections pertinentes ; garde de signature et documentation à fiabiliser. |
| Architecture | **7/10** | Frontières claires ; cycle des commandes, isolation et capacités du backend à formaliser. |

**Trois recommandations prioritaires**

1. **Fiabiliser la synchronisation** : corriger les faux échos et l’opération miroir avec écart, avec des tests distinguant cache et état matériel.
2. **Donner un cycle de vie aux commandes** : numéroter les demandes, invalider les commandes périmées et ignorer les retours d’échec dépassés.
3. **Consolider la reprise et la livraison** : supprimer les états fantômes après lecture défaillante, tester le writer réel et rendre les contrôles de signature bloquants en cas d’erreur.