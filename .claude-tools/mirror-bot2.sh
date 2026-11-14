#!/bin/sh
# Renders two BOTTOM rail halves at overall length 169.0 and 167.0 mm (mirror project, outside this repo) and builds their 3MFs.
set -e
OS="/c/Program Files/OpenSCAD (Nightly)/openscad.com"
cd /c/Users/mkepr/Documents/ROCA-mirror-key
"$OS" -q --export-format binstl -o stl/halfbot_169.0.stl -D 'part="halfbot"' -D 'mid_trim=2.81' mirror_key.scad
"$OS" -q --export-format binstl -o stl/halfbotsolid_169.0.stl -D 'part="halfbotsolid"' -D 'mid_trim=2.81' mirror_key.scad
"$OS" -q --export-format binstl -o stl/halfbot_167.0.stl -D 'part="halfbot"' -D 'mid_trim=4.81' mirror_key.scad
"$OS" -q --export-format binstl -o stl/halfbotsolid_167.0.stl -D 'part="halfbotsolid"' -D 'mid_trim=4.81' mirror_key.scad
node make-mount-3mf.mjs bot2
node /c/Users/mkepr/Documents/lease/.claude-tools/bbox3mf.mjs 169.0mm.3mf 167.0mm.3mf
