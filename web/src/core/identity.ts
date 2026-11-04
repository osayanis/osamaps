/**
 * Identité locale, sans compte : un identifiant d'appareil aléatoire, un pseudo et un code ami à
 * 6 chiffres (même format que les codes amis d'OsaNotch). Stockés dans localStorage.
 */
function read(key: string): string | null {
  try { return localStorage.getItem(key); } catch { return null; }
}
function write(key: string, v: string) {
  try { localStorage.setItem(key, v); } catch { /* navigation privée */ }
}

export function deviceId(): string {
  let id = read("osamaps.device");
  if (!id) { id = crypto.randomUUID(); write("osamaps.device", id); }
  return id;
}

export function friendCode(): string {
  let c = read("osamaps.code");
  if (!c || !/^\d{6}$/.test(c)) { c = String(Math.floor(100000 + Math.random() * 900000)); write("osamaps.code", c); }
  return c;
}

export function nickname(): string {
  return read("osamaps.name") ?? "";
}

export function setNickname(name: string) {
  write("osamaps.name", name.trim().slice(0, 30));
}

/** Petit stockage local typé pour les fonctionnalités (préfixe automatique). */
export function loadLocal<T>(key: string, fallback: T): T {
  const raw = read(`osamaps.${key}`);
  if (raw == null) return fallback;
  try { return JSON.parse(raw) as T; } catch { return fallback; }
}
export function saveLocal<T>(key: string, value: T) {
  write(`osamaps.${key}`, JSON.stringify(value));
}
