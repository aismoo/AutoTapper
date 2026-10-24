#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""下载 GitHub Actions artifact。

坑：artifacts/{id}/zip 会 302 到 Azure Blob 的预签名 URL，
如果跟着重定向还带着 Authorization 头，Azure 会直接 401
（"Server failed to authenticate the request"）。
所以必须用不转发 Authorization 的 redirect handler。
"""
import os
import sys
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TOKFILE = os.path.join(ROOT, ".local", "ghtok")
OWNER, REPO = "aismoo", "AutoTapper"


class StripAuthOnRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new is not None:
            new.headers = {k: v for k, v in new.headers.items()
                           if k.lower() != "authorization"}
        return new


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    artifact_id, name = sys.argv[1], sys.argv[2]
    tok = open(TOKFILE, encoding="utf-8").read().strip()
    outdir = os.path.join(ROOT, "dist")
    os.makedirs(outdir, exist_ok=True)
    dest = os.path.join(outdir, name + ".zip")

    url = f"https://api.github.com/repos/{OWNER}/{REPO}/actions/artifacts/{artifact_id}/zip"
    req = urllib.request.Request(url, headers={
        "Authorization": f"Bearer {tok}",
        "Accept": "application/vnd.github+json",
        "User-Agent": "dsh",
    })
    opener = urllib.request.build_opener(StripAuthOnRedirect)
    with opener.open(req, timeout=300) as r, open(dest, "wb") as f:
        f.write(r.read())
    print(f"{name}: {os.path.getsize(dest)} bytes -> {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
