import json, re, subprocess, sys, time, shlex

out, app, *rest = sys.argv[1:]
steps, args, wait, reboot = [], [], 6.0, False
for a in rest:
    if a.startswith("--args="): args = shlex.split(a[7:])
    elif a.startswith("--wait="): wait = float(a[7:])
    elif a.startswith("--url="): steps.append(("url", a[6:]))
    elif a.startswith("--then="): steps.append(("sleep", float(a[7:])))
    elif a == "--reboot": reboot = True

def sh(*c, check=True, timeout=180):
    return subprocess.run(c, check=check, capture_output=True, text=True, timeout=timeout).stdout

runtimes = json.loads(sh("xcrun", "simctl", "list", "runtimes", "-j"))["runtimes"]
ios = [r for r in runtimes if r.get("platform") == "iOS" and r.get("isAvailable")]
if not ios: sys.exit("Pas de runtime iOS installé (téléchargement : xcodebuild -downloadPlatform iOS)")
rt = ios[-1]
devs = json.loads(sh("xcrun", "simctl", "list", "devices", "-j"))["devices"].get(rt["identifier"], [])
dev = next((d for d in devs if d["name"] == "OsaMaps-Test"), None)
if not dev:
    names = [t["name"] for t in rt.get("supportedDeviceTypes", [])]
    # un iPhone classique (un seul écran) : 18 Pro, sinon 17 Pro, sinon 16 Pro
    pick = next((n for n in ("iPhone 18 Pro", "iPhone 17 Pro", "iPhone 16 Pro") if n in names), None) \
        or next((n for n in names if re.match(r"iPhone \d+$", n)), None) or next(n for n in names if n.startswith("iPhone"))
    tid = next(t["identifier"] for t in rt["supportedDeviceTypes"] if t["name"] == pick)
    udid = sh("xcrun", "simctl", "create", "OsaMaps-Test", tid, rt["identifier"]).strip()
else:
    udid = dev["udid"]
# --reboot : efface une alerte système restée affichée (ex. « Ouvrir dans OsaMaps ? » d'un ancien openurl)
if reboot: sh("xcrun", "simctl", "shutdown", udid, check=False, timeout=120)
sh("xcrun", "simctl", "boot", udid, check=False)
sh("xcrun", "simctl", "bootstatus", udid, "-b", timeout=300)
sh("xcrun", "simctl", "status_bar", udid, "override", "--time", "9:41", "--batteryState", "charged", "--batteryLevel", "100", check=False)
sh("xcrun", "simctl", "location", udid, "set", "46.5646,3.3332", check=False)
bid = "fr.osalabs.osamaps"
sh("xcrun", "simctl", "terminate", udid, bid, check=False)
sh("xcrun", "simctl", "install", udid, app)
# iOS 27 : `simctl openurl` affiche une alerte « Ouvrir dans OsaMaps ? » et le lien n'arrive pas.
# Les liens passent donc par un fichier du conteneur de l'app, lu par Links (simulateur uniquement).
import os
inbox = os.path.join(sh("xcrun", "simctl", "get_app_container", udid, bid, "data").strip(), "Documents")
os.makedirs(inbox, exist_ok=True)
inbox = os.path.join(inbox, "osamaps-links.txt")
if os.path.exists(inbox): os.remove(inbox)
sh("xcrun", "simctl", "launch", udid, bid, *args)
time.sleep(3)
for kind, v in steps:
    if kind == "url":
        with open(inbox, "a") as f: f.write(v + "\n")
        time.sleep(1.5)
    else: time.sleep(v)
time.sleep(wait)
# certains modèles ont plusieurs écrans : on capture l'écran principal
r = subprocess.run(["xcrun", "simctl", "io", udid, "screenshot", "--type=png", out], capture_output=True, text=True)
if r.returncode != 0:
    sh("xcrun", "simctl", "io", udid, "screenshot", "--type=png", "--display=1", out)
logs = sh("xcrun", "simctl", "spawn", udid, "log", "show", "--last", "2m", "--style", "compact", "--predicate", 'process == "OsaMaps" AND (messageType == error OR eventMessage CONTAINS "OsaMaps")', check=False, timeout=60)
print("capture :", out)
print("\n".join(logs.strip().splitlines()[-15:]))
