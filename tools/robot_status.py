#!/usr/bin/env python3
"""Etat du robot ORACLE pour la page ORACLE PRO (cle « robot » de live.html).
Lit les tickets GitHub n°1 (journal) et n°2 (signal de vie) du depot public.
Usage : python3 robot_status.py [biais.json] > robot.json
biais.json (optionnel) : liste [{"code","bias","date","why"}] lue dans le plan."""
import json, os, sys, urllib.request, datetime, collections

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
                      positions=(f[11] if len(f) > 11 else ""), pending=(f[12] if len(f) > 12 else ""),
                      settings=(dict(kv.split("=", 1) for kv in f[13].split(",") if "=" in kv) if len(f) > 13 else {}))
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
        alerts.append(f"Compte •••{a['login'][-3:]} ({a['type']}) : {a['state']}")
    elif a["flag"] == "silence":
        alerts.append(f"Compte •••{a['login'][-3:]} : aucun signal de vie depuis {a['age_min']} min (PC, réseau ou MT5 coupé ?)")
# deux robots sur le meme compte : plus de signaux de vie que prevu sur les 3 dernieres heures (1 par heure attendu)
# v1.19 : une réinstallation envoie plusieurs signaux en quelques minutes ; on n'alerte que si au moins
# deux heures différentes (sur les 3 dernières) comptent chacune 2 signaux ou plus
cnt = collections.Counter()
for c in comments(2)[-300:]:
    f = c["body"].split(";")
    if f[0] == "HEARTBEAT" and len(f) > 6:
        t = datetime.datetime.fromisoformat(c["created_at"].replace("Z", "+00:00"))
        if (now - t).total_seconds() < 3 * 3600:
            cnt[(f[1], t.strftime("%d%H"))] += 1
dbl = collections.Counter(login for (login, h), k in cnt.items() if k >= 2)
for login, k in dbl.items():
    if k >= 2:
        alerts.append(f"Compte •••{login[-3:]} : deux robots semblent tourner sur le même compte (à retirer d'un des deux MetaTrader)")
# v1.19 : contrôle des réglages clés envoyés par le robot (profil validé le 17/11)
EXPECT = dict(idees="6", swUnites="H1", swConfReel="3", swZone="oui", swTendance="oui")
for a in accounts:
    s_ = a.get("settings") or {}
    if not s_:
        continue
    bad = [f"{k} = {s_.get(k, '?')} (attendu {v})" for k, v in EXPECT.items() if s_.get(k) != v]
    # objectif d origine du setup (plafond 0, choix du trader le 19/11) et filtre de volatilité 0,8-2,0 (contrôlés seulement s'ils sont transmis)
    bad += [f"{k} = {s_[k]} (attendu {v})" for k, v in dict(swObjMax="0.0", swVol="0.8-2.0").items() if k in s_ and s_[k] != v]
    try:
        if float(s_.get("risqueTotal", "0")) > 2.1 or float(s_.get("perteJour", "0")) > 2.5:
            bad.append(f"risque total {s_.get('risqueTotal')} % / perte du jour {s_.get('perteJour')} % (max 2,1 / 2,5)")
    except ValueError:
        pass
    a["settings_ok"] = not bad
    if bad:
        alerts.append("Réglages du robot à corriger : " + " ; ".join(bad))
accounts.sort(key=lambda x: x["age_min"])
for a in accounts:
    a.pop("created", None)
    a["login"] = "•••" + a["login"][-3:]   # numéro de compte masqué (page publique)

# --- journal
sig, res, days = [], [], []
ws_setups, ws_res, ws_real = [], [], []
ws_real_d = []
plan_tr, plan_open = {}, {}
events = []                            # v1.21 : historique prises / sorties / annulations pour la page
seen_bodies = set()
for c in comments(1):
    if c["body"] in seen_bodies:
        continue                       # ligne en double dans le journal
    seen_bodies.add(c["body"])
    f = c["body"].split(";")
    try:
        if f[0] == "ORACLE_OPEN" and len(f) >= 10:
            events.append(dict(kind="prise", id=f[2], leg=f[3], sym=f[4], side=f[5], time=f[6], price=f[7], sl=f[8], tp=f[9]))
        elif f[0] == "ORACLE_TRADE" and len(f) >= 16:
            w = f[11].replace("clôture", "cloture")
            r = float(f[15])
            if w == "stop" and abs(r) < 0.15:
                w = "stop_entree"
            elif w == "stop" and r > 0:
                w = "stop_gain"
            events.append(dict(kind="sortie", id=f[2], leg=f[3], sym=f[4], side=f[5], time=f[9], price=f[10],
                               why=w, pnl=float(f[13]), ccy=f[14], r=r))
        elif f[0] == "ORACLE_CANCEL" and len(f) >= 6:
            events.append(dict(kind="annule", id=f[2], sym=f[3], why=f[4], time=f[5].replace("T", " ")))
    except ValueError:
        pass
    if f[0] == "SAVWS_SETUP" and len(f) >= 14:
        ws_setups.append(dict(code=f[2], tf=f[4], side="Achat" if f[5] == "BUY" else "Vente", time=f[6],
                              entry=f[7], sl=f[8], tp=f[9], rr=f[10], conf=f[12], mode=f[13]))
    elif f[0] == "SAVWS_RESULT" and len(f) >= 9:
        try:
            ws_res.append(dict(code=f[2], tf=f[4], why=f[7], r=float(f[8]), sym=f[3], time=f[6]))
        except ValueError:
            pass
    if f[0] == "ORACLE_TRADE" and len(f) >= 16 and f[2].startswith("T"):
        try:
            plan_tr.setdefault(f[2], []).append(dict(r=float(f[15]), why=f[11], sym=f[4], time=f[9]))
        except ValueError:
            pass
    elif f[0] == "ORACLE_OPEN" and len(f) >= 7 and f[2].startswith("T"):
        plan_open.setdefault(f[2], f[6])
    elif f[0] == "ORACLE_TRADE" and len(f) >= 16 and f[2].startswith("W"):
        try:
            ws_real.append(float(f[15]))
            ws_real_d.append(dict(sym=f[4], time=f[6], r=float(f[15])))
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
        days.append(dict(login="•••" + f[1][-3:], date=f"{d[6:8]}/{d[4:6]}/{d[0:4]}", balance=f[3], equity=f[4], peak=f[5], pnl=f[6], ccy=f[7]))
