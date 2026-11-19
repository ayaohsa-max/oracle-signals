"""Comparaison des sorties SAV-WS (robot v1.22) sur un backtest : python3 an122.py <dossier des oracle_backtest_*.csv>
Variantes mesurées par la simulation du robot, bougie par bougie (stop supposé touché en premier si la bougie est ambiguë) :
 0 = objectif plafonné à 3 R (v1.20) ; 1 = 50 % à 1,5 R puis stop à l'entrée ; 2 = suivi ATR ; 3 = suivi de structure.
Profil v1.20 : H1, tendance, zone HTF, >= 3 confluences, volatilité 0,8-2,0. Apprentissage 2018-2023, contrôle 2024-2026."""
import glob, sys
D = sys.argv[1] if len(sys.argv) > 1 else "."
NAMES = ["Objectif 3 R (v1.20)", "50 % à 1,5 R + stop à l'entrée", "Suivi ATR (2 ATR dès +1 R)", "Suivi de structure (5 bougies dès +1 R)"]
def num(x):
    try: return float(x)
    except Exception: return None
def st(rs):
    n = len(rs)
    if not n: return "n=0"
    g = sum(r for r in rs if r > 0); l = -sum(r for r in rs if r <= 0)
    eq = pk = dd = 0.0
    for r in rs: eq += r; pk = max(pk, eq); dd = max(dd, pk - eq)
    return f"n={n:4d} exp={sum(rs)/n:+.3f} PF={(g/l if l else 99):4.2f} DD={dd:5.1f} réussite={sum(1 for r in rs if r>0)/n:.0%}"
rows = []
for fn in sorted(glob.glob(D + "/oracle_backtest_*.csv")):
    L = [l.strip().split(";") for l in open(fn, encoding="utf-8", errors="ignore") if l.strip()]
    S = {(r[4], r[5], r[6]): r for r in L if r[0] == "SAVWS_SETUP" and len(r) >= 18}
    for r in L:
        if r[0] != "SAVWS_RESULT" or len(r) < 17 or r[4] != "H1": continue
        s = S.get((r[4], r[5], r[6]))
        if not s: continue
        nc = len([k for k in s[12].split("|")[-1].split("+") if k.strip()])
        vol = num(s[17])
        if s[14] != "TEND" or "ZoneHTF" not in s[12] or nc < 3 or vol is None or not (0.8 <= vol <= 2.0): continue
        v = [num(x) for x in r[13:17]]
        if None in v: continue
        rows.append((r[6], v))
print(f"{len(rows)} trades au profil v1.20 avec les 4 variantes")
for i, nm in enumerate(NAMES):
    a = [v[i] for t, v in rows if t < "2024.01.01"]; b = [v[i] for t, v in rows if t >= "2024.01.01"]
    print(f"{nm:42s} | 2018-2023 {st(a)} | 2024-2026 {st(b)}")
