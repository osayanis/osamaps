import { useCore, core } from "../../core/store";
import { Icon } from "./Icon";

/** Ids de panneaux possédés par ce module. */
export const PANEL = "reports";
export const DETAIL = "report-detail";

interface Back { panel: string | null; data: unknown }
export interface PanelData { back?: Back; id?: string }

/** Ouvre un panneau du module en mémorisant celui qu'on remplace (on y revient à la fermeture). */
export function openOwn(panel: typeof PANEL | typeof DETAIL, extra: Omit<PanelData, "back"> = {}) {
  const { panel: cur, panelData } = core();
  const own = cur === PANEL || cur === DETAIL;
  const back: Back = own ? ((panelData as PanelData | null)?.back ?? { panel: null, data: null }) : { panel: cur, data: panelData };
  core().openPanel(panel, { ...extra, back } satisfies PanelData);
}

export function closeOwn() {
  const { panel, panelData } = core();
  if (panel !== PANEL && panel !== DETAIL) return;
  const back = (panelData as PanelData | null)?.back;
  core().openPanel(back?.panel ?? null, back?.data);
}

/** Bouton rond « Signaler » (rail). Plus grand et blanc en conduite. */
export function ReportButton() {
  const mode = useCore((s) => s.mode);
  const open = useCore((s) => s.panel === PANEL);
  const drive = mode === "drive";
  return (
    <button
      className={`round reports-fab${drive ? " is-drive" : ""}${open ? " is-open" : ""}`}
      aria-label="Signaler"
      title="Signaler"
      onClick={() => (open ? closeOwn() : openOwn(PANEL))}
    >
      <Icon name="flag" size={drive ? 28 : 22} />
    </button>
  );
}
