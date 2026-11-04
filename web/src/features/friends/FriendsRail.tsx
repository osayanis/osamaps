import { useCore } from "../../core/store";
import { useFriends, followToken, startTrip, shareLink } from "./store";
import { IconFriends, IconShare } from "./util";

/** Bouton « Amis » (hors conduite) et « Partager mon trajet » (en conduite), sur le rail. */
export function FriendsRail() {
  const mode = useCore((s) => s.mode);
  const panel = useCore((s) => s.panel);
  const openPanel = useCore((s) => s.openPanel);
  const pending = useFriends((s) => s.incoming.length);
  const trip = useFriends((s) => s.trip);
  if (followToken) return null;

  if (mode === "drive") {
    return (
      <button
        className={`round friends-rail-btn${trip ? " is-active" : ""}`}
        aria-label={trip ? "Trajet partagé" : "Partager mon trajet"}
        onClick={async () => {
          if (panel === "share") return openPanel(null);
          if (trip) return openPanel("share");
          const t = await startTrip();
          if (!t) return;
          openPanel("share");
          const dest = useCore.getState().destination?.name ?? "ma destination";
          void shareLink(t.url, "Mon trajet", `Suis mon trajet vers ${dest} en direct`);
        }}
      >
        <IconShare />
        {trip && <span className="friends-rail-live" aria-hidden="true" />}
      </button>
    );
  }

  return (
    <button
      className="round friends-rail-btn"
      aria-label={pending ? `Amis, ${pending} demande${pending > 1 ? "s" : ""}` : "Amis"}
      onClick={() => openPanel(panel === "friends" ? null : "friends")}
    >
      <IconFriends />
      {pending > 0 && <span className="friends-badge">{pending}</span>}
    </button>
  );
}
