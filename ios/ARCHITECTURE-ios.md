# OsaMaps iOS — architecture

App **native SwiftUI** (iOS 17+), carte **MapKit** (`MKMapView`), qui parle au **même serveur** que la version web
(déjà en ligne : `https://osalabs.fr/maps/api/…` + socket.io `wss://osalabs.fr/maps/socket.io/`).
Le serveur (`../server/features/*.js`) est le contrat : lis le fichier de ton module avant d'écrire le client.
La version web (`../web/src/features/<id>/`) fait déjà tout : c'est la référence fonctionnelle à porter (mêmes
évènements, mêmes panneaux, mêmes textes en français), en mieux grâce au natif.

```
ios/
  project.yml              XcodeGen (le .xcodeproj est généré, pas versionné) : ./build.sh le régénère
  build.sh                 build Simulateur sans signature (au plus 3 builds simultanées sur le Mac)
  tools/simshot.sh         capture de l'écran DU SIMULATEUR (jamais l'écran du Mac), simulateur partagé verrouillé
  OsaMaps/
    App/                   OsaMapsApp, RootView (le shell et ses slots), SettingsScreen
    Core/                  socle commun : NE PAS MODIFIER depuis une branche de fonctionnalité
      Models.swift         Place, Route, Maneuver, Position, Progress, DriveAlert, Toast
      Core.swift           état partagé @Observable (position, follow, mode, destination, routes, progress, panel…)
      Bus.swift            évènements entre modules (placeGo, driveStart/Stop/Arrived, routeRecompute, driveAlert…)
      Registry.swift       Feature, Slot, SlotEntry, SlotView
      MapHub.swift         MapLayer (calques MKMapView : overlays, annotations, sélection, appui long), MapHub.fit
      MapView.swift        la carte + suivi caméra (conduite : suit, s'oriente, s'incline)
      API.swift            API.get/post/json vers le serveur ; External (Valhalla, IGN, Photon, Open-Meteo)
      Socket.swift         client socket.io v4 minimal : on / emit (avec ack) / onConnect
      Location.swift       GPS ou simulateur (-sim 90 -speedup 6), arrière-plan pendant la conduite
      Geometry.swift       Geo : distance, cap, snap au tracé, polyline, formats fr
      Voice.swift          Voice.shared.speak("…") en français (ducking, écran verrouillé)
      Prefs.swift          préférences partagées (éviter péages, voix, partage, trafic, onboarded, vehicle…)
      Vehicle.swift        profil véhicule (voiture / camion / poids lourd / super lourd, dimensions → Valhalla)
      Identity.swift       deviceId, friendCode, nickname ; Store.load/save (JSON, clés préfixées)
      Theme.swift          Osa.* couleurs, .osaPill / .osaRound, .osaCard() / .osaGlass(), Haptic.play
      Links.swift          liens osamaps://go|drive|stop|panel|settings|toast|alert (tests + partages)
    Features/<Id>/         UNE fonctionnalité = UN dossier (tu en es propriétaire)
    Features/Features.swift la liste : ajoute UNE ligne (ta valeur Feature)
  Shared/NavActivity.swift ActivityAttributes de la Live Activity (app + extension)
  OsaMapsLive/             extension WidgetKit : Live Activity (écran verrouillé + Dynamic Island)
```

## Règles du jeu (travail en parallèle)

- Ton dossier `OsaMaps/Features/<Id>/` ; types et fichiers préfixés par ton id (`ReportsSheet`, `ReportsLayer`…)
  pour éviter les collisions de noms (un seul module Swift pour toute l'app).
- **Ne modifie pas `Core/`, `App/`, `project.yml`, `Shared/`, ni le dossier d'un autre module.** Seul fichier partagé :
  `Features/Features.swift` (ta ligne). Exception : le module guidance possède `OsaMapsLive/` ; le module shell possède
  `OsaMaps/Resources/` (icône).
- Communiquer : `Bus.shared.on { event in … }` / `emit(...)`, et `Core.shared` ; jamais d'appel direct à un autre module.
  Besoin d'un évènement en plus : `.custom(name: "<id>:…", payload:)`, et signale-le dans ton rapport.
- Panneaux du bas (slot `.sheet`) : si `core.panel != nil`, seul le propriétaire de ce panneau affiche quelque chose.
  Sinon : `.browse` → search, `.preview` → routing, `.drive` → guidance. Ouvrir : `core.openPanel("reports", data: …)`.
- Carte : calques via `MapLayer` (dans `Feature.mapLayers`) ; reconnais TES objets (sous-classe d'annotation/overlay
  propre au module) et renvoie nil pour les autres. « Ma position » est dessinée par le module mascot.
- Pas de dépendance externe (SwiftPM) sans raison forte : tout est faisable avec le SDK.
- Swift 5.10, iOS 17. Tout ce qui touche à l'UI / Core / Bus est `@MainActor`.

## Design (la sobriété Osa)

Fond quasi noir, blanc à différentes opacités, gras (SF Pro), pilules blanches à texte noir, cartes blanc 5 % + trait 8 %,
verre sombre sur la carte. La couleur ne sert qu'à dire un **état** : trafic (vert / orange / rouge), police (bleu),
danger (jaune), succès. SF Symbols pour les icônes, pas d'émojis dans l'UI. Animations courtes (≤ 300 ms, ease-out),
respecte « Réduire les animations ». Tout en **français**, ton simple et chaleureux. En conduite : cibles ≥ 56 pt,
lisible d'un coup d'œil, Dynamic Type raisonnable.

## Construire et vérifier

```bash
cd ios && ./build.sh                                   # doit afficher BUILD SUCCEEDED (zéro erreur)
tools/simshot.sh /chemin/capture.png --args="-sim 60 -onboarded YES" \
  --url="osamaps://go?name=Vichy&lat=46.1278&lng=3.4258" --wait=8      # aperçu d'itinéraire
tools/simshot.sh /chemin/drive.png --args="-sim 90 -speedup 6 -onboarded YES" \
  --url="osamaps://go?name=Vichy&lat=46.1278&lng=3.4258" --then=6 --url="osamaps://drive" --wait=15
```

Arguments de lancement utiles : `-sim <km/h>`, `-speedup <n>`, `-onboarded YES` (sauter l'accueil),
`-api http://localhost:3005/maps/api/` (serveur local). Les PNG produits sont l'écran du simulateur uniquement.
