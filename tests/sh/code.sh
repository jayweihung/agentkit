#!/usr/bin/env bash
. "$(dirname "$0")/../lib.sh"
# what this section needs that the old one-file run.sh had done before it
cd "$T"
# ---------- code checks ----------
check "no \$var directly before non-ASCII (bash 3.2 reads it as part of the name)" '! LC_ALL=C grep -nE "\\\$[A-Za-z_][A-Za-z0-9_]*[^ -~]" "$KIT" "$HERE/../unix/install.sh"'
finish
