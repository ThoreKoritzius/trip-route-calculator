import json, math, random, statistics as st, sys
W = sys.argv[1]
trips = [t for t in json.load(open(f'{W}/trips_all.json')) if 'error' not in t['valhalla']]
R = 6371e3

def q(xs, p):
    xs = sorted(xs); k = (len(xs) - 1) * p; f = math.floor(k); c = min(f + 1, len(xs) - 1)
    return xs[f] + (xs[c] - xs[f]) * (k - f)

def boot_median_ci(xs, n=2000, seed=1):
    rnd = random.Random(seed)
    meds = sorted(st.median(rnd.choices(xs, k=len(xs))) for _ in range(n))
    return meds[int(0.025 * n)], meds[int(0.975 * n)]

def xy(p, lat0): return (math.radians(p[1]) * R * math.cos(math.radians(lat0)), math.radians(p[0]) * R)
def sd(p, a, b):
    dx, dy = b[0]-a[0], b[1]-a[1]; L = dx*dx+dy*dy
    t = 0 if L == 0 else max(0, min(1, ((p[0]-a[0])*dx + (p[1]-a[1])*dy)/L))
    return math.hypot(p[0]-a[0]-t*dx, p[1]-a[1]-t*dy)
def overlap(route, ref, tol=20.0, step=10.0):
    lat0 = route[0][0]; r = [xy(p, lat0) for p in route]; f = [xy(p, lat0) for p in ref]
    # Grid-bucket the reference segments for speed.
    cell = 50.0; grid = {}
    for u, v in zip(f, f[1:]):
        for gx in range(int(min(u[0], v[0]) // cell) - 1, int(max(u[0], v[0]) // cell) + 2):
            for gy in range(int(min(u[1], v[1]) // cell) - 1, int(max(u[1], v[1]) // cell) + 2):
                grid.setdefault((gx, gy), []).append((u, v))
    inside = total = 0.0
    for a, b in zip(r, r[1:]):
        L = math.dist(a, b); n = max(1, int(L / step))
        for k in range(n):
            t = (k + 0.5) / n; p = (a[0] + t*(b[0]-a[0]), a[1] + t*(b[1]-a[1]))
            cands = grid.get((int(p[0] // cell), int(p[1] // cell)), [])
            total += L / n
            if cands and min(sd(p, u, v) for u, v in cands) <= tol: inside += L / n
    return inside / total if total else 1.0

def ratio_stats(name, a, b):
    rs = [t[a]['distance'] / t[b]['distance'] for t in trips if t[b]['distance'] > 0]
    lo, hi = boot_median_ci(rs)
    within5 = sum(abs(r - 1) <= 0.05 for r in rs) / len(rs)
    within10 = sum(abs(r - 1) <= 0.10 for r in rs) / len(rs)
    print(f'{name:28} median {st.median(rs):.3f} (95% CI {lo:.3f}–{hi:.3f}), IQR {q(rs,.25):.3f}–{q(rs,.75):.3f}, within ±5%: {within5:.0%}, ±10%: {within10:.0%}, shorter: {sum(r < 0.999 for r in rs)/len(rs):.0%}')
    return rs

print(f'n = {len(trips)} trips (valhalla failures dropped: {400 - len(trips)})')
ratio_stats('trip_routing / OSRM', 'ours', 'osrm')
ratio_stats('trip_routing / Valhalla', 'ours', 'valhalla')
ratio_stats('OSRM / Valhalla (reference)', 'osrm', 'valhalla')
rs = ratio_stats('shortest-path mode / OSRM', 'ours_shortest', 'osrm')
print(f'  shortest-path mode longer than OSRM by >1%: {sum(r > 1.01 for r in rs)} trips')

for a, b in [('ours', 'osrm'), ('ours', 'valhalla'), ('osrm', 'valhalla')]:
    ov = [overlap(t[a]['coords'], t[b]['coords']) for t in trips]
    print(f'same path {a}~{b}: median {st.median(ov):.0%}, IQR {q(ov,.25):.0%}–{q(ov,.75):.0%}')

print('compute time per route (ms): median / p95')
for lo, hi, label in [(300, 1000, '0.3–1 km'), (1000, 2000, '1–2 km'), (2000, 5000, '2–5 km'), (0, 1e9, 'all')]:
    sel = [t for t in trips if lo <= t['crow'] < hi]
    o = [t['ours']['ms'] for t in sel]; s = [t['osrm']['ms'] for t in sel]
    print(f'  {label:9} n={len(sel):3}  trip_routing {st.median(o):6.2f} / {q(o,.95):6.2f}   OSRM (CH, server-side) {st.median(s):5.2f} / {q(s,.95):5.2f}   OSRM local HTTP {st.median([t["osrm"]["http_ms"] for t in sel]):5.2f}   Valhalla public HTTP {st.median([t["valhalla"]["http_ms"] for t in sel]):6.1f}')
