# Tests matériels

Matériel : MacBook Pro M4 14", Studio Display, macOS 27.3 bêta (26C5035r).
Une compilation réussie ou un test unitaire ne valent **pas** validation matérielle.

Journaux pendant un test :

```bash
log stream --predicate 'subsystem == "com.jcbaptiste.SimpleBrightness"' --level debug
```

| # | Scénario | État | Date | Remarque |
|---|---|---|---|---|
| 1 | Studio Display : lecture, écriture, notification | ✅ Validé | 21/11 | Prototype puis app |
| 2 | Écran interne : lecture, écriture | ✅ Validé | 21/11 | |
| 3 | F1/F2, pointeur sur le Studio Display | ✅ Validé | 21/11 | Clavier du MacBook |
| 4 | F1/F2, pointeur sur l'écran interne | ✅ Validé | 21/11 | |
| 5 | Capot fermé puis rouvert (Studio Display seul) | ✅ Validé | 21/11 | Liste d'écrans mise à jour |
| 6 | OSD système (ancien style) | ✅ Validé | 21/11 | Nouvel OSD macOS 27 inaccessible |
| 7 | Touche maintenue (répétition) | ✅ Validé | 22/11 | 126 événements « repeat » traités |
| 8 | ⇧⌥ + F1/F2 : quart de cran | ✅ Validé | 22/11 | |
| 9 | ⌥ + F1/F2 : ouvre Réglages › Moniteurs | ✅ Validé | 22/11 | Touche rendue à macOS |
| 10 | Synchro : F1/F2 sur un écran → l'autre suit | ✅ Validé | 22/11 | Dans les deux sens, sans saut ni oscillation |
| 11 | Synchro : curseur de Control Center → l'autre suit | ✅ Validé | 22/11 | Curseurs des deux écrans ; 144 et 62 changements propagés, aucun aller-retour dans les journaux |
| 12 | Synchro : luminosité automatique de l'écran interne | ✅ Validé | 22/11 | Le Studio suit avec l'écart ; l'auto reste active après F1 ; pas d'oscillation. Pendant une transition, ~60 notifications/s et ~2,5 % CPU ; 0 % une fois stable |
| 13 | Synchro désactivée : contrôle indépendant | ✅ Validé | 22/11 | |
| 14 | Activation / désactivation de la synchro | ✅ Validé | 22/11 | Aucun saut anormal (une seule bascule observée dans les journaux) |
| 15 | Veille puis réveil | ✅ Validé | 22/11 | Luminosité intacte ; F1/F2 et synchro avec écart fonctionnent (essayés ~1 min après le réveil) |
| 16 | Débranchement / rebranchement du Studio Display | ✅ Validé (après correctif) | 22/11 | 1ᵉʳ essai : Studio resté « non pris en charge ». Corrigé (stabilisation 3 s + revérifications à 6 et 10 s). Les petits sauts de l'écran interne au (dé)branchement viennent de macOS : mesurés à l'identique app arrêtée (0,525 → 0,475 → 0,525) |
| 17 | Changement rapide d'utilisateur | ⏳ À faire | | Tap arrêté puis relancé |
| 18 | Retrait de l'autorisation, app lancée | ✅ Validé | 22/11 | Détecté, tap arrêté, touches natives ; menu propose l'autorisation ; reprise sans relancer à la réactivation |
| 19 | Repos prolongé (1 h) : CPU ≈ 0 %, mémoire stable | ⏳ À faire | | Mesures courtes : 0 % CPU, 25 Mo au repos |
| 20 | Ouvrir à la connexion | ⏳ À faire | | Après redémarrage de session |
| 21 | Changement externe depuis un autre processus, synchro active | ✅ Validé | 22/11 | Studio → interne et interne → Studio, alignés en < 1 s, stables après 2,5 s |
| 22 | Écart des écrans externes (+10 %) | ✅ Validé | 22/11 | Interne 90 %, Studio 100 % ; maintenu avec F1/F2 dans les deux sens |
| 23 | Auto-luminosité activée sur le Studio Display | ⚠️ Limite macOS | 22/11 | **App arrêtée.** Capot ouvert (2 essais, main puis lampe torche) : luminance retenue pour le Studio figée (53 lux), aucune réaction. Capot fermé (~22 s) : `corebrightnessd` passe en mode « Clamshell », lit 431 lux et le Studio réagit (0,173 → 0,249 puis redescend à 0,191 en 5 s). Indice que macOS n'exploite le capteur du Studio que capot fermé ; à confirmer par un essai plus long. Erreur « cannot initialize curve » à chaque (re)branchement |
| 24 | Version P1+P2 (audits du 22/11) : F1/F2, synchro avec écart, près du maximum, menu | ✅ Validé | 22/11 | « Pas de saut » près du maximum confirmé ; fermeture du capot : relectures à 0,6 s et 3 s puis arrêt (journaux) |
| 25 | Version P1+P2 : débranchement / rebranchement réel du Studio Display | ⏳ À revérifier | | Non exercé lors du contrôle du 22/11 (seule la fermeture du capot apparaît dans les journaux) |
| 26 | Icône de la barre des menus : masquer, rouvrir l'app, seulement avec un écran externe | ✅ Validé | 22/11 | Réapparition menu ouvert à la réouverture ; visible avec le Studio, masquée sans, revient au rebranchement |
