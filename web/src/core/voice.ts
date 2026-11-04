import { loadLocal, saveLocal } from "./identity";

/** Synthèse vocale en français, en file d'attente. `speak("Dans 300 mètres, tournez à droite")`. */
let muted = loadLocal("muted", false);
let voice: SpeechSynthesisVoice | null = null;

function pickVoice() {
  const voices = speechSynthesis.getVoices();
  voice = voices.find((v) => v.lang === "fr-FR" && /Amélie|Thomas|Audrey|Google/i.test(v.name))
    ?? voices.find((v) => v.lang.startsWith("fr")) ?? null;
}
if ("speechSynthesis" in window) {
  pickVoice();
  speechSynthesis.onvoiceschanged = pickVoice;
}

export function speak(text: string, opts: { priority?: boolean } = {}) {
  if (muted || !("speechSynthesis" in window)) return;
  if (opts.priority) speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = "fr-FR";
  if (voice) u.voice = voice;
  u.rate = 1.02;
  speechSynthesis.speak(u);
}

export function isMuted() { return muted; }
export function setMuted(m: boolean) {
  muted = m;
  saveLocal("muted", m);
  if (m && "speechSynthesis" in window) speechSynthesis.cancel();
}
