import { useEffect, useState } from "react";
import { useCore } from "../../core/store";
import { distance } from "../../core/geometry";
import { categoryById } from "./categories";
import { Icon } from "./icons";
import { distanceLabel } from "./format";
import { closeCategory, runCategory, searchCenter } from "./nearby";
import { Sheet } from "./Sheet";
import { openPlace, useSearch } from "./state";

/** Panneau "search-results" : POI d'une catégorie autour de soi (ou de la zone regardée). */
export function CategoryList() {
  const panel = useCore((s) => s.panel);
  const map = useCore((s) => s.map);
  const position = useCore((s) => s.position);
  const category = useSearch((s) => s.category);
  const [moved, setMoved] = useState(false);

  // la carte a été déplacée loin du centre de recherche → proposer « Rechercher dans cette zone »
  useEffect(() => {
    if (!map || !category) return;
    const check = () => {
      const c = map.getCenter();
      const span = distance([map.getBounds().getWest(), c.lat], [map.getBounds().getEast(), c.lat]);
      setMoved(distance([c.lng, c.lat], category.center) > Math.max(800, span * 0.35));
    };
    check();
    map.on("moveend", check);
    return () => { map.off("moveend", check); };
  }, [map, category?.center]);

  if (panel !== "search-results" || !category) return null;
  const cat = categoryById(category.id);
  if (!cat) return null;
  const ref = position?.coord ?? category.center;

  return (
    <Sheet className="search-list" onClose={closeCategory} ariaLabel={`${cat.label} autour`}>
      <div className="list-head">
        <span className="place-badge"><Icon name={cat.icon} size={20} /></span>
        <div className="place-titles">
          <h2 className="place-name">{cat.label}</h2>
          <div className="place-detail">
            {category.loading ? "Recherche autour…"
              : category.error === "network" ? "Service indisponible"
              : category.results.length ? `${category.results.length} à proximité` : "Rien à proximité"}
          </div>
        </div>
        <button className="place-close" aria-label="Fermer la liste" onClick={closeCategory}><Icon name="x" size={18} /></button>
      </div>

      {moved && !category.loading && (
        <button className="pill secondary list-here" onClick={() => runCategory(category.id, searchCenter())}>
          <Icon name="search" size={16} />Rechercher dans cette zone
        </button>
      )}

      <div className="list-body">
        {category.loading && (
          <div className="search-skeleton">{[0, 1, 2, 3].map((i) => <div key={i} className="search-skel-row"><span /><span /></div>)}</div>
        )}
        {!category.loading && category.error === "network" && (
          <div className="search-hint is-warn">
            La recherche autour de vous ne répond pas.{" "}
            <button className="btn-ghost" onClick={() => runCategory(category.id, category.center)}>Réessayer</button>
          </div>
        )}
        {!category.loading && category.error === "empty" && (
          <div className="search-hint">Aucun résultat « {cat.label.toLowerCase()} » dans un rayon de {cat.maxKm} km.</div>
        )}
        {category.results.map((r, i) => (
          <div key={r.id} className="search-row" onClick={() => openPlace({ ...r, from: "list" })}>
            <span className="search-row-icon list-index">{i + 1}</span>
            <span className="search-row-text">
              <span className="search-row-title">{r.name}</span>
              <span className="search-row-sub">{r.detail || r.typeLabel}</span>
            </span>
            <span className="search-row-meta">{distanceLabel(ref, r.coord)}</span>
          </div>
        ))}
      </div>
    </Sheet>
  );
}
