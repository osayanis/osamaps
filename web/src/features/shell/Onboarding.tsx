import { useEffect, useRef, useState } from "react";
import { usePrefs } from "../../core/prefs";
import { nickname, setNickname, friendCode } from "../../core/identity";
import { startGeo, simulated } from "../../core/geo";
import {
  OsaMapsMark, IconRoute, IconFlag, IconUsers, IconPin, IconGauge, IconHeart,
  IconChevronLeft, IconChevronRight, IconArrowRight, IconCheck, IconWarn,
} from "./icons";
import { haptic } from "./haptics";

/**
 * Accueil au premier lancement (slot "overlay", tant que usePrefs.onboarded = false).
 * Quatre écrans courts : merci → ce que fait OsaMaps → autorisations (expliquées avant d'être
 * demandées) → pseudo, puis la carte. Glisser à gauche/droite, Entrée, ou les boutons.
 * « Revoir l'accueil » (réglages) remet onboarded à false.
 */
const COUNT = 4;

export function Onboarding() {
  const onboarded = usePrefs((s) => s.onboarded);
  if (onboarded) return null;
  return <OnboardingFlow />;
}

function OnboardingFlow() {
  const setPref = usePrefs((s) => s.setPref);
  const [step, setStep] = useState(() => {
    // pour les captures de test : ?onboarding=2
    const n = Number(new URLSearchParams(location.search).get("onboarding"));
    return Number.isFinite(n) && n >= 0 && n < COUNT ? n : 0;
  });
  const [dir, setDir] = useState<1 | -1>(1);
  const [name, setName] = useState(() => nickname());
  const [leaving, setLeaving] = useState(false);
  const root = useRef<HTMLDivElement>(null);

  const go = (n: number) => {
    if (n < 0 || n >= COUNT || n === step) return;
    setDir(n > step ? 1 : -1);
    setStep(n);
    haptic("tap");
  };
  const finish = () => {
    if (name.trim()) setNickname(name);
    haptic("success");
    setLeaving(true);
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    window.setTimeout(() => setPref("onboarded", true), reduce ? 0 : 260);
  };
  const next = () => (step === COUNT - 1 ? finish() : go(step + 1));

  // clavier : Entrée / flèches
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      const typing = (e.target as HTMLElement)?.tagName === "INPUT";
      if (e.key === "Enter") { e.preventDefault(); next(); }
      else if (!typing && e.key === "ArrowRight") go(step + 1);
      else if (!typing && e.key === "ArrowLeft") go(step - 1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  });

  // glisser horizontalement entre les écrans
  const swipe = useRef<{ x: number; y: number } | null>(null);
  const onPointerDown = (e: React.PointerEvent) => {
    if ((e.target as HTMLElement).closest("input, button, label")) return;
    swipe.current = { x: e.clientX, y: e.clientY };
  };
  const onPointerUp = (e: React.PointerEvent) => {
    const s = swipe.current;
    swipe.current = null;
    if (!s) return;
    const dx = e.clientX - s.x, dy = e.clientY - s.y;
    if (Math.abs(dx) > 60 && Math.abs(dx) > Math.abs(dy) * 1.5) go(step + (dx < 0 ? 1 : -1));
  };

  useEffect(() => { root.current?.focus(); }, []);

  return (
    <div ref={root} tabIndex={-1} className={`shell-ob${leaving ? " leaving" : ""}`} role="dialog" aria-modal="true"
      aria-label="Bienvenue dans OsaMaps" onPointerDown={onPointerDown} onPointerUp={onPointerUp}>
      <header className="shell-ob-top">
        <div className="shell-ob-dots" aria-label={`Étape ${step + 1} sur ${COUNT}`}>
          {Array.from({ length: COUNT }, (_, i) => (
            <button key={i} className={`shell-ob-dot${i === step ? " on" : ""}${i < step ? " done" : ""}`}
              aria-label={`Aller à l’étape ${i + 1}`} onClick={() => go(i)} />
          ))}
        </div>
        {step < COUNT - 1 && <button className="btn-ghost" onClick={() => go(COUNT - 1)}>Passer</button>}
      </header>

      <main className={`shell-ob-page ${dir > 0 ? "fwd" : "back"}`} key={step}>
        {step === 0 && <Welcome />}
        {step === 1 && <Features />}
        {step === 2 && <Permissions />}
        {step === 3 && <Nickname name={name} setName={setName} onSubmit={finish} />}
      </main>

      <footer className="shell-ob-bottom">
        {step > 0 ? (
          <button className="btn-ghost shell-ob-back" onClick={() => go(step - 1)}>
            <IconChevronLeft size={18} /> Retour
          </button>
        ) : <span />}
        <button className="pill shell-ob-next" onClick={next}>
          {step === COUNT - 1 ? <>C’est parti <IconArrowRight size={18} /></> : <>Continuer <IconChevronRight size={18} /></>}
        </button>
      </footer>
    </div>
  );
}

