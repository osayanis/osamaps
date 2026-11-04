// Serveur OsaMaps : API HTTP (/maps/api/*) + temps réel (socket.io sur /maps/socket.io).
// Chaque fonctionnalité serveur est un fichier `features/<id>.js` qui exporte
// `register({ io, route, store, log })`. Ils sont chargés automatiquement.
import { createServer } from "node:http";
import { readdir } from "node:fs/promises";
import { Server } from "socket.io";
import { createStore } from "./lib/store.js";
import { createRouter } from "./lib/router.js";

const PORT = Number(process.env.PORT) || 3005;
const router = createRouter("/maps/api");
const http = createServer((req, res) => router.handle(req, res));
const io = new Server(http, {
  path: "/maps/socket.io",
  cors: { origin: ["https://osalabs.fr", "http://localhost:5175"] },
  maxHttpBufferSize: 64 * 1024,
});
const store = createStore(new URL("./data/", import.meta.url));
const log = (...a) => console.log(new Date().toISOString(), ...a);

router.get("/health", () => ({ ok: true, time: Date.now() }));

const dir = new URL("./features/", import.meta.url);
for (const f of (await readdir(dir)).filter((f) => f.endsWith(".js")).sort()) {
  const mod = await import(new URL(f, dir));
  await mod.register({ io, route: router, store, log });
  log("fonctionnalité chargée :", f);
}

http.listen(PORT, () => log(`OsaMaps prêt sur :${PORT}`));
for (const sig of ["SIGINT", "SIGTERM"]) process.on(sig, async () => { await store.flushAll(); process.exit(0); });
