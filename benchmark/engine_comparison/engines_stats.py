"""Routes the sampled trips with local OSRM (timed from its log) and public Valhalla."""
import json, re, sys, time, urllib.request
W = sys.argv[1]
UA = 'trip_routing-benchmark (+https://github.com/ThoreKoritzius/trip-route-calculator)'
trips = json.load(open(f'{W}/trips_ours.json'))

def get(url, body=None, timeout=30):
    req = urllib.request.Request(url, data=body, headers={'User-Agent': UA, 'Content-Type': 'application/json'})
    t = time.perf_counter()
    with urllib.request.urlopen(req, timeout=timeout) as r:
        d = json.load(r)
    return d, (time.perf_counter() - t) * 1000

def decode6(s):
    coords, i, lat, lon = [], 0, 0, 0
    while i < len(s):
        for which in (0, 1):
            shift = res = 0
            while True:
                b = ord(s[i]) - 63; i += 1
                res |= (b & 0x1f) << shift; shift += 5
                if b < 0x20: break
            v = ~(res >> 1) if res & 1 else res >> 1
            if which == 0: lat += v
            else: lon += v
        coords.append([lat / 1e6, lon / 1e6])
    return coords

# --- local OSRM (server-side time from osrm-routed's log) ---
log = f'{W}/osrm/routed.log'
before = len(open(log).read().splitlines())
for t in trips:
    (sl, so), (el, eo) = t['start'], t['end']
    d, ms = get(f'http://127.0.0.1:5055/route/v1/foot/{so},{sl};{eo},{el}?overview=full&geometries=geojson')
    r = d['routes'][0]
    t['osrm'] = {'distance': r['distance'], 'http_ms': ms, 'coords': [[c[1], c[0]] for c in r['geometry']['coordinates']]}
time.sleep(0.5)
server_ms = [float(m) for m in re.findall(r' ([\d.]+)ms 127\.0\.0\.1 ', '\n'.join(open(log).read().splitlines()[before:]))]
assert len(server_ms) == len(trips), (len(server_ms), len(trips))
for t, ms in zip(trips, server_ms): t['osrm']['ms'] = ms
print('osrm done', flush=True)

# --- public Valhalla, ~1 request/s ---
for n, t in enumerate(trips):
    (sl, so), (el, eo) = t['start'], t['end']
    body = json.dumps({'locations': [{'lat': sl, 'lon': so}, {'lat': el, 'lon': eo}], 'costing': 'pedestrian'}).encode()
    for attempt in range(3):
        try:
            d, ms = get('https://valhalla1.openstreetmap.de/route', body)
            t['valhalla'] = {'distance': d['trip']['summary']['length'] * 1000, 'http_ms': ms,
                             'coords': [c for leg in d['trip']['legs'] for c in decode6(leg['shape'])]}
            break
        except Exception as e:
            t['valhalla'] = {'error': str(e)}
            time.sleep(5)
    if n % 50 == 0: print('valhalla', n, flush=True)
    time.sleep(1.0)
json.dump(trips, open(f'{W}/trips_all.json', 'w'))
print('done', sum('error' in t['valhalla'] for t in trips), 'valhalla errors')
