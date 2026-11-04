import { useEffect, useState } from "react";
import { useCore, core, type LngLat } from "../../core/store";
import { usePrefs } from "../../core/prefs";
import { nickname } from "../../core/identity";
import { emit } from "../../core/bus";
import { distance, formatDistance } from "../../core/geometry";
import {
  useFriends, addFriend, respond, removeFriend, rename, inviteUrl, shareLink, copy, stopTrip, startTrip, type Friend,
} from "./store";
import {
  initials, prettyCode, statusLine, midpoint, reverseName,
  IconClose, IconBack, IconChevron, IconCopy, IconShare, IconNav, IconMeet, IconLock, IconCheck,
} from "./util";

const PANELS = ["friends", "friend", "share", "friends-invite"];

/** Panneau du bas du module : n'apparaît que si `core.panel` lui appartient. */
export function FriendsSheet() {
  const panel = useCore((s) => s.panel);
  if (!panel || !PANELS.includes(panel)) return null;
  return (
    <section className="friends-sheet glass" aria-label="Amis">
      {panel === "friends" && <FriendsList />}
      {panel === "friend" && <FriendDetail />}
      {panel === "share" && <ShareTrip />}
      {panel === "friends-invite" && <Invite />}
    </section>
  );
}

const close = () => core().openPanel(null);

function Head({ title, back }: { title: string; back?: () => void }) {
  return (
    <header className="friends-head">
      {back && <button className="friends-icon-btn" onClick={back} aria-label="Retour"><IconBack /></button>}
      <h2>{title}</h2>
      <button className="friends-icon-btn" onClick={close} aria-label="Fermer"><IconClose /></button>
    </header>
  );
}

function Avatar({ name, live }: { name: string; live?: boolean }) {
  return <span className={`friends-avatar${live ? " is-live" : ""}`}>{initials(name)}</span>;
}

/** Saisie du pseudo (affichée tant qu'il est vide, et dans les réglages). */
export function NicknameField({ compact }: { compact?: boolean }) {
  const [value, setValue] = useState(nickname());
  const [saved, setSaved] = useState(false);
  const dirty = value.trim() !== nickname();
  return (
    <form className="friends-row-form" onSubmit={(e) => { e.preventDefault(); void rename(value).then(() => { setSaved(true); window.setTimeout(() => setSaved(false), 1500); }); }}>
      <input
        className="friends-input"
        value={value}
        maxLength={30}
        placeholder={compact ? "Ton pseudo" : "Ton pseudo (visible par tes amis)"}
        onChange={(e) => setValue(e.target.value)}
        aria-label="Pseudo"
      />
      <button className="pill" type="submit" disabled={!dirty || !value.trim()}>{saved ? <IconCheck /> : "OK"}</button>
    </form>
  );
}

function AddForm({ initial = "" }: { initial?: string }) {
  const [code, setCode] = useState(initial);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const digits = code.replace(/\D/g, "");
  return (
    <form
      className="friends-row-form"
      onSubmit={async (e) => {
        e.preventDefault();
        setBusy(true);
        const err = await addFriend(digits);
        setBusy(false);
        setError(err);
        if (!err) setCode("");
      }}
    >
      <input
        className="friends-input friends-code-input"
        inputMode="numeric"
        autoComplete="off"
        placeholder="Code ami à 6 chiffres"
        value={code}
        maxLength={7}
        onChange={(e) => { setCode(e.target.value.replace(/[^\d ]/g, "")); setError(null); }}
        aria-label="Code ami"
      />
      <button className="pill" type="submit" disabled={digits.length !== 6 || busy}>Ajouter</button>
      {error && <p className="friends-error" role="alert">{error}</p>}
    </form>
  );
}

