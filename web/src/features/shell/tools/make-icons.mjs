// Génère les icônes PNG de la PWA à partir des SVG de web/public/icons (Chrome headless).
//   cd web && node src/features/shell/tools/make-icons.mjs
// Sorties : public/icons/icon-192.png, icon-512.png, maskable-512.png, apple-touch-icon.png (180),
// favicon-32.png. « any » garde ses coins arrondis transparents ; maskable et Apple sont pleins.
import puppeteer from "puppeteer-core";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

const icons = join(dirname(fileURLToPath(import.meta.url)), "../../../../public/icons");
const any = await readFile(join(icons, "osamaps.svg"), "utf8");
const full = await readFile(join(icons, "osamaps-maskable.svg"), "utf8");

const jobs = [
  { svg: any, size: 192, out: "icon-192.png", transparent: true },
  { svg: any, size: 512, out: "icon-512.png", transparent: true },
  { svg: any, size: 32, out: "favicon-32.png", transparent: true },
  { svg: full, size: 512, out: "maskable-512.png" },
  // iOS arrondit lui-même : carré plein, contenu un peu plus grand que la version maskable
  { svg: full.replace("scale(0.72)", "scale(0.82)"), size: 180, out: "apple-touch-icon.png" },
];

const browser = await puppeteer.launch({
  executablePath: process.env.CHROME || "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome",
  headless: true,
});
try {
  const page = await browser.newPage();
  for (const j of jobs) {
    await page.setViewport({ width: j.size, height: j.size, deviceScaleFactor: 1 });
    const svg = j.svg.replace("<svg ", `<svg width="${j.size}" height="${j.size}" `);
    await page.setContent(`<html><body style="margin:0;background:transparent">${svg}</body></html>`);
    await page.screenshot({ path: join(icons, j.out), omitBackground: !!j.transparent, clip: { x: 0, y: 0, width: j.size, height: j.size } });
    console.log("icône :", j.out);
  }
} finally {
  await browser.close();
}
