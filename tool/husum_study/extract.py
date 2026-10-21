#!/usr/bin/env python3
"""Extract complete pedestrian candidate ways for the Husum feasibility study.

Requires pyosmium==4.3.2. No Overpass/API key. Input is a regional .osm.pbf.
The bbox is an experiment's coverage window, not an administrative city border.
"""
import argparse
import json
import resource
import time
from pathlib import Path

import osmium

# lon_min, lat_min, lon_max, lat_max; about 10 x 11 km, with city-edge margin.
BBOX = (8.98, 54.43, 9.14, 54.53)
EXCLUDED = {'motorway', 'motorway_link', 'construction', 'proposed',
            'raceway', 'bus_guideway', 'abandoned'}


def intersects(a, b, bbox=BBOX):
    """Liang–Barsky segment/rectangle test, also retaining crossing-only ways."""
    x0, y0, x1, y1 = *a, *b
    dx, dy = x1 - x0, y1 - y0
    lower, upper = 0.0, 1.0
    for p, q in ((-dx, x0-bbox[0]), (dx, bbox[2]-x0),
                 (-dy, y0-bbox[1]), (dy, bbox[3]-y0)):
        if p == 0:
            if q < 0:
                return False
        elif p < 0:
            lower = max(lower, q/p)
        else:
            upper = min(upper, q/p)
        if lower > upper:
            return False
    return True


def walkable(tags):
    # Match OsmClient.fetchWalkableWays and graph_builder.isWalkable.
    if not tags.get('highway') or tags['highway'] in EXCLUDED:
        return False
    if tags.get('area') == 'yes' or tags.get('place') == 'square':
        return False
    if tags.get('foot') in {'no', 'private'}:
        return False
    return tags.get('access') not in {'no', 'private'} or tags.get('foot') in {
        'yes', 'designated', 'permissive'}


class Extractor(osmium.SimpleHandler):
    def __init__(self):
        super().__init__()
        self.nodes = {}
        self.ways = []
        self.candidate_ways = 0
        self.invalid_locations = 0
        self.landmarks = []

    def way(self, way):
        tags = dict(way.tags)
        if not walkable(tags):
            return
        self.candidate_ways += 1
        try:
            coordinates = [(n.lon, n.lat) for n in way.nodes]
        except osmium.InvalidLocationError:
            self.invalid_locations += 1
            return
        if not any(intersects(a, b) for a, b in zip(coordinates, coordinates[1:])):
            return
        for n, (lon, lat) in zip(way.nodes, coordinates):
            self.nodes[n.ref] = {'type': 'node', 'id': n.ref, 'lat': lat, 'lon': lon}
        self.ways.append({'type': 'way', 'id': way.id,
                          'nodes': [n.ref for n in way.nodes], 'tags': tags})

    def node(self, node):
        tags = dict(node.tags)
        if (tags.get('name') and BBOX[0] <= node.location.lon <= BBOX[2]
                and BBOX[1] <= node.location.lat <= BBOX[3]
                and (tags.get('railway') == 'station' or tags.get('historic')
                     or tags.get('tourism') or tags.get('amenity') == 'place_of_worship')):
            self.landmarks.append({'name': tags['name'], 'lat': node.location.lat,
                                   'lon': node.location.lon, 'tags': tags})


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('source', type=Path)
    parser.add_argument('output', type=Path)
    parser.add_argument('--scan-landmarks', action='store_true',
                        help='Also call the Python node handler (slower baseline)')
    args = parser.parse_args()
    started = time.perf_counter()
    handler = Extractor()
    if args.scan_landmarks:
        handler.apply_file(str(args.source), locations=True, idx='flex_mem')
    else:
        # Populate the location index in C++ before filtering. Avoid a Python
        # callback for every regional node and every non-highway way.
        processor = osmium.FileProcessor(str(args.source)).with_locations()
        processor.with_filter(osmium.filter.EntityFilter(osmium.osm.WAY))
        processor.with_filter(osmium.filter.KeyFilter('highway'))
        for way in processor:
            handler.way(way)
    extracted = time.perf_counter()
    with args.output.open('w') as stream:
        json.dump({'elements': [*handler.nodes.values(), *handler.ways]}, stream,
                  separators=(',', ':'))
    metrics = {
        'scan_mode': 'python_nodes' if args.scan_landmarks else 'cpp_filters',
        'bbox_lon_lat': BBOX, 'source_bytes': args.source.stat().st_size,
        'candidate_ways_in_region': handler.candidate_ways,
        'retained_ways': len(handler.ways), 'retained_nodes': len(handler.nodes),
        'ways_with_missing_locations': handler.invalid_locations,
        'extract_seconds': extracted-started,
        'extract_and_json_seconds': time.perf_counter()-started,
        'peak_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        'json_bytes': args.output.stat().st_size,
    }
    args.output.with_suffix('.metrics.json').write_text(json.dumps(metrics, indent=2)+'\n')
    args.output.with_suffix('.landmarks.json').write_text(json.dumps(handler.landmarks, indent=2)+'\n')
    print(json.dumps(metrics, indent=2))


if __name__ == '__main__':
    main()
