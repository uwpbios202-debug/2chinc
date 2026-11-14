#!/bin/sh
# Read-only access matrix for the CHPMS directory (simulated sign-ins; nothing is written).
echo "== Navigator without an authenticator (aal1)"; ./.claude-tools/chpms-as.sh navigator aal1
echo "== Field staff without the authenticator step (aal1): must be refused"; ./.claude-tools/chpms-as.sh field aal1
echo "== Office staff without the authenticator step (aal1): must be refused"; ./.claude-tools/chpms-as.sh staff aal1
echo "== A tenant: must be refused"; ./.claude-tools/chpms-as.sh resident
echo "== An owner: must be refused"; ./.claude-tools/chpms-as.sh owner
echo "== Not signed in at all: must be refused"; ./.claude-tools/supa-query.sh "select chpms_directory()->>'role' r"
