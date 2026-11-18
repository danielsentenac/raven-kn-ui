"""Save the answers of `raven-kn serve` on the fixture store as files for the Dart tests,
and HEALPix reference values from healpy.

  python tool/capture_fixtures.py http://127.0.0.1:8765 TOKEN
"""
import base64
import json
import sys
import urllib.parse
import urllib.request
from pathlib import Path

import healpy as hp
import numpy as np

base, token = sys.argv[1], sys.argv[2]
out = Path(__file__).resolve().parents[1] / "test" / "fixtures"
out.mkdir(parents=True, exist_ok=True)


def get(path, raw=False):
    req = urllib.request.Request(base + path, headers={"Authorization": f"Bearer {token}"})
    with urllib.request.urlopen(req) as r:
        body = r.read()
    return body if raw else json.loads(body)


resp = {}
for p in ("/api/health", "/api/events?limit=2000&cursor=", "/api/optical", "/api/sky", "/api/followups"):
    resp[p] = get(p)
for c in resp["/api/optical"]["optical"]:
    p = "/api/optical/" + urllib.parse.quote(c["name"])
    resp[p] = get(p)
    for r in resp[p]["runs"]:
        q = f"/api/runs/{urllib.parse.quote(c['name'])}/{urllib.parse.quote(r['run'])}"
        resp[q] = get(q)
cur = resp["/api/events?limit=2000&cursor="]["cursor"]
resp[f"/api/events?limit=2000&cursor={urllib.parse.quote(cur)}"] = get(
    f"/api/events?limit=2000&cursor={urllib.parse.quote(cur)}")
blobs = {}
for se in resp["/api/sky"]["gw"]:
    for v in se["versions"]:
        for kind in v["maps"]:
            p = f"/api/gw/{se['superevent_id']}/map/{v['version']}/{kind}"
            blobs[p] = base64.b64encode(get(p, raw=True)).decode()
# the name of the machine that built the store stays out of the saved answers
import socket
text = json.dumps({"json": resp, "blobs": blobs}).replace(socket.gethostname(), "listener-host")
(out / "api.json").write_text(text)

rng = np.random.default_rng(0)
ra = np.concatenate([rng.uniform(0, 360, 400), [0, 0, 90, 180, 270, 359.999, 45, 45]])
dec = np.concatenate([np.degrees(np.arcsin(rng.uniform(-1, 1, 400))), [0, 90, -90, 41.8103, -41.8103, 0, 89.9, -89.9]])
ref = [{"order": o, "ra": float(a), "dec": float(d), "pix": int(hp.ang2pix(1 << o, a, d, nest=True, lonlat=True))}
       for o in (0, 3, 7) for a, d in zip(ra, dec)]
(out / "healpix.json").write_text(json.dumps(ref))
print(len(resp), "answers,", len(blobs), "maps,", len(ref), "HEALPix points")
