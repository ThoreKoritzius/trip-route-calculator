# Engine comparison

Compares trip_routing with OSRM and Valhalla on random walking trips, with all
engines routing on the same OpenStreetMap snapshot where possible. The README's
"Compared with routing servers" section was produced with these scripts.

## Requirements

- `osrm-backend` (e.g. `brew install osrm-backend`)
- Python 3 with `osmium` (`pip install osmium`) for converting the extract
- Network access to the public Valhalla server (requests are paced at ~1/s)

## Steps

```bash
W=/tmp/engines && mkdir -p $W/osrm $W/data

# 1. One OSM snapshot for everyone (Cologne district, contains Aachen).
curl -L -o $W/data/region.osm.pbf \
  https://download.geofabrik.de/europe/germany/nordrhein-westfalen/koeln-regbez-latest.osm.pbf

# 2. trip_routing graph for Aachen from that snapshot, with the same filters as
#    the package's Overpass query.
python3 benchmark/engine_comparison/pbf_to_overpass_json.py \
  $W/data/region.osm.pbf $W/data/aachen_elements.json 50.648,5.953,50.862,6.233
dart run benchmark/engine_comparison/build_graph.dart \
  $W/data/aachen_elements.json $W/data/aachen.trg

# 3. Local OSRM (foot profile, contraction hierarchies) on the same snapshot.
cp $W/data/region.osm.pbf $W/osrm/region.osm.pbf
osrm-extract -p "$(brew --prefix osrm-backend)/share/osrm/profiles/foot.lua" $W/osrm/region.osm.pbf
osrm-contract $W/osrm/region.osrm
osrm-routed --algorithm ch --port 5055 $W/osrm/region.osrm > $W/osrm/routed.log 2>&1 &

# 4. Random trips routed by trip_routing, then OSRM and Valhalla.
dart run benchmark/engine_comparison/route_sample.dart $W/data/aachen.trg $W/trips_ours.json 400
python3 benchmark/engine_comparison/engines_stats.py $W
python3 benchmark/engine_comparison/analyze.py $W
```

Trips start and end on the walkable network inside Aachen's German core
(50.73–50.83 N, 6.02–6.15 E), stratified into 0.3–1, 1–2 and 2–5 km straight-line
distance. trip_routing times are in-process (median of 5 runs, warm). OSRM times
are the server-side times `osrm-routed` logs per request. Valhalla runs on the
public server, so it contributes route lengths only.