/** Les deux derniers mots restent ensemble (pas de mot seul sur la dernière ligne). */
function noOrphan(words: string[]) {
  if (words.length < 4) return words;
  return [...words.slice(0, -2), `${words[words.length - 2]}\u00a0${words[words.length - 1]}`];
}

/** Titre qui apparaît mot par mot. */
function Words({ text, start = 0 }: { text: string; start?: number }) {
  return (
    <h1 className="shell-ob-title" aria-label={text}>
      {noOrphan(text.split(" ")).map((w, i) => (
        <span key={i} aria-hidden="true" className="shell-ob-word" style={{ animationDelay: `${start + i * 55}ms` }}>{w}&nbsp;</span>
      ))}
    </h1>
  );
}

function Welcome() {
  return (
    <div className="shell-ob-center">
      <div className="shell-ob-mark"><OsaMapsMark size={88} /></div>
      <Words text="Merci d’utiliser la suite Osa." start={120} />
      <p className="shell-ob-lead st" style={{ "--i": 6 } as React.CSSProperties}>
        OsaMaps, c’est la route façon Osa : simple, rapide, et partagée avec celles et ceux qui roulent autour de toi.
      </p>
      <p className="shell-ob-sign st" style={{ "--i": 8 } as React.CSSProperties}>
        <IconHeart size={12} /> OsaLabs
      </p>
    </div>
  );
}

function Features() {
  const items = [
    { Icon: IconRoute, title: "Itinéraires et guidage vocal", text: "Le chemin le plus rapide, annoncé à voix haute. Péages et autoroutes à éviter si tu préfères." },
    { Icon: IconFlag, title: "Signalé par la communauté", text: "Police, accident, travaux, bouchon : un appui suffit pour prévenir les autres." },
    { Icon: IconUsers, title: "Tes amis sur la carte", text: "Partage ta position avec qui tu veux, seulement quand tu le décides." },
  ];
  return (
    <div className="shell-ob-stack">
      <Words text="Une carte qui roule avec toi." />
      <div className="shell-ob-list">
        {items.map(({ Icon, title, text }, i) => (
          <div key={title} className="shell-ob-item card st" style={{ "--i": 4 + i * 1.5 } as React.CSSProperties}>
            <span className="shell-ob-item-icon"><Icon /></span>
            <div><b>{title}</b><p>{text}</p></div>
          </div>
        ))}
      </div>
    </div>
  );
}

type GeoState = "unknown" | "prompt" | "granted" | "denied" | "asking" | "unavailable";

