#!/usr/bin/env python3
"""Etat du robot ORACLE pour la page ORACLE PRO (cle « robot » de live.html).
Lit les tickets GitHub n°1 (journal) et n°2 (signal de vie) du depot public.
Usage : python3 robot_status.py [biais.json] > robot.json
biais.json (optionnel) : liste [{"code","bias","date","why"}] lue dans le plan."""
import json, sys, urllib.request, datetime, collections

REPO = "ayaohsa-max/oracle-signals"

def comments(issue):
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
                      consignes=f[7], ideas=f[8], equity=f[9], ccy=f[10], created=c["created_at"])
accounts = []
by_login = collections.defaultdict(list)
for b in beats.values():
    t = datetime.datetime.fromisoformat(b["created"].replace("Z", "+00:00"))
    age = int((now - t).total_seconds() // 60)
    if age > 7 * 24 * 60:
        continue                       # compte inactif depuis plus d'une semaine : on ne l'affiche plus
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
for c in comments(1):
    f = c["body"].split(";")
    if f[0] == "SAV_SIGNAL" and len(f) >= 11:
        sig.append(dict(time=f[6], code=f[2], tf=f[4], side="Achat" if f[5] == "BUY" else "Vente",
                        entry=f[7], sl=f[8], tp=f[9], taken={"OBS": "observé", "PRIS": "pris", "NON_PRIS": "non pris"}.get(f[10], f[10])))
    elif f[0] == "SAV_RESULT" and len(f) >= 10:
        try:
            res.append(float(f[9]))
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
out = dict(accounts=accounts, alerts=alerts, biases=biases,
           sav=dict(mode=None, signals=list(reversed(sig))[:15], results=results),
           days=list(reversed(days))[:10])
print(json.dumps(out, ensure_ascii=False))
