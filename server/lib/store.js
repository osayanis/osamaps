// Stockage JSON simple et sûr : une « collection » = un fichier data/<nom>.json, gardé en mémoire,
// écrit (atomiquement) au plus toutes les 5 s quand il a changé.
//   const reports = await store.collection("reports", []);   reports.data.push(x); reports.save();
import { mkdir, readFile, writeFile, rename } from "node:fs/promises";

export function createStore(dirUrl) {
  const cols = new Map();
  let ready = mkdir(dirUrl, { recursive: true });

  async function collection(name, initial) {
    if (cols.has(name)) return cols.get(name);
    await ready;
    const file = new URL(`${name}.json`, dirUrl);
    let data = initial;
    try { data = JSON.parse(await readFile(file, "utf8")); } catch { /* nouveau */ }
    let dirty = false, timer = null;
    const col = {
      get data() { return data; },
      set data(v) { data = v; col.save(); },
      save() {
        dirty = true;
        timer ??= setTimeout(() => { timer = null; col.flush(); }, 5000);
      },
      async flush() {
        if (!dirty) return;
        dirty = false;
        const tmp = new URL(`${name}.json.tmp`, dirUrl);
        await writeFile(tmp, JSON.stringify(data));
        await rename(tmp, file);
      },
    };
    cols.set(name, col);
    return col;
  }

  async function flushAll() { await Promise.all([...cols.values()].map((c) => c.flush())); }

  return { collection, flushAll };
}
