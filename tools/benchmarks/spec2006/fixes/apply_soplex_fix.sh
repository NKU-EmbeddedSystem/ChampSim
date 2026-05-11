#!/bin/bash
# Apply 450.soplex GCC 11+ build fix for SPEC CPU2006
# Usage: ./apply_soplex_fix.sh /path/to/cpu2006
set -e

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SPEC_ROOT="${1:?Usage: $0 /path/to/cpu2006}"

if [ ! -d "$SPEC_ROOT/benchspec/CPU2006/450.soplex" ]; then
    echo "Error: $SPEC_ROOT does not look like a SPEC CPU2006 root directory"
    exit 1
fi

PATCH_FILE="$SCRIPT_DIR/soplex-gcc12-fix.patch"
SRC_FILE="$SPEC_ROOT/benchspec/CPU2006/450.soplex/src/mpsinput.cc"

echo "==> Applying source patch..."
patch -d "$SPEC_ROOT" -p1 < "$PATCH_FILE"

echo "==> Updating MANIFEST MD5..."
OLD_MD5="196a9b257ce41b01f564dcbc76839458"
NEW_MD5=$(md5sum "$SRC_FILE" | awk '{print $1}')

MANIFEST_FILE="$SPEC_ROOT/MANIFEST"
if grep -q "$OLD_MD5" "$MANIFEST_FILE"; then
    sed -i "s/$OLD_MD5/$NEW_MD5/" "$MANIFEST_FILE"
    echo "    MANIFEST updated: $OLD_MD5 -> $NEW_MD5"
else
    echo "    MANIFEST already up to date (old MD5 not found, or already patched)"
fi

echo "==> Done. Rebuild with:"
echo "    cd $SPEC_ROOT && . ./shrc && runspec --action=build --config=linux64-amd64-gcc-fortify0.cfg --tune=base 450.soplex"