function Permissions() {
  const contribute = usePrefs((s) => s.contributeTraffic);
  const setPref = usePrefs((s) => s.setPref);
  const [geo, setGeo] = useState<GeoState>("unknown");

  useEffect(() => {
    if (!("geolocation" in navigator)) { setGeo("unavailable"); return; }
    let status: PermissionStatus | null = null;
    const sync = () => status && setGeo(status.state as GeoState);
    navigator.permissions?.query({ name: "geolocation" as PermissionName })
      .then((s) => { status = s; sync(); s.addEventListener("change", sync); })
      .catch(() => setGeo("prompt"));
    return () => status?.removeEventListener("change", sync);
  }, []);

  const ask = () => {
    setGeo("asking");
    navigator.geolocation.getCurrentPosition(
      () => { setGeo("granted"); haptic("success"); if (!simulated) startGeo(); },
      (err) => setGeo(err.code === err.PERMISSION_DENIED ? "denied" : "prompt"),
      { enableHighAccuracy: true, timeout: 20000 },
    );
  };

  return (
    <div className="shell-ob-stack">
      <Words text="Deux choses, expliquées avant." />
      <div className="shell-ob-list">
        <div className="shell-ob-perm card st" style={{ "--i": 4 } as React.CSSProperties}>
          <span className="shell-ob-item-icon"><IconPin /></span>
          <div className="shell-ob-perm-body">
            <b>Ta position</b>
            <p>Pour te situer sur la carte et te guider. Ce que tu partages ensuite, c’est toi qui choisis.</p>
            <div className="shell-ob-perm-action">
              {geo === "granted" ? (
                <span className="shell-ob-state good"><IconCheck size={16} /> Autorisée</span>
              ) : geo === "denied" ? (
                <span className="shell-ob-state warn"><IconWarn size={16} /> Refusée — réactive-la dans les réglages du navigateur</span>
              ) : geo === "unavailable" ? (
                <span className="shell-ob-state warn"><IconWarn size={16} /> Indisponible sur cet appareil</span>
              ) : (
                <button className="pill" onClick={ask} disabled={geo === "asking"}>
                  {geo === "asking" ? "En attente…" : "Autoriser ma position"}
                </button>
              )}
            </div>
          </div>
        </div>

        <label className="shell-ob-perm card st" style={{ "--i": 5.5 } as React.CSSProperties}>
          <span className="shell-ob-item-icon"><IconGauge /></span>
          <div className="shell-ob-perm-body">
            <b>Aider le trafic, anonymement</b>
            <p>Ta vitesse est envoyée sans ton pseudo, pour colorer les routes en vert, orange ou rouge pour tout le monde.</p>
          </div>
          <Switch checked={contribute} onChange={(v) => setPref("contributeTraffic", v)} label="Contribuer au trafic" />
        </label>
      </div>
      <p className="shell-ob-note st" style={{ "--i": 7 } as React.CSSProperties}>Tout se change plus tard dans les réglages.</p>
    </div>
  );
}

function Nickname({ name, setName, onSubmit }: { name: string; setName: (s: string) => void; onSubmit: () => void }) {
  const input = useRef<HTMLInputElement>(null);
  const code = friendCode();
  useEffect(() => {
    // pas de clavier qui surgit pendant l'animation d'entrée sur téléphone
    const t = window.setTimeout(() => { if (window.matchMedia("(pointer: fine)").matches) input.current?.focus(); }, 300);
    return () => window.clearTimeout(t);
  }, []);
  return (
    <div className="shell-ob-stack">
      <Words text={"Comment on t’appelle\u00a0?"} />
      <form className="shell-ob-form st" style={{ "--i": 4 } as React.CSSProperties}
        onSubmit={(e) => { e.preventDefault(); onSubmit(); }}>
        <input ref={input} className="shell-ob-input" value={name} maxLength={30} autoComplete="nickname"
          placeholder="Ton pseudo" aria-label="Ton pseudo" enterKeyHint="go"
          onChange={(e) => setName(e.target.value)} />
        <p>C’est le nom que verront tes amis. Tu peux laisser vide et le choisir plus tard.</p>
      </form>
      <div className="shell-ob-code card st" style={{ "--i": 5.5 } as React.CSSProperties}>
        <span>Ton code ami</span>
        <b>{code.slice(0, 3)} {code.slice(3)}</b>
      </div>
    </div>
  );
}

export function Switch({ checked, onChange, label }: { checked: boolean; onChange: (v: boolean) => void; label: string }) {
  return (
    <button type="button" role="switch" aria-checked={checked} aria-label={label}
      className={`shell-switch${checked ? " on" : ""}`}
      onClick={(e) => { e.preventDefault(); haptic("tap"); onChange(!checked); }}>
      <span />
    </button>
  );
}
