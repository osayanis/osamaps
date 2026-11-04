import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./styles/tokens.css";
import "./styles/shell.css";
import { registerFeatures } from "./core/registry";
import { FEATURES } from "./features";
import { App } from "./App";
import { core, useCore } from "./core/store";
import { emit, on } from "./core/bus";

// Accès de débogage / tests headless (scripts/shot.mjs) : window.osamaps.core().map …
(window as unknown as { osamaps: unknown }).osamaps = { core, useCore, emit, on };

registerFeatures(FEATURES);

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <App />
  </StrictMode>,
);
