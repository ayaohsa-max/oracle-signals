"""Analyse du backtest v1.19 (8 ans, H1) : choix du filtre de régime, de la validité et de la sortie.
Usage : python3 an119.py <dossier des oracle_backtest_*.csv> [json_sortie]
Sélection sur 2018-2023 (apprentissage), validation sur 2024-2026 (contrôle).
Règles de base v1.17 : dans la tendance + zone HTF + >= 3 confluences, sans or.
"""
import glob, sys, json, itertools, collections

D = sys.argv[1] if len(sys.argv) > 1 else "."
OUT = sys.argv[2] if len(sys.argv) > 2 else None
SPLIT = "2024.01.01"


def num(x):
    try:
        return float(x)
    except (TypeError, ValueError):
        return None


def nconf(c):
    c = (c or "").split("|")[-1]
    return len([k for k in c.split("+") if k.strip()])


def st(rs):
    n = len(rs)
    if not n:
        return dict(n=0, e=0.0, pf=0.0, dd=0.0, w=0.0, t=0.0)
    g = sum(r for r in rs if r > 0); l = -sum(r for r in rs if r <= 0)
    eq = pk = dd = 0.0
    for r in rs:
        eq += r; pk = max(pk, eq); dd = max(dd, pk - eq)
    return dict(n=n, e=round(sum(rs) / n, 3), pf=round(g / l, 2) if l else 99.0, dd=round(dd, 1),
                w=round(sum(1 for r in rs if r > 0) / n, 3), t=round(sum(rs), 1))


rows = []
for fn in sorted(glob.glob(D + "/oracle_backtest_*.csv")):
    sym = fn.split("oracle_backtest_")[1][:-4]
    L = [l.strip().split(";") for l in open(fn, encoding="utf-8", errors="ignore") if l.strip()]
    S = {(r[4], r[5], r[6]): r for r in L if r[0] == "SAVWS_SETUP" and len(r) >= 15}
    for r in L:
        if r[0] != "SAVWS_RESULT" or len(r) < 9:
            continue
        s = S.get((r[4], r[5], r[6]))
        if not s:
            continue
        x = dict(sym=sym, tf=r[4], t=r[6], r=num(r[8]) or 0.0, why=r[7],
                 delay=num(r[11]) if len(r) > 11 else None, mfe=num(r[12]) if len(r) > 12 else None,
                 conf=s[12], nc=nconf(s[12]), zone="ZoneHTF" in s[12], tend=s[14] if len(s) > 14 else "-",
                 adx=num(s[15]) if len(s) > 15 else None, dist=num(s[16]) if len(s) > 16 else None,
                 vol=num(s[17]) if len(s) > 17 else None)
        rows.append(x)

base = [x for x in rows if x["tf"] == "H1" and not x["sym"].startswith("XAU") and x["tend"] == "TEND"
        and x["zone"] and x["nc"] >= 3]
print(f"Résultats lus : {len(rows)} ; base v1.17 (H1, tendance, zone, >=3 conf., sans or) : {len(base)}")
print(f"  avec régime renseigné : {sum(1 for x in base if x['adx'] is not None)} ; avec MFE : {sum(1 for x in base if x['mfe'] is not None)} ; avec délai : {sum(1 for x in base if x['delay'] is not None)}")


def exitR(x, k):
    """Sortie fixe à k R reconstruite avec le gain maximal (MFE) ; None = sortie d'origine."""
    if k is None or x["mfe"] is None:
        return x["r"]
    if x["mfe"] >= k:
        return float(k)
    return -1.0 if x["why"] == "stop" else min(x["r"], x["mfe"])


ADX = [None, 15, 20, 25, 30]                 # ADX D1 minimal
DIST = [None, (0, 3), (0.5, 4), (0, 2)]      # distance à la MM200 (en ATR), bornes min-max
VOL = [None, (0.7, 1.5), (0.8, 2.0), (0, 1.2)]  # ATR14 / ATR100
VAL = [12, 24, 48, 100]                      # délai d'entrée maximal (bougies)
EXIT = [None, 1.5, 2.0, 3.0]


def keep(x, a, d, v, val):
    if a is not None and (x["adx"] is None or x["adx"] < a): return False
    if d is not None and (x["dist"] is None or not (d[0] <= abs(x["dist"]) <= d[1])): return False
    if v is not None and (x["vol"] is None or not (v[0] <= x["vol"] <= v[1])): return False
    if val < 100 and (x["delay"] is None or x["delay"] > val): return False
    return True


tr = [x for x in base if x["t"] < SPLIT]; te = [x for x in base if x["t"] >= SPLIT]
res = []
for a, d, v, val, k in itertools.product(ADX, DIST, VOL, VAL, EXIT):
    A = [exitR(x, k) for x in tr if keep(x, a, d, v, val)]
    B = [exitR(x, k) for x in te if keep(x, a, d, v, val)]
    sa, sb = st(A), st(B)
    if sa["n"] < 150:          # assez de trades pour juger (≈ 25 par an)
        continue
    yrs = collections.defaultdict(list)
    for x in tr + te:
        if keep(x, a, d, v, val):
            yrs[x["t"][:4]].append(exitR(x, k))
    pos = sum(1 for y in yrs.values() if sum(y) > 0)
    res.append(dict(adx=a, dist=d, vol=v, val=val, exit=k, train=sa, test=sb, years_pos=pos, years=len(yrs)))

# classement sur l'apprentissage seulement (espérance × racine(n), pour ne pas favoriser les tout petits échantillons)
res.sort(key=lambda r: r["train"]["e"] * (r["train"]["n"] ** 0.5), reverse=True)
ref = next((r for r in res if r["adx"] is None and r["dist"] is None and r["vol"] is None and r["val"] == 100 and r["exit"] is None), None)
fmt = lambda s: f"n={s['n']:4d} exp={s['e']:+.2f} PF={s['pf']:4.2f} DD={s['dd']:5.1f}"
if ref:
    print("Référence v1.17 :", "appr.", fmt(ref["train"]), "| contrôle", fmt(ref["test"]), f"| années + {ref['years_pos']}/{ref['years']}")
print("\nTop 15 (classés sur 2018-2023, vérifiés sur 2024-2026) :")
for r in res[:15]:
    ok = r["test"]["n"] >= 40 and r["test"]["e"] > 0 and r["test"]["pf"] >= 1.1
    print(f"{'✓' if ok else '✗'} ADX≥{r['adx']} dist={r['dist']} vol={r['vol']} validité={r['val']} sortie={r['exit']} | appr. {fmt(r['train'])} | contrôle {fmt(r['test'])} | années + {r['years_pos']}/{r['years']}")
best = next((r for r in res if r["test"]["n"] >= 40 and r["test"]["e"] > 0 and r["test"]["pf"] >= 1.1), None)
print("\nVERDICT :", ("réglage retenu → " + json.dumps({k: best[k] for k in ('adx', 'dist', 'vol', 'val', 'exit')})) if best else
      "aucun réglage ne tient sur la période de contrôle : garder v1.17 tel quel, pas de filtre ajouté.")
if OUT:
    json.dump(dict(n_base=len(base), ref=ref, top=res[:15], best=best), open(OUT, "w"), ensure_ascii=False, indent=1)