n = len(res)
results = dict(n=n, win=(f"{100*sum(1 for r in res if r > 0)/n:.0f} %" if n else None),
               exp=(round(sum(res) / n, 2) if n else None))
biases = []
if len(sys.argv) > 1:
    try:
        biases = json.load(open(sys.argv[1], encoding="utf-8"))
    except Exception:
        pass
if not biases:   # sinon : biais publiés dans les consignes du robot (oracle_signals.csv)
    try:
        _root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        _hd = ""
        for _l in open(os.path.join(_root, "oracle_signals.csv"), encoding="utf-8"):
            _f = _l.strip().split(";")
            if _f[0] == "HEADER" and len(_f) > 1:
                _hd = _f[1][8:10] + "/" + _f[1][5:7]
            elif _f[0] == "BIAS" and len(_f) >= 3:
                biases.append(dict(code=_f[1], bias=int(_f[2]), date=_hd, why="consignes du robot"))
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
# crypto semaine / week-end (v1.15) : heure du journal = heure du serveur FTMO (UTC+2/+3) ;
# le week-end Paris (vendredi 23h → dimanche 23h) correspond au samedi et au dimanche du serveur.
CRYPTO = ("BTC", "ETH", "SOL", "XRP", "LTC", "ADA", "DOGE", "BNB")
def _is_crypto(x):
    u = (x or "").upper()
    return any(k in u for k in CRYPTO)
def _is_wk(t):
    try:
        return datetime.datetime.strptime(t[:16], "%Y.%m.%d %H:%M").weekday() >= 5
    except Exception:
        return False
cw_sim = [x for x in ws_res if _is_crypto(x["code"]) or _is_crypto(x.get("sym"))]
cw_real = [x for x in ws_real_d if _is_crypto(x["sym"])]
crypto_wk = dict(
    weekend=dict(sim=_stats([x["r"] for x in cw_sim if _is_wk(x["time"])]), real=_stats([x["r"] for x in cw_real if _is_wk(x["time"])])),
    semaine=dict(sim=_stats([x["r"] for x in cw_sim if not _is_wk(x["time"])]), real=_stats([x["r"] for x in cw_real if not _is_wk(x["time"])])),
    rule="20 résultats, ≥ 0,2 R, PF ≥ 1,3, risque divisé par 2")
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

# --- idées du plan (T) : émises (historique git des consignes), déclenchées, résultats réels
def _plan_issued():
    import subprocess, os
    seen = {}
    try:
        root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
        log = subprocess.run(["git", "-C", root, "log", "--reverse", "--format=@@%cI", "-p", "--", "oracle_signals.csv"],
                             capture_output=True, text=True, timeout=60).stdout
        when = ""
        for ln in log.splitlines():
            if ln.startswith("@@") and not ln.startswith("@@ "):
                when = ln[2:18].replace("T", " ")
            elif ln.startswith("+ORDER;"):
                f = ln[1:].split(";")
                if len(f) >= 8 and f[1] not in seen:
                    seen[f[1]] = dict(id=f[1], sym=f[2], side=f[3], type=f[4], entry=f[5], sl=f[6], tp=f[7], issued=when)
    except Exception:
        pass
    return seen
_iss = _plan_issued()
plan_ideas = []
for k in set(_iss) | set(plan_tr) | set(plan_open):
    x = dict(_iss.get(k, dict(id=k)))
    tr = plan_tr.get(k, [])
    if tr:
        x["status"] = "clôturée"; x["r"] = round(sum(t["r"] for t in tr) / len(tr), 2)
    elif k in plan_open:
        x["status"] = "en cours"
    else:
        x["status"] = "non déclenchée"
    x["opened"] = plan_open.get(k)
    plan_ideas.append(x)
plan_ideas.sort(key=lambda x: x.get("issued") or x.get("opened") or "", reverse=True)
_pr = [x["r"] for x in plan_ideas if "r" in x]
plan = dict(issued=len(_iss), triggered=sum(1 for x in plan_ideas if x["status"] != "non déclenchée"),
            real=_stats(_pr), ideas=plan_ideas[:25])
events.sort(key=lambda e: e.get("time") or "", reverse=True)
out = dict(events=events[:40], plan=plan, accounts=accounts, alerts=alerts, biases=biases, savws=savws, crypto_weekend=cw, crypto_wk=crypto_wk,
           sav=dict(mode=None, signals=list(reversed(sig))[:15], results=results),
           days=list(reversed(days))[:10])
print(json.dumps(out, ensure_ascii=False))
