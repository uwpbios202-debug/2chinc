#!/bin/sh
cd "C:/Users/mkepr/Documents/ROCA-mirror-key" || exit 1
OS="/c/Program Files/OpenSCAD (Nightly)/openscad.com"
COMMON="--export-format binstl -D base_t=54 -D screw_seat=6"
"$OS" -o stl/halftop_54.stl $COMMON -D 'part="halftop"' mirror_key.scad 2>&1 | grep -iE "warn|error|Split" 
"$OS" -o stl/halftopsolid_54.stl $COMMON -D 'part="halftopzones"' mirror_key.scad 2>&1 | grep -iE "warn|error"
"$OS" -o stl/halfbot_54.stl $COMMON -D mid_trim=3.81 -D 'part="halfbot"' mirror_key.scad 2>&1 | grep -iE "warn|error"
"$OS" -o stl/halfbotsolid_54.stl $COMMON -D mid_trim=3.81 -D 'part="halfbotzones"' mirror_key.scad 2>&1 | grep -iE "warn|error"
ls -l stl/*_54.stl
