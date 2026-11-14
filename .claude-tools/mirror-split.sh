#!/bin/sh
# Renders the split rail pair + extensions and builds the 3MF files (mirror project, outside this repo).
set -e
OS="/c/Program Files/OpenSCAD (Nightly)/openscad.com"
cd /c/Users/mkepr/Documents/ROCA-mirror-key
for p in halftop halfbot halftopsolid halfbotsolid ext extmax; do
  "$OS" -q --export-format binstl -o "stl/$p.stl" -D "part=\"$p\"" mirror_key.scad
done
"$OS" -o split_view.png --imgsize=1400,900 --camera=0,0,0,40,0,20,700 --viewall --autocenter -D 'part="splitview"' mirror_key.scad 2>&1 | grep -E "ECHO|ERROR|WARN" || true
"$OS" -o split_joint.png --imgsize=1000,800 --camera=0,0,0,0,0,0,140 -D 'part="splitview"' mirror_key.scad 2>/dev/null || true
node make-mount-3mf.mjs split
