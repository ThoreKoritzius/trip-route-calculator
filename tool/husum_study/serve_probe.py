#!/usr/bin/env python3
"""Loopback static-transfer smoke only; not a VPS/WAN load test."""
import concurrent.futures
import functools
import hashlib
import http.server
import json
import pathlib
import resource
import sys
import threading
import time
import urllib.request

path = pathlib.Path(sys.argv[1]).resolve()
expected = hashlib.sha256(path.read_bytes()).hexdigest()


class Handler(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(('127.0.0.1', 0),
    functools.partial(Handler, directory=str(path.parent)))
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
url = f'http://127.0.0.1:{server.server_port}/{path.name}'


def fetch(_):
    started = time.perf_counter()
    with urllib.request.urlopen(url, timeout=10) as response:
        body = response.read()
        assert int(response.headers['Content-Length']) == len(body)
    assert hashlib.sha256(body).hexdigest() == expected
    return (time.perf_counter()-started)*1000


try:
    started = time.perf_counter()
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        elapsed = sorted(pool.map(fetch, range(20)))
    metrics = {'transfers': len(elapsed), 'concurrency': 4,
        'file_bytes': path.stat().st_size, 'sha256': expected,
        'total_seconds': time.perf_counter()-started,
        'transfer_median_ms': elapsed[len(elapsed)//2],
        'transfer_max_ms': max(elapsed),
        'peak_rss_kib': resource.getrusage(resource.RUSAGE_SELF).ru_maxrss,
        'all_content_checks_passed': True, 'transport': 'loopback HTTP only'}
    print(json.dumps(metrics, indent=2))
finally:
    server.shutdown()
    server.server_close()