function FriendsList() {
  const { me, friends, incoming, outgoing, status, error } = useFriends();
  const shareLocation = usePrefs((s) => s.shareLocation);
  const setPref = usePrefs((s) => s.setPref);
  const position = useCore((s) => s.position);
  const [named, setNamed] = useState(!!nickname());

  const sorted = [...friends].sort((a, b) => Number(!!b.loc?.drive) - Number(!!a.loc?.drive) || Number(!!b.loc) - Number(!!a.loc) || Number(b.online) - Number(a.online) || a.name.localeCompare(b.name, "fr"));

  return (
    <>
      <Head title="Amis" />
      <div className="friends-scroll">
        {status === "error" && <p className="friends-error">{error}</p>}
        {status !== "ready" && status !== "error" && <p className="friends-muted">Connexion…</p>}

        {!named && (
          <div className="friends-block">
            <p className="friends-label">Choisis un pseudo pour que tes amis te reconnaissent</p>
            <div onSubmit={() => setNamed(true)}><NicknameField compact /></div>
          </div>
        )}

        {me && (
          <div className="friends-mycode card">
            <div>
              <p className="friends-label">Mon code ami</p>
              <p className="friends-code">{prettyCode(me.code)}</p>
            </div>
            <div className="friends-mycode-actions">
              <button className="friends-icon-btn" onClick={() => void copy(me.code)} aria-label="Copier mon code"><IconCopy /></button>
              <button className="pill" onClick={() => void shareLink(inviteUrl(me.code), "OsaMaps", `Ajoute-moi en ami sur OsaMaps (code ${prettyCode(me.code)})`)}>
                <IconShare size={18} /> Inviter
              </button>
            </div>
          </div>
        )}

        <AddForm />

        {incoming.length > 0 && (
          <div className="friends-block">
            <p className="friends-label">Demandes reçues</p>
            {incoming.map((r) => (
              <div key={r.pid} className="friends-row">
                <Avatar name={r.name ?? "?"} />
                <div className="friends-row-text"><strong>{r.name}</strong><span>veut t'ajouter</span></div>
                <button className="btn-ghost" onClick={() => void respond(r.pid, false)}>Refuser</button>
                <button className="pill" onClick={() => void respond(r.pid, true)}>Accepter</button>
              </div>
            ))}
          </div>
        )}

        <div className="friends-block">
          <p className="friends-label">{friends.length ? `Mes amis · ${friends.length}` : "Mes amis"}</p>
          {friends.length === 0 && <p className="friends-muted">Pas encore d'amis. Donne ton code ou envoie ton lien d'invitation.</p>}
          {sorted.map((f) => (
            <button key={f.pid} className="friends-row friends-row-btn" onClick={() => core().openPanel("friend", { pid: f.pid })}>
              <Avatar name={f.name} live={!!f.loc} />
              <div className="friends-row-text">
                <strong>{f.name}</strong>
                <span className={f.loc?.drive ? "is-driving" : f.online ? "is-online" : ""}>
                  {statusLine(f)}{f.loc && position && !f.loc.drive ? ` · ${formatDistance(distance(position.coord, [f.loc.lng, f.loc.lat]))}` : ""}
                </span>
              </div>
              <IconChevron />
            </button>
          ))}
        </div>

        {!shareLocation && friends.length > 0 && (
          <div className="friends-hint card">
            <IconLock />
            <div>
              <strong>Ta position n'est pas partagée</strong>
              <span>Si tu l'actives, seuls tes amis acceptés te voient sur la carte. Rien n'est enregistré : ta position s'efface quelques minutes après ton dernier passage.</span>
              <button className="pill secondary" onClick={() => setPref("shareLocation", true)}>Partager avec mes amis</button>
            </div>
          </div>
        )}

        {outgoing.length > 0 && (
          <div className="friends-block">
            <p className="friends-label">Demandes envoyées</p>
            {outgoing.map((r) => (
              <div key={r.pid} className="friends-row">
                <Avatar name="?" />
                <div className="friends-row-text"><strong>Code {prettyCode(r.code)}</strong><span>En attente de réponse</span></div>
                <button className="btn-ghost" onClick={() => void removeFriend(r.pid)}>Annuler</button>
              </div>
            ))}
          </div>
        )}
      </div>
    </>
  );
}

