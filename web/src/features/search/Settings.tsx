import { useState } from "react";
import { emit } from "../../core/bus";
import { Icon } from "./icons";
import { ago } from "./format";
import {
  clearRecents, forgetCar, removeFavorite, renameFavorite, setShortcut, startPicking, useSearch, type Saved,
} from "./state";

/** Section Réglages « Mes lieux » : Maison, Travail, favoris, voiture, historique. */
export function SearchSettings() {
  const { home, work, favorites, recents, car } = useSearch();
  const [editing, setEditing] = useState<string | null>(null);
  const [draft, setDraft] = useState("");
  const [confirmClear, setConfirmClear] = useState(false);

  const shortcut = (which: "home" | "work", p: Saved | null) => (
    <div className="set-row">
      <span className="set-icon"><Icon name={which} size={18} /></span>
      <span className="set-text">
        <span className="set-title">{which === "home" ? "Maison" : "Travail"}</span>
        <span className="set-sub">{p ? p.detail ? `${p.name}, ${p.detail}` : p.name : "Non définie"}</span>
      </span>
      <button className="btn-ghost" onClick={() => startPicking(which)}>{p ? "Modifier" : "Définir"}</button>
      {p && (
        <button className="set-iconbtn" aria-label={`Retirer ${which === "home" ? "Maison" : "Travail"}`} onClick={() => setShortcut(which, null)}>
          <Icon name="trash" size={16} />
        </button>
      )}
    </div>
  );

  return (
    <section className="card set-card" aria-labelledby="search-settings-title">
      <h3 id="search-settings-title" className="set-h">Mes lieux</h3>
      {shortcut("home", home)}
      {shortcut("work", work)}

      <div className="set-sep" />
      <div className="set-subhead">
        <span>Favoris</span>
        <button className="btn-ghost" onClick={() => startPicking("favorite")}><Icon name="plus" size={14} /> Ajouter</button>
      </div>
      {favorites.length === 0 && <p className="set-note">Ajoutez un lieu en favori depuis sa fiche (étoile).</p>}
      {favorites.map((f) => (
        <div className="set-row" key={f.id}>
          <span className="set-icon"><Icon name="star" size={18} /></span>
          {editing === f.id ? (
            <form
              className="set-edit"
              onSubmit={(e) => { e.preventDefault(); renameFavorite(f.id, draft); setEditing(null); }}
            >
              <input
                autoFocus
                className="set-input"
                value={draft}
                maxLength={60}
                onChange={(e) => setDraft(e.target.value)}
                onKeyDown={(e) => { if (e.key === "Escape") setEditing(null); }}
                aria-label="Nouveau nom"
              />
              <button className="set-iconbtn" type="submit" aria-label="Valider"><Icon name="check" size={16} /></button>
            </form>
          ) : (
            <>
              <span className="set-text">
                <span className="set-title">{f.name}</span>
                {f.detail && <span className="set-sub">{f.detail}</span>}
              </span>
              <button className="set-iconbtn" aria-label={`Renommer ${f.name}`} onClick={() => { setEditing(f.id); setDraft(f.name); }}>
                <Icon name="edit" size={16} />
              </button>
              <button className="set-iconbtn" aria-label={`Supprimer ${f.name}`} onClick={() => removeFavorite(f.id)}>
                <Icon name="trash" size={16} />
              </button>
            </>
          )}
        </div>
      ))}

      <div className="set-sep" />
      <div className="set-row">
        <span className="set-icon"><Icon name="car" size={18} /></span>
        <span className="set-text">
          <span className="set-title">Ma voiture</span>
          <span className="set-sub">
            {car ? `Garée ${car.time ? ago(car.time) : ""}${car.detail ? ` · ${car.detail}` : ""}` : "Enregistrée automatiquement à l'arrivée"}
          </span>
        </span>
        {car && <button className="btn-ghost" onClick={() => { forgetCar(); emit("toast", { text: "Stationnement oublié" }); }}>Oublier</button>}
      </div>

      <div className="set-sep" />
      <div className="set-row">
        <span className="set-icon"><Icon name="history" size={18} /></span>
        <span className="set-text">
          <span className="set-title">Historique de recherche</span>
          <span className="set-sub">{recents.length ? `${recents.length} lieu${recents.length > 1 ? "x" : ""} récent${recents.length > 1 ? "s" : ""}, gardés sur cet appareil` : "Vide"}</span>
        </span>
        {recents.length > 0 && (
          confirmClear ? (
            <button className="pill set-danger" onClick={() => { clearRecents(); setConfirmClear(false); emit("toast", { text: "Historique effacé", tone: "good" }); }}>
              Confirmer
            </button>
          ) : (
            <button className="btn-ghost" onClick={() => setConfirmClear(true)}>Effacer</button>
          )
        )}
      </div>
    </section>
  );
}
