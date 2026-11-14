#!/usr/bin/env python3
"""
Register (or update) a lease agent and store their signature image in the
PRIVATE lease-signing bucket (agents/<agent id>.png). The image is only ever
read by the lease-signing function when the agent countersigns after the
tenants have signed; it is never sent to a browser.

Usage (local Supabase by default):
    python tools/site/agent_signature.py --name "Albert Harris" --title President \
        --org "Royal Orleans Condominium – Addition 1 (ROCA1)" --email agent@example.com \
        --phone "(414) 555-0123" --signature path/to/signature.png

Against another project: set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY.
The signature should be a PNG with a white or transparent background.
"""
import argparse
import json
import os
import sys
import urllib.parse
import urllib.request

LOCAL_URL = "http://127.0.0.1:54321"
# The Supabase CLI's standard local service-role key (local development only).
LOCAL_SERVICE_KEY = ("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6InNlcnZpY2Vfcm9sZSIsImV4cCI6MTk4MzgxMjk5Nn0."
                     "EGIM96RAZx35lJzdJsyH-qQwv8Hdp7fsn3W0YpN81IU")


def call(method, url, key, body=None, ctype="application/json", extra=None):
    data = body if isinstance(body, (bytes, bytearray)) else (json.dumps(body).encode() if body is not None else None)
    headers = {"apikey": key, "Authorization": "Bearer " + key, "Content-Type": ctype, **(extra or {})}
    req = urllib.request.Request(url, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        sys.exit(f"{method} {url} failed: HTTP {e.code} {e.read().decode()[:300]}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--name", required=True)
    ap.add_argument("--title", default="")
    ap.add_argument("--org", default="")
    ap.add_argument("--email", required=True)
    ap.add_argument("--phone", required=True, help="mobile for the sign-in text code")
    ap.add_argument("--signature", required=True, help="PNG file")
    a = ap.parse_args()

    base = os.environ.get("SUPABASE_URL", LOCAL_URL).rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", LOCAL_SERVICE_KEY if base == LOCAL_URL else "")
    if not key:
        sys.exit("Set SUPABASE_SERVICE_ROLE_KEY for a non-local project.")
    png = open(a.signature, "rb").read()
    if png[:8] != b"\x89PNG\r\n\x1a\n":
        sys.exit("The signature must be a PNG file.")

    email = a.email.strip().lower()
    rows = call("GET", f"{base}/rest/v1/lease_agents?select=id&email=eq.{urllib.parse.quote(email)}", key)
    fields = {"name": a.name, "title": a.title or None, "org": a.org or None, "email": email, "phone_mobile": a.phone, "active": True}
    if rows:
        agent_id = rows[0]["id"]
        call("PATCH", f"{base}/rest/v1/lease_agents?id=eq.{agent_id}", key, fields)
    else:
        agent_id = call("POST", f"{base}/rest/v1/lease_agents", key, fields, extra={"Prefer": "return=representation"})[0]["id"]

    path = f"agents/{agent_id}.png"
    call("POST", f"{base}/storage/v1/object/lease-signing/{path}", key, png, ctype="image/png", extra={"x-upsert": "true"})
    call("PATCH", f"{base}/rest/v1/lease_agents?id=eq.{agent_id}", key, {"signature_path": path})
    print(f"Agent {a.name} <{email}> registered (id {agent_id}); signature stored privately at lease-signing/{path}.")


if __name__ == "__main__":
    main()