function FriendDetail() {
  const pid = (useCore((s) => s.panelData) as { pid?: string } | null)?.pid;
  const friend = useFriends((s) => s.friends.find((f) => f.pid === pid));
  const position = useCore((s) => s.position);
  const [confirm, setConfirm] = useState(false);
  const [busy, setBusy] = useState(false);
  const back = () => core().openPanel("friends");
  const hasLoc = !!friend?.loc;
  // à l'ouverture, la carte va voir où il est
  useEffect(() => {
    const f = useFriends.getState().friends.find((x) => x.pid === pid);
    const map = core().map;
    if (!f?.loc || !map) return;
    core().set({ follow: false });
    map.easeTo({ center: [f.loc.lng, f.loc.lat], zoom: Math.max(map.getZoom(), 13), padding: { top: 0, bottom: 300, left: 0, right: 0 }, duration: 600 });
  }, [pid, hasLoc]);
  if (!friend) return (<><Head title="Ami" back={back} /><p className="friends-muted">Cet ami n'est plus dans ta liste.</p></>);

  const loc = friend.loc;
  const at: LngLat | null = loc ? [loc.lng, loc.lat] : null;
  const away = at && position ? distance(position.coord, at) : null;

  const join = () => at && emit("place:go", { name: friend.name, lng: at[0], lat: at[1] });
  const meet = async () => {
    if (!at || !position) return;
    setBusy(true);
    const mid = midpoint(position.coord, at);
    const city = await reverseName(mid);
    setBusy(false);
    emit("place:go", { name: city ? `Mi-chemin · ${city}` : "Point à mi-chemin", lng: mid[0], lat: mid[1] });
  };

  return (
    <>
      <Head title={friend.name} back={back} />
      <div className="friends-detail">
        <Avatar name={friend.name} live={!!loc} />
        <div className="friends-row-text">
          <strong className={loc?.drive ? "is-driving" : friend.online ? "is-online" : ""}>{statusLine(friend)}</strong>
          <span>{away != null ? `À ${formatDistance(away)} de toi` : loc ? "Position partagée" : "Ne partage pas sa position"}</span>
        </div>
      </div>
      {at ? (
        <div className="friends-actions">
          <button className="pill" onClick={join}><IconNav /> Rejoindre</button>
          <button className="pill secondary" onClick={() => void meet()} disabled={!position || busy}><IconMeet /> {busy ? "Recherche…" : "À mi-chemin"}</button>
        </div>
      ) : (
        <p className="friends-muted">Quand {friend.name} partagera sa position, tu pourras le rejoindre ou vous retrouver à mi-chemin.</p>
      )}
      <div className="friends-footer">
        <span className="friends-muted">Code {prettyCode(friend.code)}</span>
        {confirm ? (
          <span className="friends-confirm">
            <button className="btn-ghost" onClick={() => setConfirm(false)}>Garder</button>
            <button className="btn-ghost friends-danger" onClick={() => { void removeFriend(friend.pid); back(); }}>Retirer vraiment</button>
          </span>
        ) : (
          <button className="btn-ghost" onClick={() => setConfirm(true)}>Retirer de mes amis</button>
        )}
      </div>
    </>
  );
}

function ShareTrip() {
  const trip = useFriends((s) => s.trip);
  const destination = useCore((s) => s.destination);
  const mode = useCore((s) => s.mode);
  if (!trip) {
    return (
      <>
        <Head title="Partager mon trajet" />
        <p className="friends-muted">Envoie un lien : la personne voit ta voiture avancer et ton heure d'arrivée, sans installer quoi que ce soit. Le lien s'arrête 30 min après ton arrivée.</p>
        <div className="friends-actions">
          <button className="pill" disabled={mode !== "drive"} onClick={() => void startTrip().then((t) => t && shareLink(t.url, "Mon trajet", `Suis mon trajet vers ${destination?.name ?? "ma destination"} en direct`))}>
            <IconShare size={18} /> Créer le lien
          </button>
        </div>
      </>
    );
  }
  return (
    <>
      <Head title="Trajet partagé" />
      <div className="friends-link card">
        <span className="friends-live-dot" aria-hidden="true" />
        <div className="friends-row-text">
          <strong>{trip.watchers ? `${trip.watchers} personne${trip.watchers > 1 ? "s" : ""} te sui${trip.watchers > 1 ? "vent" : "t"}` : "Lien actif"}</strong>
          <span>Vers {destination?.name ?? "ta destination"} · s'arrête 30 min après l'arrivée</span>
        </div>
      </div>
      <div className="friends-actions">
        <button className="pill" onClick={() => void shareLink(trip.url, "Mon trajet", `Suis mon trajet vers ${destination?.name ?? "ma destination"} en direct`)}><IconShare size={18} /> Envoyer</button>
        <button className="pill secondary" onClick={() => void copy(trip.url)}><IconCopy /> Copier</button>
      </div>
      <div className="friends-footer">
        <span />
        <button className="btn-ghost friends-danger" onClick={() => { void stopTrip(); close(); }}>Arrêter le partage</button>
      </div>
    </>
  );
}

function Invite() {
  const code = (useCore((s) => s.panelData) as { code?: string } | null)?.code ?? "";
  const status = useFriends((s) => s.status);
  const [sent, setSent] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  return (
    <>
      <Head title="Ajouter un ami" />
      <p className="friends-muted">Quelqu'un t'a invité sur OsaMaps. Envoie-lui une demande : il pourra l'accepter, puis vous pourrez partager vos positions si vous le souhaitez.</p>
      <div className="friends-mycode card">
        <div><p className="friends-label">Code</p><p className="friends-code">{prettyCode(code)}</p></div>
      </div>
      {!nickname() && <><p className="friends-label">Ton pseudo</p><NicknameField compact /></>}
      {sent && <p className="friends-error" role="alert">{sent}</p>}
      <div className="friends-actions">
        <button className="btn-ghost" onClick={close}>Plus tard</button>
        <button
          className="pill"
          disabled={status !== "ready" || busy}
          onClick={async () => {
            setBusy(true);
            const err = await addFriend(code);
            setBusy(false);
            if (err) setSent(err); else core().openPanel("friends");
          }}
        >
          Envoyer la demande
        </button>
      </div>
    </>
  );
}

export type { Friend };
