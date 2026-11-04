import { usePrefs } from "./prefs";

/** Synthèse vocale en français, en file d'attente. `speak("Dans 300 mètres, tournez à droite")`. */
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
  if (!usePrefs.getState().voice || !("speechSynthesis" in window)) return;
  if (opts.priority) speechSynthesis.cancel();
  const u = new SpeechSynthesisUtterance(text);
  u.lang = "fr-FR";
  if (voice) u.voice = voice;
  u.rate = 1.02;
  speechSynthesis.speak(u);
}

/** Une seule source de vérité : la préférence `voice` (Réglages et bouton du guidage restent d'accord). */
export function isMuted() { return !usePrefs.getState().voice; }
export function setMuted(m: boolean) {
  usePrefs.getState().setPref("voice", !m);
}
usePrefs.subscribe((s, prev) => {
  if (prev.voice && !s.voice && "speechSynthesis" in window) speechSynthesis.cancel();
});
