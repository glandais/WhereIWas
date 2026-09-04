# Synchronisation iCloud (CloudKit) de la base WhereIWas

## Contexte

Aujourd'hui toute la donnée vit dans un seul fichier SQLite local :
`Library/Application Support/WhereIWas.store`, ouvert par
`ModelConfiguration("WhereIWas", schema:url:)` dans
`WhereIWas/Persistence/LocationStore.swift:32-43`. Aucun entitlement iCloud,
aucun App Group, aucune migration versionnée, aucun code réseau.

Le besoin exprimé est de « survivre à un backup / restauration », sans exposer
de fichiers à l'utilisateur ; l'option retenue est une **vraie synchronisation
CloudKit** sur la base privée de l'utilisateur, plutôt qu'un simple durcissement
de la sauvegarde iOS. Résultat attendu : la base se retrouve sur un nouvel
iPhone via le compte iCloud de l'utilisateur, sans intervention manuelle et sans
dépendre de la sauvegarde de l'appareil.

**Deux points à garder en tête pendant l'exécution**, sans qu'ils remettent la
décision en cause :

1. Le besoin initial est *déjà* satisfait par le système. Le store est dans
   Application Support, rien ne l'exclut du backup, les exports vont dans
   `temporaryDirectory` (jamais sauvegardés) et les réglages sont dans
   `UserDefaults.standard` (sauvegardés). Un backup/restauration iOS ramène
   déjà l'historique complet. CloudKit apporte autre chose : l'indépendance
   vis-à-vis de la sauvegarde de l'appareil, et le multi-appareils.
2. **Une synchronisation n'est pas une sauvegarde.** Une purge ou une
   suppression accidentelle se propage à tous les appareils. Et sur un compte
   avec deux iPhones, les deux traces GPS fusionnent en un seul historique
   entrelacé — pour un logger de déplacements c'est un comportement produit à
   assumer explicitement, pas un effet de bord anodin.

La question « les déclarations de confidentialité App Store deviennent-elles
fausses ? » est volontairement laissée ouverte : la phase 8 liste le travail,
elle ne tranche pas.

---

## Contraintes dures de SwiftData + CloudKit

Elles dictent tout le découpage qui suit :

- **Aucune contrainte d'unicité.** Les quatre `@Attribute(.unique)` doivent
  disparaître (`Models.swift:17,110,152`, `AuditModels.swift:11`).
- **Toute propriété non optionnelle doit avoir une valeur par défaut.** Aucun
  modèle n'en a aujourd'hui : tout est assigné dans les `init`.
- **Toute relation doit avoir son inverse.** Sans objet ici : il n'y a aucune
  `@Relationship` (le lien vers la session est un `sessionID: UUID?`
  dénormalisé, `Models.swift:37-39` — un choix qui se révèle payant).
- **Un modèle n'appartient qu'à une seule `ModelConfiguration`**, ce qui rend
  possible le découpage synchronisé / local de la phase 3.
- La synchronisation exige la capability **Push Notifications** et le background
  mode **`remote-notification`** : CloudKit pousse les changements par silent
  push.

---

## Phase 0 — Filet de sécurité (avant de toucher au schéma)

`WhereIWas/App/AppEnvironment.swift:33-47` bascule silencieusement sur un store
**en mémoire** dès que `makeContainer` throw, avec un simple `logger.fault`.
Aujourd'hui ça protège d'un fichier corrompu ; dès qu'on modifie le schéma, ça
transforme un échec de migration en **perte totale de l'historique, sans aucun
signal visible pour l'utilisateur**, à chaque lancement. C'est le prérequis
absolu.

- Distinguer les cas dans `makeContainer` : fichier absent (normal) vs échec
  d'ouverture/migration (anormal). Ne jamais basculer en mémoire sur le second
  sans laisser de trace persistante.
