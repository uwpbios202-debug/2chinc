#!/usr/bin/env python3
"""
Uploads the 3446 N 12th St land-contract documents (files/land-contract-3446-N-12th/)
to the private 'land-contract-docs' bucket and lists them for the buyers.

Needs the live project's URL and SERVICE ROLE key (never commit it):
    set SUPABASE_URL=https://<project>.supabase.co
    set SUPABASE_SERVICE_ROLE_KEY=...
    python tools/upload_land_contract_docs.py          (add --dry-run to just list)

Safe to re-run: files are replaced, rows are upserted by storage path.
Deliberately NOT included: the notice of delinquency, the court case search, the
2019 lease, and ALL the old interest statements (2022, 2023, 2024 and the 2026-02-17
one). They were worked out from the spreadsheet, not the way the contract says, and
disagree with the portal's interest table (see land_contract_interest() in
supabase/migrations/20261102010000_land_contract_buyer_view.sql). Add corrected ones here.
"""
import json, os, sys, urllib.request, urllib.parse

CONTRACT_ID = os.environ.get("LAND_CONTRACT_ID", "65c45d34-6fa4-5fb0-8beb-a76a2b45cb54")
FOLDER = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "files", "land-contract-3446-N-12th")
DOCS = [  # (file, kind, title, tax_year, dated)
    ("3446_Land_Contract.pdf", "contract", "Land contract (current copy)", None, "2025-11-30"),
    ("3446_Amortization_and_Budget.xlsx", "amortization", "Amortization schedule (spreadsheet)", None, "2025-11-30"),
    ("Property_Tax_Bill_2025.pdf", "tax_bill", "2025 City of Milwaukee property tax bill", 2025, "2026-01-09"),
]
MIME = {".pdf": "application/pdf", ".xlsx": "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"}


def call(method, url, key, body=None, headers=None):
    h = {"apikey": key, "Authorization": "Bearer " + key}
    h.update(headers or {})
    req = urllib.request.Request(url, data=body, method=method, headers=h)
    with urllib.request.urlopen(req) as r:
        return r.read()


def main():
    dry = "--dry-run" in sys.argv
    base = os.environ.get("SUPABASE_URL", "").rstrip("/")
    key = os.environ.get("SUPABASE_SERVICE_ROLE_KEY", "")
    if not dry and not (base and key):
        sys.exit("Set SUPABASE_URL and SUPABASE_SERVICE_ROLE_KEY first (or use --dry-run).")
    for fname, kind, title, year, dated in DOCS:
        path = os.path.join(FOLDER, fname)
        if not os.path.exists(path):
            sys.exit("Missing file: " + path)
        store = f"{CONTRACT_ID}/{fname}"
        print(("would upload " if dry else "uploading ") + store)
        if dry:
            continue
        with open(path, "rb") as f:
            data = f.read()
        call("POST", f"{base}/storage/v1/object/land-contract-docs/{urllib.parse.quote(store)}", key, data,
             {"Content-Type": MIME[os.path.splitext(fname)[1]], "x-upsert": "true"})
        row = {"contract_id": CONTRACT_ID, "kind": kind, "title": title, "tax_year": year, "dated": dated, "storage_path": store}
        call("POST", f"{base}/rest/v1/land_contract_documents?on_conflict=storage_path", key, json.dumps(row).encode(),
             {"Content-Type": "application/json", "Prefer": "resolution=merge-duplicates"})
    print("Done." if not dry else "Dry run only.")


if __name__ == "__main__":
    main()
