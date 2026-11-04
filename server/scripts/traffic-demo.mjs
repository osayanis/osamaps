// TESTS UNIQUEMENT — simule des voitures qui envoient des `traffic:ping` à un serveur OsaMaps LOCAL.
// Ne jamais lancer contre la production : ce seraient de fausses données de trafic.
//
//   node scripts/traffic-demo.mjs --from=3.3332,46.5646 --to=3.4258,46.1278 \
//        [--server=http://localhost:3105] [--jam-at=2500] [--jam-len=900] [--cars=16] [--speed=6] \
//        [--fluid=6] [--duration=600] [--save-route=route.json] [--route=route.json]
//
// --from/--to : calcule le tracé avec Valhalla (une seule requête) ; --route : réutilise un tracé
// enregistré ([[lng,lat],…]). Les voitures lentes roulent à --speed km/h sur [jam-at, jam-at+jam-len]
// mètres du tracé ; les voitures « fluides » roulent à 70 km/h ailleurs.
import { createRequire } from "node:module";
import { readFile, writeFile } from "node:fs/promises";

// socket.io-client n'est installé que côté web (dépendance de test, pas du serveur)
const require = createRequire(new URL("../../web/package.json", import.meta.url));
const { io } = require("socket.io-client");

const opt = Object.fromEntries(process.argv.slice(2).map((a) => { const [k, ...v] = a.replace(/^--/, "").split("="); return [k, v.join("=") || "1"]; }));
const server = opt.server || "http://localhost:3105";
if (!/localhost|127\.0\.0\.1/.test(server) && !opt["i-know"]) {
  console.error("Refus : ce script envoie de FAUSSES données. Serveur local uniquement.");
  process.exit(1);
}
const jamAt = Number(opt["jam-at"] ?? 2500), jamLen = Number(opt["jam-len"] ?? 900);
const nCars = Number(opt.cars ?? 16), jamKmh = Number(opt.speed ?? 6), nFluid = Number(opt.fluid ?? 6);
const duration = Number(opt.duration ?? 600) * 1000;

const RAD = Math.PI / 180;
const dist = (a, b) => {
  const dLat = (b[1] - a[1]) * RAD, dLng = (b[0] - a[0]) * RAD;
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.sin(dLng / 2) ** 2;
  return 2 * 6371008.8 * Math.asin(Math.sqrt(h));
};
const bearing = (a, b) => {
  const y = Math.sin((b[0] - a[0]) * RAD) * Math.cos(b[1] * RAD);
  const x = Math.cos(a[1] * RAD) * Math.sin(b[1] * RAD) - Math.sin(a[1] * RAD) * Math.cos(b[1] * RAD) * Math.cos((b[0] - a[0]) * RAD);
  return (Math.atan2(y, x) / RAD + 360) % 360;
};
function decode(str, precision = 6) {
  const f = 10 ** precision, out = [];
  let i = 0, lat = 0, lng = 0;
  while (i < str.length) {
    for (const w of [0, 1]) {
      let r = 0, s = 0, b;
      do { b = str.charCodeAt(i++) - 63; r |= (b & 0x1f) << s; s += 5; } while (b >= 0x20);
      const d = r & 1 ? ~(r >> 1) : r >> 1;
      if (w === 0) lat += d; else lng += d;
    }
    out.push([lng / f, lat / f]);
  }
  return out;
}

let coords;
if (opt.route) coords = JSON.parse(await readFile(opt.route, "utf8"));
else {
  const [a, b] = [opt.from || "3.3332,46.5646", opt.to || "3.4258,46.1278"].map((s) => s.split(",").map(Number));
  const r = await fetch("https://valhalla1.openstreetmap.de/route", {
    method: "POST", headers: { "Content-Type": "application/json", "User-Agent": "OsaMaps-test" },
    body: JSON.stringify({ locations: [{ lon: a[0], lat: a[1] }, { lon: b[0], lat: b[1] }], costing: "auto", language: "fr-FR" }),
  });
  const j = await r.json();
  coords = j.trip.legs.flatMap((l) => decode(l.shape));
  if (opt["save-route"]) await writeFile(opt["save-route"], JSON.stringify(coords));
}
const cum = [0];
for (let i = 1; i < coords.length; i++) cum.push(cum[i - 1] + dist(coords[i - 1], coords[i]));
const total = cum[cum.length - 1];
const at = (d) => {
  d = Math.max(0, Math.min(total, d));
  let i = 1; while (i < cum.length - 1 && cum[i] < d) i++;
  const t = (d - cum[i - 1]) / (cum[i] - cum[i - 1] || 1), a = coords[i - 1], b = coords[i];
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t];
};
console.log(`tracé : ${(total / 1000).toFixed(1)} km — bouchon simulé de ${jamAt} à ${jamAt + jamLen} m, ${nCars} voitures à ${jamKmh} km/h, ${nFluid} fluides`);

const cars = [];
for (let i = 0; i < nCars; i++) cars.push({ d: jamAt + (jamLen * i) / Math.max(1, nCars - 1), v: jamKmh / 3.6, lo: jamAt, hi: jamAt + jamLen });
const fluidLo = jamAt + jamLen + 300, fluidHi = Math.min(total, fluidLo + 4000);
for (let i = 0; i < nFluid; i++) cars.push({ d: fluidLo + ((fluidHi - fluidLo) * i) / Math.max(1, nFluid), v: 70 / 3.6, lo: fluidLo, hi: fluidHi });

const tok = () => Math.random().toString(36).slice(2, 12) + Math.random().toString(36).slice(2, 8);
for (const c of cars) {
  c.tok = tok();
  c.prev = at(c.d);
  c.t = Date.now();
  c.socket = io(server, { path: "/maps/socket.io", transports: ["websocket"] });
}

const started = Date.now();
const timer = setInterval(() => {
  const now = Date.now();
  for (const c of cars) {
    const dt = (now - c.t) / 1000;
    c.d += c.v * dt * (0.8 + Math.random() * 0.4);
    if (c.d > c.hi) { c.d = c.lo; c.prev = at(c.d); c.t = now; c.tok = tok(); continue; } // nouveau « trajet »
    const p = at(c.d);
    const h = dist(c.prev, p) > 5 ? bearing(c.prev, p) : bearing(at(c.d - 10), at(c.d + 10));
    c.socket.emit("traffic:ping", { t: c.tok, a: c.prev, b: p, s: dist(c.prev, p) / dt, h: Math.round(h * 10) / 10, dt: Math.round(dt * 10) / 10 });
    c.prev = p; c.t = now;
  }
  if (now - started > duration) { clearInterval(timer); for (const c of cars) c.socket.close(); console.log("fin de la simulation"); }
}, 3500);

setInterval(async () => {
  try { const s = await (await fetch(`${server}/maps/api/traffic/status`)).json(); console.log(new Date().toLocaleTimeString("fr-FR"), JSON.stringify(s.community)); } catch {}
}, 10_000).unref();
