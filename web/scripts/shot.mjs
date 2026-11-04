// Capture headless d'OsaMaps (jamais de capture de l'écran du Mac).
//   node scripts/shot.mjs <url> <sortie.png> [--size=390x844] [--wait=4000] [--eval="js à exécuter avant"]
// Attend que la carte soit chargée (window.osamaps.core().mapReady) puis que les tuiles soient idle.
import puppeteer from "puppeteer-core";

const [url, out, ...rest] = process.argv.slice(2);
if (!url || !out) { console.error("usage: node scripts/shot.mjs <url> <out.png> [--size=WxH] [--wait=ms] [--eval=js]"); process.exit(1); }
const opt = Object.fromEntries(rest.map((a) => { const [k, ...v] = a.replace(/^--/, "").split("="); return [k, v.join("=")]; }));
const [w, h] = (opt.size || "390x844").split("x").map(Number);

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
  args: ["--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--hide-scrollbars", "--no-first-run"],
});
try {
  const page = await browser.newPage();
  await page.setViewport({ width: w, height: h, deviceScaleFactor: 2, isMobile: w < 700, hasTouch: w < 700 });
  page.on("console", (m) => { if (m.type() === "error") console.error("[page]", m.text()); });
  page.on("pageerror", (e) => console.error("[pageerror]", e.message));
  await page.goto(url, { waitUntil: "networkidle2", timeout: 45000 });
  await page.waitForFunction(() => window.osamaps?.core().mapReady, { timeout: 30000 }).catch(() => console.error("carte pas prête"));
  if (opt.eval) await page.evaluate(opt.eval);
  await page.evaluate(() => new Promise((r) => { const m = window.osamaps?.core().map; if (!m) return r(); if (m.loaded()) r(); else m.once("idle", r); setTimeout(r, 8000); }));
  await new Promise((r) => setTimeout(r, Number(opt.wait || 1500)));
  await page.screenshot({ path: out });
  console.log("capture :", out);
} finally {
  await browser.close();
}
