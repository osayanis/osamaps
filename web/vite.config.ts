import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Servi en production sous https://osalabs.fr/maps/ (Nginx → dist statique ; /maps/api et
// /maps/socket.io → serveur Node sur le port 3005). En dev, mêmes chemins via le proxy.
// Ports réglables pour faire tourner plusieurs copies en parallèle : WEB_PORT=5201 API_PORT=3101 npm run dev
const api = `http://localhost:${process.env.API_PORT || 3005}`;

export default defineConfig({
  base: "/maps/",
  plugins: [react()],
  server: {
    port: Number(process.env.WEB_PORT) || 5175,
    strictPort: true,
    proxy: {
      "/maps/api": api,
      "/maps/socket.io": { target: api, ws: true },
    },
  },
  preview: { port: Number(process.env.WEB_PORT) || 4175, proxy: { "/maps/api": api, "/maps/socket.io": { target: api, ws: true } } },
});
