#!/usr/bin/env python3
"""Etat du robot ORACLE pour la page ORACLE PRO (cle « robot » de live.html).
Lit les tickets GitHub n°1 (journal) et n°2 (signal de vie) du depot public.
Usage : python3 robot_status.py [biais.json] > robot.json
biais.json (optionnel) : liste [{"code","bias","date","why"}] lue dans le plan."""
import json, sys, urllib.request, datetime, collections

REPO = "ayaohsa-max/oracle-signals"

def comments(issue):
    try:
        return comments_http(issue)
    except Exception:
        import subprocess
        r = subprocess.run(["gh", "api", "--paginate",
                            f"repos/{REPO}/issues/{issue}/comments?per_page=100"],
                           capture_output=True, text=True, timeout=120, check=True)
        txt = r.stdout.replace("][", ",")
        return json.loads(txt) if txt.strip() else []

def comments_http(issue):
    out, page = [], 1
    while True:
        url = f"https://api.github.com/repos/{REPO}/issues/{issue}/comments?per_page=100&page={page}"
        with urllib.request.urlopen(urllib.request.Request(url, headers={"User-Agent": "oracle-status"}), timeout=30) as r:
            d = json.load(r)
        if not d:
            break
        out += d
        page += 1
        if page > 20:
            break
    return out

now = datetime.datetime.now(datetime.timezone.utc)
alerts = []

# --- signal de vie
beats = collections.OrderedDict()
for c in comments(2):
    f = c["body"].split(";")
    if f[0] != "HEARTBEAT" or len(f) < 11:
        continue
    key = (f[1], f[3])
    beats[key] = dict(login=f[1], type=f[2], server=f[3], version=f[4], last=f[5], state=f[6],
                      consignes=f[7], ideas=f[8], equity=f[9], ccy=f[10], created=c["created_at"],
                      positions=(f[11] if len(f) > 11 else ""), pending=(f[12] if len(f) > 12 else ""))
accounts = []
by_login = collections.defaultdict(list)
for b in beats.values():
    t = datetime.datetime.fromisoformat(b["created"].replace("Z", "+00:00"))
    age = int((now - t).total_seconds() // 60)
    if age > 3 * 24 * 60:
        continue                       # compte silencieux depuis plus de 3 jours (robot retiré) : on ne l'affiche plus
    b["age_min"] = age
    st = b["state"].lower()
    weekday = now.weekday() < 5
    flag = "ok"
    if "arrêt définitif" in st or "perte" in st:
        flag = "alerte"
    elif st.startswith("arrêt") or st.startswith("pause"):
        flag = "pause"
    if weekday and age > 90 and flag == "ok":
        flag = "silence"
    b["flag"] = flag
    by_login[b["login"]].append(b)
    accounts.append(b)
for a in accounts:
    if a["flag"] == "alerte":
        alerts.append(f"Compte {a['login']} ({a['type']}) : {a['state']}")
    elif a["flag"] == "silence":
        alerts.append(f"Compte {a['login']} : aucun signal de vie depuis {a['age_min']} min (PC, réseau ou MT5 coupé ?)")
# deux robots sur le meme compte : plus de signaux de vie que prevu sur les 3 dernieres heures (1 par heure attendu)
cnt = collections.Counter()
for c in comments(2)[-300:]:
    f = c["body"].split(";")
    if f[0] == "HEARTBEAT" and len(f) > 6:
        t = datetime.datetime.fromisoformat(c["created_at"].replace("Z", "+00:00"))
        if (now - t).total_seconds() < 3 * 3600:
            cnt[f[1]] += 1
for login, k in cnt.items():
    if k >= 5:
        alerts.append(f"Compte {login} : deux robots semblent tourner sur le même compte (à retirer d'un des deux MetaTrader)")
accounts.sort(key=lambda x: x["age_min"])
for a in accounts:
    a.pop("created", None)

# --- journal
sig, res, days = [], [], []
ws_setups, ws_res, ws_real = [], [], []
seen_bodies = set()
for c in comments(1):
    if c["body"] in seen_bodies:
        continue                       # ligne en double dans le journal
    seen_bodies.add(c["body"])
    f = c["body"].split(";")
    if f[0] == "SAVWS_SETUP" and len(f) >= 14:
        ws_setups.append(dict(code=f[2], tf=f[4], side="Achat" if f[5] == "BUY" else "Vente", time=f[6],
                              entry=f[7], sl=f[8], tp=f[9], rr=f[10], conf=f[12], mode=f[13]))
    elif f[0] == "SAVWS_RESULT" and len(f) >= 9:
        try:
            ws_res.append(dict(code=f[2], tf=f[4], why=f[7], r=float(f[8])))
        except ValueError:
            pass
    elif f[0] == "ORACLE_TRADE" and len(f) >= 16 and f[2].startswith("W"):
        try:
            ws_real.append(float(f[15]))
        except ValueError:
            pass
    if f[0] == "SAV_SIGNAL" and len(f) >= 11:
        sig.append(dict(time=f[6], code=f[2], tf=f[4], side="Achat" if f[5] == "BUY" else "Vente",
                        entry=f[7], sl=f[8], tp=f[9], taken={"OBS": "observé", "PRIS": "pris", "NON_PRIS": "non pris"}.get(f[10], f[10])))
    elif f[0] == "SAV_RESULT" and len(f) >= 10:
        try:
            res.append(float(f[8]))
        except ValueError:
            pass
    elif f[0] == "ORACLE_DAY" and len(f) >= 8:
        d = f[2]
        days.append(dict(login=f[1], date=f"{d[6:8]}/{d[4:6]}/{d[0:4]}", balance=f[3], equity=f[4], peak=f[5], pnl=f[6], ccy=f[7]))
n = len(res)
results = dict(n=n, win=(f"{100*sum(1 for r in res if r > 0)/n:.0f} %" if n else None),
               exp=(round(sum(res) / n, 2) if n else None))
biases = []
if len(sys.argv) > 1:
    try:
        biases = json.load(open(sys.argv[1], encoding="utf-8"))
    except Exception:
        pass
def _stats(rs):
    n = len(rs)
    if not n:
        return dict(n=0, exp=None, win=None, pf=None)
    gain = sum(r for r in rs if r > 0); loss = -sum(r for r in rs if r <= 0)
    return dict(n=n, exp=round(sum(rs) / n, 2), win=f"{100*sum(1 for r in rs if r > 0)/n:.0f} %",
                pf=(round(gain / loss, 2) if loss > 0 else None))
savws = dict(setups=len(ws_setups), sim=_stats([x["r"] for x in ws_res]), real=_stats(ws_real),
             recent=list(reversed(ws_setups))[:10], target=30)
# interrupteur crypto week-end : 8e champ de la ligne HEADER du fichier de consignes publié (v1.15)
cw = None
try:
    import os
    for ln in open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "oracle_signals.csv"), encoding="utf-8"):
        if ln.startswith("HEADER;"):
            hf = ln.strip().split(";")
            cw = "actif" if len(hf) > 7 and hf[7] == "1" else "arrêt"
            break
except Exception:
    pass
out = dict(accounts=accounts, alerts=alerts, biases=biases, savws=savws, crypto_weekend=cw,
           sav=dict(mode=None, signals=list(reversed(sig))[:15], results=results),
           days=list(reversed(days))[:10])
print(json.dumps(out, ensure_ascii=False))
