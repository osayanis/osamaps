import { useEffect, useState, type ReactNode } from "react";
import { usePrefs } from "../../core/prefs";
import { core, useCore } from "../../core/store";
import { loadLocal, saveLocal } from "../../core/identity";
import { DEFAULT_CENTER } from "../../core/geo";
import { sunTimes } from "./sun";
import { usePwa, canInstall, installApp, wipeLocalData } from "./pwa";
import { haptic } from "./haptics";
import { Switch } from "./Onboarding";
import { VehicleRow } from "./Vehicle";
import {
  IconAuto, IconSun, IconMoon, IconDownload, IconRefresh, IconTrash, IconHeart, IconExternal,
} from "./icons";

/** Version affichée dans « À propos » (garder en phase avec web/package.json). */
export const APP_VERSION = "0.1.0";

/** Brique de section de réglages : titre + carte de lignes. */
function Section({ title, children, place }: { title: string; children: ReactNode; place: "top" | "bottom" }) {
  return (
    <section className={`shell-set ${place}`}>
      <h3>{title}</h3>
      <div className="shell-set-card card">{children}</div>
    </section>
  );
}

function Row({ label, hint, children, onClick, danger }: { label: string; hint?: ReactNode; children?: ReactNode; onClick?: () => void; danger?: boolean }) {
  const body = (
    <>
      <div className="shell-set-text">
        <span className={danger ? "danger" : undefined}>{label}</span>
        {hint && <small>{hint}</small>}
      </div>
      {children}
    </>
  );
  return onClick
    ? <button className="shell-set-row clickable" onClick={onClick}>{body}</button>
    : <div className="shell-set-row">{body}</div>;
}

const fmt = (d: Date) => d.toLocaleTimeString("fr-FR", { hour: "2-digit", minute: "2-digit" });

/** Section « Général » (en haut des réglages). */
export function GeneralSettings() {
  const mapStyle = usePrefs((s) => s.mapStyle);
  const setPref = usePrefs((s) => s.setPref);
  const coord = useCore((s) => s.position?.coord) ?? DEFAULT_CENTER;
  const pwa = usePwa();
  const [vibrate, setVibrate] = useState(() => loadLocal("shell.haptics", true));
  const canVibrate = typeof navigator.vibrate === "function";

  const sun = sunTimes(new Date(), coord[1], coord[0]);
  const styles = [
    { id: "auto", label: "Auto", Icon: IconAuto },
    { id: "light", label: "Clair", Icon: IconSun },
    { id: "dark", label: "Sombre", Icon: IconMoon },
  ] as const;

  return (
    <Section title="Général" place="top">
      <div className="shell-set-row column">
        <div className="shell-set-text">
          <span>Style de carte</span>
          <small>
            {mapStyle === "auto"
              ? sun ? `Clair de ${fmt(sun.sunrise)} à ${fmt(sun.sunset)}, sombre le reste du temps.` : "Selon le jour et la nuit."
              : mapStyle === "light" ? "Toujours clair." : "Toujours sombre."}
          </small>
        </div>
        <div className="shell-seg" role="radiogroup" aria-label="Style de carte">
          {styles.map(({ id, label, Icon }) => (
            <button key={id} role="radio" aria-checked={mapStyle === id}
              className={`shell-seg-btn${mapStyle === id ? " on" : ""}`}
              onClick={() => { haptic("tap"); setPref("mapStyle", id); }}>
              <Icon size={18} /> {label}
            </button>
          ))}
        </div>
      </div>
      <Row label="Unités" hint="Distances en kilomètres, vitesses en km/h.">
        <span className="shell-set-value">km · km/h</span>
      </Row>
      {canVibrate && (
        <Row label="Vibrations" hint="Un petit retour sur les actions importantes et les alertes.">
          <Switch checked={vibrate} label="Vibrations" onChange={(v) => { setVibrate(v); saveLocal("shell.haptics", v); }} />
        </Row>
      )}
      {canInstall(pwa) && (
        <Row label="Installer OsaMaps" hint={pwa.ios ? "Partager → « Sur l’écran d’accueil »." : "Plein écran, lancé comme une app."}
          onClick={() => void installApp()}>
          <IconDownload size={20} />
        </Row>
      )}
    </Section>
  );
}

/** Section « Véhicule » (juste sous « Général ») : voiture, camion, poids lourd, super lourd + dimensions. */
export function VehicleSettings() {
  return (
    <Section title="Véhicule" place="top">
      <VehicleRow />
    </Section>
  );
}

/** Section « Accueil, données, à propos » (en bas des réglages). */
export function AboutSettings() {
  const setPref = usePrefs((s) => s.setPref);
  const [confirm, setConfirm] = useState(false);
  useEffect(() => {
    if (!confirm) return;
    const t = window.setTimeout(() => setConfirm(false), 4000);
    return () => window.clearTimeout(t);
  }, [confirm]);

  const replay = () => {
    core().set({ settingsOpen: false });
    setPref("onboarded", false);
  };
  const wipe = () => {
    if (!confirm) { haptic("warn"); setConfirm(true); return; }
    haptic("error");
    void wipeLocalData();
  };

  return (
    <>
      <Section title="Accueil et données" place="bottom">
        <Row label="Revoir l’accueil" hint="Les écrans du premier lancement." onClick={replay}>
          <IconRefresh size={20} />
        </Row>
        <Row label={confirm ? "Touchez encore pour tout effacer" : "Effacer toutes mes données locales"} danger
          hint="Réglages, pseudo, code ami et tout ce qu’OsaMaps garde sur cet appareil. Irréversible."
          onClick={wipe}>
          <IconTrash size={20} />
        </Row>
      </Section>

      <Section title="À propos" place="bottom">
        <div className="shell-set-about">
          <div className="shell-set-about-head">
            <b>OsaMaps</b>
            <span>Version {APP_VERSION}</span>
          </div>
          <p className="shell-set-made"><IconHeart size={12} /> Fait par Yanis, OsaLabs</p>
          <a className="shell-set-row clickable" href="https://osalabs.fr" target="_blank" rel="noopener">
            <div className="shell-set-text"><span>osalabs.fr</span><small>Toute la suite Osa</small></div>
            <IconExternal size={18} />
          </a>
          <div className="shell-set-credits">
            <p>Carte © les contributeurs <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a>.</p>
            <p>Tuiles <a href="https://openfreemap.org" target="_blank" rel="noopener">OpenFreeMap</a> · itinéraires <a href="https://valhalla.github.io/valhalla/" target="_blank" rel="noopener">Valhalla</a> (serveur FOSSGIS) · adresses <a href="https://geoservices.ign.fr" target="_blank" rel="noopener">IGN</a> / Base Adresse Nationale · lieux <a href="https://photon.komoot.io" target="_blank" rel="noopener">Photon</a>.</p>
          </div>
        </div>
      </Section>
    </>
  );
}
