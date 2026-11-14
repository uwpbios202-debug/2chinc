#!/bin/sh
# Prints the four Housing Navigator documents in "Claude outputs" to PDF with headless Edge (local files only).
cd "$(dirname "$0")/../Claude outputs" || exit 1
EDGE="/c/Program Files (x86)/Microsoft/Edge/Application/msedge.exe"
for f in Navigator-1-Meeting-Packet-Rashada-Ford Navigator-2-Housing-Navigator-Agreement Navigator-3-Confidentiality-Agreement Navigator-4-Landlord-Participation-Agreement; do
  src="$(cygpath -w "$PWD/$f.html")"
  out="$(cygpath -w "$PWD/$f.pdf")"
  "$EDGE" --headless=new --disable-gpu --no-pdf-header-footer --print-to-pdf="$out" "file:///$src" >/dev/null 2>&1
  ls -l "$f.pdf" 2>/dev/null || echo "FAILED: $f"
done
