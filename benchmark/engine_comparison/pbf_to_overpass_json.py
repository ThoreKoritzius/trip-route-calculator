"""Writes the ways our Overpass query would return for a bbox, from a .pbf."""
import json, re, sys
import osmium

pbf, out = sys.argv[1], sys.argv[2]
min_lat, min_lon, max_lat, max_lon = map(float, sys.argv[3].split(','))
EXCLUDED = re.compile(r'^(motorway|motorway_link|construction|proposed|raceway|bus_guideway|abandoned)$')
FOOT_NO = re.compile(r'^(no|private)$')

def wanted(tags):
    hw = tags.get('highway')
    if hw is None or EXCLUDED.search(hw):
        return False
    if re.search('yes', tags.get('area', '')) or re.search('square', tags.get('place', '')):
        return False
    return not FOOT_NO.search(tags.get('foot', ''))

class Handler(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.nodes, self.ways = {}, []
    def way(self, w):
        tags = {t.k: t.v for t in w.tags}
        if not wanted(tags):
            return
        locs = [(n.ref, n.location) for n in w.nodes if n.location.valid()]
        if not any(min_lat <= l.lat <= max_lat and min_lon <= l.lon <= max_lon for _, l in locs):
            return
        for ref, l in locs:
            self.nodes[ref] = (l.lat, l.lon)
        self.ways.append({'type': 'way', 'id': w.id, 'nodes': [r for r, _ in locs], 'tags': tags})

h = Handler()
h.apply_file(pbf, locations=True)
elements = [{'type': 'node', 'id': i, 'lat': la, 'lon': lo} for i, (la, lo) in h.nodes.items()] + h.ways
json.dump({'elements': elements}, open(out, 'w'))
print(f'{len(h.ways)} ways, {len(h.nodes)} nodes')
