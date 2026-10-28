#!/usr/bin/env python3
"""Stands in for TMDB and Jellyfin in the self-test, never the real ones.

    standin.py PORT MEDIA LOG

TMDB is under /3 (and its pictures under /t/p), with the answers of its documented API for two shows
and a film; Jellyfin is under /jf, over the pretend server's MEDIA folder, which it shows as
/data/media the way the container does. A folder shows up in Jellyfin only after the app has said it is
new (Library/Media/Updated) or the whole library was refreshed, so the test sees the app tell it.
Every request is written to LOG, one JSON line each.
"""
import json
import os
import sys
import unicodedata
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs

PORT, MEDIA, LOG = int(sys.argv[1]), sys.argv[2], sys.argv[3]
HERE = os.path.dirname(os.path.abspath(__file__))
TMDB_KEY, TMDB_TOKEN, JF_KEY = "test-tmdb-key", "eyJ0ZXN0.token", "test-jf-key"
CONTAINER = "/data/media"
SHOWN = set()   # Jellyfin paths it has scanned

SHOWS = [{"id": 100, "name": "Test Show", "first_air_date": "2020-03-01", "poster_path": "/p100.jpg", "overview": ""},
         {"id": 101, "name": "Test Show Again", "first_air_date": "2023-01-10", "poster_path": None, "overview": ""}]
FILMS = [{"id": 194, "title": "Amélie", "release_date": "2001-04-25", "poster_path": "/p194.jpg", "overview": ""}]
EPISODES = ["Pilot", "Café: Two", "Three/Four", "Four", "Five", "Six"]


def fold(s):
    s = unicodedata.normalize("NFKD", s.lower())
    return "".join(c for c in s if c.isalnum())


def jf_path(host):
    return CONTAINER + host[len(MEDIA):]


def scanned(path):
    return any(path == p or path.startswith(p + "/") for p in SHOWN)


def walk(kind):
    """What Jellyfin would show: films, shows and episodes in the scanned folders."""
    out = []
    films, shows = os.path.join(MEDIA, "films"), os.path.join(MEDIA, "shows")
    if kind == "Movie":
        for d in sorted(os.listdir(films)) if os.path.isdir(films) else []:
            for f in sorted(os.listdir(os.path.join(films, d))):
                p = jf_path(os.path.join(films, d, f))
                if f.endswith(".mkv") and scanned(p):
                    out.append({"Id": "m-" + fold(d), "Name": d.rsplit(" (", 1)[0], "Path": unicodedata.normalize("NFC", p)})
    if kind == "Series":
        for d in sorted(os.listdir(shows)) if os.path.isdir(shows) else []:
            p = jf_path(os.path.join(shows, d))
            if scanned(p):
                out.append({"Id": "s-" + fold(d), "Name": d.rsplit(" (", 1)[0], "Path": unicodedata.normalize("NFC", p)})
    return out


class H(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def note(self, body=None):
        with open(LOG, "a") as f:
            f.write(json.dumps({"method": self.command, "path": self.path, "auth": self.headers.get("Authorization", ""), "body": body}) + "\n")

    def send(self, code, obj=None, raw=None, ctype="application/json"):
        data = raw if raw is not None else json.dumps(obj if obj is not None else {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        self.route(None)

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(n) if n else b""
        self.route(json.loads(raw) if raw else None)

    def route(self, body):
        self.note(body)
        u = urlparse(self.path)
        q = {k: v[0] for k, v in parse_qs(u.query).items()}
        parts = [p for p in u.path.split("/") if p]
        if parts[:2] == ["t", "p"]:
            return self.send(200, raw=open(os.path.join(HERE, "fixtures", "poster.jpg"), "rb").read(), ctype="image/jpeg")
        if parts[:1] == ["3"]:
            ok = q.get("api_key") == TMDB_KEY or self.headers.get("Authorization") == "Bearer " + TMDB_TOKEN
            if not ok:
                return self.send(401, {"status_code": 7, "status_message": "Invalid API key"})
            return self.tmdb(parts[1:], q)
        if parts[:1] == ["jf"]:
            if 'Token="%s"' % JF_KEY not in self.headers.get("Authorization", ""):
                return self.send(401)
            return self.jellyfin(parts[1:], q, body)
        self.send(404)

    def tmdb(self, p, q):
        if p == ["configuration"]:
            return self.send(200, {"images": {}})
        if p == ["search", "tv"]:
            return self.send(200, {"results": [s for s in SHOWS if fold(q.get("query", "")) in fold(s["name"])]})
        if p == ["search", "movie"]:
            return self.send(200, {"results": [f for f in FILMS if fold(q.get("query", "")) in fold(f["title"])]})
        if p == ["tv", "100"]:
            return self.send(200, {"id": 100, "name": "Test Show", "number_of_seasons": 2})
        if p == ["tv", "100", "season", "1"]:
            return self.send(200, {"episodes": [{"episode_number": i + 1, "name": n, "runtime": 1} for i, n in enumerate(EPISODES)]})
        if p == ["tv", "100", "external_ids"]:
            return self.send(200, {"imdb_id": "tt0000100", "tvdb_id": 9100})
        if p == ["movie", "194", "external_ids"]:
            return self.send(200, {"imdb_id": "tt0211915"})
        self.send(404, {"status_code": 34})

    def jellyfin(self, p, q, body):
        if p == ["System", "Info"]:
            return self.send(200, {"ServerName": "Stand-in", "Version": "12.4.0"})
        if p == ["Library", "VirtualFolders"]:
            return self.send(200, [{"Name": "Movies", "CollectionType": "movies", "Locations": [CONTAINER + "/films"], "ItemId": "lib-movies"},
                                   {"Name": "Shows", "CollectionType": "tvshows", "Locations": [CONTAINER + "/shows"], "ItemId": "lib-shows"},
                                   {"Name": "Music", "CollectionType": "music", "Locations": [CONTAINER + "/music"], "ItemId": "lib-music"}])
        if p == ["Library", "Media", "Updated"] and self.command == "POST":
            for u in (body or {}).get("Updates", []):
                SHOWN.add(unicodedata.normalize("NFC", u["Path"]))
            return self.send(204, raw=b"")
        if p == ["Library", "Refresh"] and self.command == "POST":
            SHOWN.add(CONTAINER)
            return self.send(204, raw=b"")
        if p == ["Items"]:
            want = fold(q.get("searchTerm", ""))
            items = [i for i in walk(q.get("includeItemTypes", "")) if want in fold(i["Name"])]
            return self.send(200, {"Items": items, "TotalRecordCount": len(items)})
        if len(p) == 3 and p[0] == "Shows" and p[2] == "Episodes":
            show = next((s for s in walk("Series") if s["Id"] == p[1]), None)
            if not show:
                return self.send(404)
            host = MEDIA + show["Path"][len(CONTAINER):]
            folder = os.path.join(host, "Season " + q.get("season", "1"))
            eps = [{"Id": "e-" + fold(f), "Name": f, "Path": unicodedata.normalize("NFC", show["Path"] + "/Season " + q.get("season", "1") + "/" + f)}
                   for f in sorted(os.listdir(folder)) if f.endswith(".mkv")] if os.path.isdir(folder) else []
            return self.send(200, {"Items": eps, "TotalRecordCount": len(eps)})
        self.send(404)


ThreadingHTTPServer(("127.0.0.1", PORT), H).serve_forever()
