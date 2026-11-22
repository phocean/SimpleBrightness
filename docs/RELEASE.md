# Publier une version

Le DMG est construit, signé et notarisé **sur le Mac du titulaire du compte développeur**,
puis déposé dans une release GitHub. La clé privée Developer ID ne quitte jamais son
trousseau : GitHub ne reçoit que le DMG final et sa somme SHA-256.

```bash
make publish
```

Dans l'ordre, `make publish` :

1. refuse de continuer si des modifications ne sont pas validées ou pas poussées : le
   binaire publié doit correspondre exactement au code source publié (GPL) ;
2. refuse si l'étiquette `vX.Y.Z` existe déjà sur GitHub, ou si les notes
   `docs/releases/vX.Y.Z.md` manquent ;
3. lance les tests unitaires ;
4. lance `make release` : build Release signé Developer ID et horodaté, contrôles
   bloquants (ci-dessous), DMG signé, notarisation par Apple, agrafage, contrôle Gatekeeper ;
5. seulement alors, crée l'étiquette `vX.Y.Z` **signée** (clé SSH) et la pousse ;
6. crée la release GitHub avec le DMG et son `.sha256`.

Un échec aux étapes 1 à 4 ne laisse aucune trace sur GitHub. Si l'étape 6 échoue,
l'étiquette est retirée de GitHub et du Mac : il suffit de relancer `make publish`.

## Nouvelle version

1. Changer `MARKETING_VERSION` dans `project.yml`.
2. Écrire `docs/releases/vX.Y.Z.md`.
3. Valider (commit signé) et pousser, puis `make publish`.

Le numéro de build (`CFBundleVersion`) est le nombre de commits.

## Identifiants de notarisation (une fois)

`notarytool` lit ses identifiants dans un profil du trousseau. Par défaut, `make` utilise le
profil `studio-eq`, déjà créé sur ce Mac pour la même équipe ; un autre nom se passe par
`make publish NOTARY_PROFILE=<nom>`. Pour en créer un :

```bash
xcrun notarytool store-credentials <nom> --apple-id <votre Apple ID> --team-id 26N2RN6N67
```

Le mot de passe demandé est un **mot de passe pour app** (account.apple.com › Connexion et
sécurité). Vérification : `xcrun notarytool history --keychain-profile <nom>`.

## Contrôles bloquants de `make release`

- signature valide, autorité **Developer ID Application**, équipe attendue,
  **horodatage sécurisé**, **Hardened Runtime** ;
- **aucun droit** (entitlement), lu comme une liste de propriétés : en particulier pas de
  `get-task-allow` ;
- identifiant `com.jcbaptiste.SimpleBrightness` (jamais un build Debug) et numéro de
  version attendu ;
- notarisation « Accepted » (sinon le journal d'Apple est affiché), ticket agrafé, DMG
  accepté par Gatekeeper (`spctl`).

## Essais sans publier

- `make dmg` : DMG signé et vérifié, **non notarisé** (Gatekeeper le refuserait ailleurs).
- `make release` : DMG notarisé et agrafé dans `build/release/`, sans étiquette ni release.