- Exposer un état d'erreur de persistance jusqu'à `StatusView` (une ligne
  d'alerte suffit) : l'utilisateur doit savoir que rien n'est enregistré.
- Introduire `SchemaV1` (`VersionedSchema`, exactement le schéma actuel) et un
  `SchemaMigrationPlan` sans étape, passé à `ModelContainer(for:migrationPlan:
  configurations:)`. Coût quasi nul, et c'est l'ancrage de toutes les
  migrations suivantes.

Fichiers : `WhereIWas/Persistence/LocationStore.swift`,
`WhereIWas/App/AppEnvironment.swift`, un nouveau
`WhereIWas/Persistence/SchemaVersions.swift`, `WhereIWas/UI/StatusView.swift`.

Livrable compilable et testable seul : aucun changement de comportement visible.

## Phase 1 — Rendre le schéma compatible CloudKit (sans activer CloudKit)

Purement local, aucune déclaration App Store à toucher, entièrement testable.

- Retirer les quatre `@Attribute(.unique)`.
- Donner une valeur par défaut à **chaque** propriété non optionnelle des quatre
  `@Model`. Les `init` existants continuent de tout assigner ; les defaults sont
  là pour CloudKit et pour la migration légère.
- Ajouter `SchemaV2` et une `MigrationStage.lightweight(fromVersion: SchemaV1,
  toVersion: SchemaV2)`. La suppression d'un index unique et l'ajout de defaults
  entrent dans le périmètre de la migration légère ; le test de la phase 7 est
  là pour le prouver plutôt que pour l'espérer.

Ce que la perte de `.unique` change réellement : sur les trois `id: UUID`, rien
(ils sont générés, jamais rapprochés). Sur `LocationSample.sequence`, tout —
c'est l'objet de la phase 2.

Fichiers : `WhereIWas/Persistence/Models.swift`,
`WhereIWas/Persistence/AuditModels.swift`,
`WhereIWas/Persistence/SchemaVersions.swift`.

## Phase 2 — Remplacer `sequence` comme identité et comme ordre

`LocationStore.allocateSequences` (`LocationStore.swift:47-59`) seede un
compteur en mémoire depuis `max(sequence)`. Avec deux appareils, les deux
allouent `1, 2, 3…` : collisions d'identité et ordre global faux. C'est le
point de conception le plus lourd de la migration.

**Approche retenue** : `sequence` redevient ce qu'il est réellement — un
compteur d'insertion *local*, informatif — et l'identité comme l'ordre passent
sur `(timestamp, id)`.

- Ajouter `id: UUID` (non unique, généré à l'insert) à `LocationSample`.
- `StoredLocationSample.id` passe de `sequence` à `id`
  (`Domain/Interfaces.swift:67-92`).
- Remplacer tous les tris `SortDescriptor(\.sequence)` par un tri sur
  `timestamp`, départagé par `createdAt` : `LocationStore.swift:96, 116, 123,
  129, 134`. Sémantiquement c'est même plus juste — l'ordre attendu d'une trace
  GPS est l'ordre chronologique des fixes.
- `pendingUpload(limit:)` / `markUploaded(sequences:)` passent de `[Int64]` à
  `[UUID]` (`Interfaces.swift` + `LocationStore.swift:93-109`).
  **À décider au passage** : cette paire est du code mort réservé à une couche
  d'upload qui n'existe pas, et c'est elle qui rend `metadata/app-privacy.md`
  fragile (le fichier prévoit explicitement de devoir se refaire « the day that
  layer ships »). La supprimer coûte moins cher que la migrer, et retire un
  faux positif dans la déclaration de confidentialité. Le champ `uploaded`
  disparaîtrait avec, ainsi que `StoreStats.pendingUpload`.
- Consommateurs à suivre : `WhereIWas/UI/MapView.swift:35,51,56` (`.tag` sur
  `sequence`), `Persistence/GPXExporter.swift`, `Persistence/JSONExporter.swift`
  (le champ apparaît dans le JSON exporté — c'est un changement de format
  d'export, à assumer ou à conserver en champ informatif).
- `SchemaV3` + étape de migration ; pour une base existante, `id` est généré à
  la volée.

Tests à réécrire : `WhereIWasTests/LocationStoreTests.swift:44, 77, 81, 98,
118, 140`, qui asservissent tous des valeurs de `sequence` littérales.

## Phase 3 — Découper la base en deux configurations

Un seul `ModelContainer`, deux `ModelConfiguration` :

| Configuration | Modèles | CloudKit |
|---|---|---|
| `WhereIWas` (`WhereIWas.store`) | `LocationSample`, `TrackingSession`, `StateTransitionLog` | `.private("iCloud.io.github.glandais.whereiwas")` |
| `WhereIWasAudit` (`WhereIWasAudit.store`) | `AuditEventLog` | aucun |

Pourquoi sortir l'audit : il est opt-in, à rétention 7 jours, produit plusieurs
lignes par fix accepté avec un blob JSON de détails (`AuditModels.swift:18`),
et c'est le poste de volume dominant quand il est activé. Il n'a aucune valeur
après une restauration — c'est du diagnostic sur *cet* appareil. L'envoyer dans
CloudKit serait le pire rapport coût/bénéfice de tout le projet.

Impact : `LocationStore.storeURL` devient deux URLs, `makeContainer` construit
deux configurations, et le `@ModelActor` continue de voir les deux à travers son
unique `modelContext` — les méthodes d'audit (`LocationStore.swift:220-279`) ne
changent pas. La configuration mémoire des tests reste unique et sans CloudKit.

Il faut migrer les `AuditEventLog` existants vers le nouveau fichier, ou
accepter de les perdre (rétention 7 jours, opt-in, off par défaut : les perdre
est défendable et se documente en une ligne).

## Phase 4 — Entitlements et configuration projet

Le projet Xcode est généré : tout passe par `project.yml`, suivi de
`xcodegen generate`.

Sur le target `WhereIWas` :

```yaml
    entitlements:
      path: WhereIWas/WhereIWas.entitlements
      properties:
        com.apple.developer.icloud-container-identifiers:
          - iCloud.io.github.glandais.whereiwas
        com.apple.developer.icloud-services: [CloudKit]
        aps-environment: development
```

Dans `info.properties` : ajouter `remote-notification` à `UIBackgroundModes`, et
**retirer `fetch`** — il est déclaré aujourd'hui sans qu'aucun `BGAppRefreshTask`
ne soit enregistré (seul un `BGProcessingTask` l'est,
`MaintenanceScheduler.swift:42-52`), ce que App Review relève régulièrement.

Hors dépôt, à faire une fois : créer le container `iCloud.io.github.glandais.
whereiwas` au portail développeur, et — étape classiquement oubliée —
**promouvoir le schéma CloudKit de Development vers Production** avant toute
soumission. Sans cette promotion, la synchronisation fonctionne en debug et ne
fonctionne pour aucun utilisateur de l'App Store.

## Phase 5 — Activation conditionnelle et absence de compte iCloud

- Nouveau réglage `iCloudSyncEnabled: Bool = false` dans
  `Domain/TrackingSettings.swift`. Le `init(from:)` manuel (`:149-176`) fait déjà
  du `decodeIfPresent ?? default`, donc l'ajout est rétro-compatible sans
  versionner la clé `whereiwas.settings.v1`.
- Au démarrage, `makeContainer` choisit `.private(…)` ou `.none` selon ce
  réglage **et** `CKContainer.default().accountStatus`. Pas de compte iCloud
  → configuration locale, et un message dans Réglages plutôt qu'un échec.
- Changer le réglage impose de reconstruire le `ModelContainer`, donc tout le
  graphe d'`AppEnvironment`. Le plus honnête est de l'annoncer : le toggle
  prend effet au prochain lancement.
- Déconnexion d'iCloud en cours de route : la base locale reste intacte, la
  synchronisation s'arrête. Ne jamais supprimer le store local sur ce
  changement d'état.
- Nouvelle section iCloud dans `WhereIWas/UI/SettingsView.swift` (statut du
  compte, toggle, avertissement « la purge se propage à tous les appareils »),
  sur le modèle des sections existantes (`:225-245` pour la rétention).
- Nouvelles clés en **dotted names**, puis `./scripts/xcb.sh strings` et
  remplissage de l'unité `en` **et** des huit autres langues.

## Phase 6 — Volume et budget background : le point qui décide

C'est ici que l'approche se valide ou se corrige, et il faut mesurer avant de
conclure.

- Ordre de grandeur (à confirmer, non documenté aujourd'hui) : filtre 10 m en
  marche ≈ 450 samples/h, soit ~5 000 lignes/jour sur une garde de 12 h, et
  ~150 000 lignes pour les 30 jours de rétention par défaut. C'est un volume
  lourd mais pas absurde pour une base privée CloudKit.
- Le vrai risque n'est pas le stock, c'est le flux de suppressions : la purge
  quotidienne propage ~5 000 suppressions/jour, et `purge(olderThan:)`
  (`LocationStore.swift:139-147`) fait aujourd'hui un `delete(model:where:)`
  massif suivi d'un `save()`, sans pagination ni budget de temps face à
  l'expiration du `BGProcessingTask`. À paginer dans cette phase.
- SwiftData ne permet pas de synchroniser un sous-ensemble de lignes d'une même
  entité : on ne peut pas « ne synchroniser que les 7 derniers jours » de
  `LocationSample`. Les deux seules voies réelles sont d'accepter le volume
  complet borné par la rétention, ou de renoncer à synchroniser les samples —
  ce qui viderait l'objectif. **Recommandation : accepter, et mesurer sur
  appareil réel avant d'aller plus loin.**
- Contrat de relaunch (`ARCHITECTURE.md` §5) : `NSPersistentCloudKitContainer`
  démarre son travail à l'initialisation du container, or `AppEnvironment.init`
  puis `TrackingCoordinator.init` doivent rendre la main dans le même tour de
  run-loop pour que l'événement de localisation qui a relancé l'app soit
  délivré. Mesurer le coût d'init avec CloudKit activé ; s'il est significatif,
  n'activer la synchronisation qu'au premier plan.
- Batterie : toute l'app est construite autour de « ne pas vider la batterie »
  (budget de référence dans `ARCHITECTURE.md` §5 : 40-50 % sur une garde de
  12 h). Ajouter un trafic réseau continu doit être mesuré contre ce budget.

## Phase 7 — Tests

- Les tests actuels utilisent un container mémoire
  (`LocationStoreTests.swift:8`, `AuditTrailTests.swift:87`) : la configuration
  mémoire reste **sans** `cloudKitDatabase`, donc ils continuent de tourner sans
  compte iCloud.
- À ajouter : migration V1→V2→V3 sur un fichier de store réel (créer une base à
  l'ancien schéma, l'ouvrir au nouveau, vérifier qu'aucune ligne n'est perdue) —
  c'est le test qui protège de la phase 0.
- À réécrire : tout ce qui asservit des valeurs littérales de `sequence`
  (phase 2), et l'ordre désormais chronologique.
- **Non testable en CI** : la synchronisation elle-même. CloudKit ne fonctionne
  pas sans compte iCloud connecté, et le vrai test est à deux appareils. À
  ajouter au plan de test appareil d'`ARCHITECTURE.md` §7 : enregistrer sur
  l'appareil A, vérifier l'apparition sur B, purger sur A, vérifier la
  propagation, se déconnecter d'iCloud et vérifier que rien n'est perdu
  localement.

## Phase 8 — Documentation et App Store

Technique :

- `ARCHITECTURE.md` §4 : le schéma réel, les deux configurations, la migration
  versionnée. En corrigeant au passage trois écarts existants entre le doc et
  le code — les index annoncés sur `uploaded`, `timestamp` et `severityRank`
  n'existent pas, la « optional session relationship » non plus, et
  `AuditEventRecord` s'appelle `AuditEventLog`.
- `ARCHITECTURE.md` §5 : `remote-notification`, retrait de `fetch`, coût d'init
  du container sur le contrat de relaunch.
- `CLAUDE.md` : le container iCloud, la promotion du schéma CloudKit en
  Production, le fait que `xcb.sh strings` reste la seule voie pour les
  catalogues.

Déclarations (à trancher, pas décidé ici) :

- `docs/privacy/index.html` : « The app makes no other network requests of any
  kind » (l. ~104), « no networking code » (l. ~48), « You hold the only copy »
  et « No backup is made by the app » (l. ~120) deviennent faux tels quels.
- `metadata/review-notes.md` : l. 16 « never sends it anywhere » et l. 34 « no
  server […] leaves the device only when the user exports it themselves ».
- `metadata/app-privacy.md` : **la nuance décisive**. Apple définit la collecte
  comme un transfert hors de l'appareil « so that **you or a third party** can
  access it ». Le développeur n'a aucun accès à la base privée d'un utilisateur.
  Les nutrition labels *peuvent* donc rester « Data Not Collected » — mais cette
  conclusion doit être écrite noir sur blanc dans ce fichier, avec son
  raisonnement, et non déduite au moment du questionnaire. Le fichier a déjà
  une section « When this must be revisited » prévue exactement pour ça.
- `metadata/version/1.0.0/<locale>.json` dans les 9 locales : uniquement si les
  descriptions affirment que les données restent sur l'appareil — à vérifier
  avant de promettre neuf traductions.

---

## Vérification

```bash
./scripts/xcb.sh test          # toute la suite, y compris les tests de migration
./scripts/xcb.sh strings       # après les nouvelles clés de la phase 5
xcodegen generate              # après la phase 4
```

Vérifier que la configuration Release reste propre de tout code screenshots :

```bash
xcodebuild -project WhereIWas.xcodeproj -target WhereIWas -configuration Release \
  -showBuildSettings | grep SWIFT_ACTIVE_COMPILATION_CONDITIONS   # doit être vide
```

Bout en bout, sur appareil réel (le simulateur ne fait ni CoreMotion, ni
relaunch background, ni visits) :

1. Installer par-dessus une base existante et vérifier qu'aucun sample n'est
   perdu — c'est la vérification la plus importante de tout le plan.
2. Activer la synchronisation, relancer, vérifier la montée dans le CloudKit
   Dashboard (base Development).
3. Deuxième appareil sur le même compte : vérifier l'arrivée de l'historique.
4. Purger sur A, vérifier la propagation sur B.
5. Se déconnecter d'iCloud : vérifier que la base locale reste intacte et que
   l'enregistrement continue.
6. Mesurer la consommation batterie sur une garde simulée, contre le budget de
   référence d'`ARCHITECTURE.md` §5.
