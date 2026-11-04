# OsaMaps — architecture

La navigation de la suite Osa : une PWA (React + MapLibre) servie sous **https://osalabs.fr/maps/**, et un petit serveur
Node (API + socket.io) pour tout ce qui est communautaire et temps réel.

```
web/                      Vite + React 18 + TypeScript + MapLibre GL 4 + zustand
  src/core/               socle commun : NE PAS MODIFIER depuis une branche de fonctionnalité
    registry.ts           Feature / slots
    store.ts              état partagé (carte, position, mode, itinéraires, panneau ouvert…)
    prefs.ts              préférences persistées (éviter péages, voix, partage…)
    bus.ts                évènements entre modules (place:go, drive:start, drive:alert, route:recompute…)
    geo.ts                GPS ou simulateur (?sim=90&speedup=4)
    geometry.ts           distances, caps, accrochage au tracé, polyline, formats fr-FR
    services.ts           api(), URLs des services externes, getSocket()
    identity.ts           deviceId, code ami, pseudo, loadLocal/saveLocal
    voice.ts              speak() en français
    MapView.tsx           la carte plein écran + suivi de position
  src/App.tsx             le shell : emplacements top / rail / sheet / hud / overlay / settings
  src/features/<id>/      UNE fonctionnalité = UN dossier (tu en es propriétaire)
  src/features/index.ts   la liste : chaque module ajoute une ligne d'import + une entrée
  scripts/shot.mjs        capture headless (Chrome sans fenêtre) pour vérifier le rendu
server/
  index.js                http + socket.io (path /maps/socket.io), charge features/*.js
  lib/router.js           route.get/post(path, handler) — renvoie du JSON ; HttpError(status, msg)
  lib/store.js            store.collection(nom, initial) → { data, save() } (JSON sur disque)
  features/<id>.js        export async function register({ io, route, store, log })
deploy/                   Nginx + pm2 (VPS)
```

## Règles du jeu (travail en parallèle)

- Une fonctionnalité vit dans `web/src/features/<id>/` (+ `server/features/<id>.js` si besoin).
  **Ne modifie pas `src/core/`, `App.tsx`, `styles/` ni le dossier d'un autre module.**
- Seul fichier partagé à toucher : `web/src/features/index.ts` (ta ligne d'import + ton entrée).
- Besoin de quelque chose dans le socle ? Fais-le localement dans ton dossier et signale-le dans
  ton rapport (« à remonter dans core »). Besoin d'un évènement de plus ? Déclare un petit émetteur
  local, ou utilise `emit("toast", …)` / `drive:alert` qui existent déjà.
- Communiquer entre modules : le **bus** (`on`/`emit`) et le **store** (`useCore`), jamais d'import
  direct du dossier d'un autre module.
- Styles : un fichier CSS par module (`features/<id>/<id>.css`), classes préfixées par l'id
  (`.reports-…`). Utilise les variables de `styles/tokens.css` et les briques `.glass .card .pill
  .round .btn-ghost` de `styles/shell.css`.
- Calques de carte : ids préfixés (`reports-points`, `routing-line`…), ajoutés dans un composant du
  slot `map` (monté quand la carte est prête) et retirés au démontage. Le style peut être rechargé
  (clair/sombre) : réécoute `map.on("style.load", …)` pour remettre tes sources/calques.
- Serveur : routes sous `/<id>/…` (ex. `route.get("/reports", …)`), évènements socket préfixés
  (`reports:new`). Valide TOUT ce qui arrive du client (types, bornes, longueur des textes), limite
  le débit, ne stocke jamais d'IP ni de position précise d'un utilisateur au-delà du besoin.

## Design (la sobriété Osa)

Fond quasi noir, blanc à différentes opacités, gras, pilules blanches à texte noir, cartes blanc 5 %
avec un trait 8 %. La couleur ne sert qu'à dire un **état** : trafic (vert / orange / rouge), police
(bleu), danger (jaune), succès. Pas de dégradés décoratifs, pas d'émojis comme icônes dans l'UI
(SVG simples, trait 2 px, coins ronds). Animations courtes (≤ 300 ms, `var(--ease-out)`), sur
`transform`/`opacity` uniquement, et `prefers-reduced-motion` respecté. Tout en **français**, ton
simple et chaleureux. Pensé d'abord pour le téléphone (390 × 844), utilisable d'une main, gros
boutons (≥ 44 px) en conduite.

## Lancer et vérifier

```bash
cd server && PORT=3005 node index.js           # API + temps réel
cd web && npm run dev                          # http://localhost:5175/maps/?sim=60
# plusieurs copies en parallèle : API_PORT=3101 WEB_PORT=5201 npm run dev ; PORT=3101 node index.js
cd web && npm run build                        # doit passer sans erreur TypeScript
node scripts/shot.mjs "http://localhost:5175/maps/?sim=60" /chemin/capture.png --size=390x844 \
  --eval="window.osamaps.emit('place:go', { name: 'Vichy', lng: 3.4258, lat: 46.1278 })"
```

`window.osamaps` expose `core()`, `useCore`, `emit`, `on` pour piloter l'app depuis un test headless.
**Jamais de capture de l'écran du Mac** : seulement `scripts/shot.mjs` (Chrome headless).

## Production

- Web : `web/dist` copié dans `/var/www/osamaps/web` ; Nginx (site osalabs) sert `/maps/`.
- Serveur : `/var/www/osamaps/server`, pm2 `osamaps`, port 3005 ; `/maps/api/` et `/maps/socket.io/`
  proxifiés. Données : `server/data/` (hors git).
