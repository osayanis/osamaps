import { useEffect } from "react";
import { MapView } from "./core/MapView";
import { slotEntries, allFeatures } from "./core/registry";
import { useCore } from "./core/store";
import { startGeo } from "./core/geo";

/**
 * Le shell : la carte, puis des emplacements fixes où les fonctionnalités se montent.
 *   top     — recherche (mode exploration)
 *   rail    — boutons ronds à droite
 *   sheet   — panneau du bas (empilé)
 *   hud     — affichage de conduite (mode drive)
 *   overlay — plein écran (accueil, toasts, modales)
 *   settings — sections de l'écran Réglages (ouvert par core.settingsOpen)
 */
export function App() {
  const mode = useCore((s) => s.mode);
  const settingsOpen = useCore((s) => s.settingsOpen);

  useEffect(() => {
    startGeo();
    const cleanups = allFeatures().map((f) => f.init?.()).filter(Boolean) as (() => void)[];
    return () => cleanups.forEach((c) => c());
  }, []);

  return (
    <div className={`app mode-${mode}`}>
      <MapView />
      {mode !== "drive" && <div className="slot slot-top">{render("top")}</div>}
      <div className="slot slot-rail">{render("rail")}</div>
      {mode === "drive" && <div className="slot slot-hud">{render("hud")}</div>}
      <div className="slot slot-sheet">{render("sheet")}</div>
      <div className="slot slot-overlay">{render("overlay")}</div>
      {settingsOpen && <Settings />}
    </div>
  );
}

function render(slot: Parameters<typeof slotEntries>[0]) {
  return slotEntries(slot).map(({ featureId, Component }) => <Component key={featureId} />);
}

function Settings() {
  const set = useCore((s) => s.set);
  return (
    <div className="settings" role="dialog" aria-label="Réglages">
      <header className="settings-head">
        <h2>Réglages</h2>
        <button className="btn-ghost" onClick={() => set({ settingsOpen: false })}>Fermer</button>
      </header>
      <div className="settings-body">{render("settings")}</div>
    </div>
  );
}
