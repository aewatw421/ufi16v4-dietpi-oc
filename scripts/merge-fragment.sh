#!/usr/bin/env bash
# Merge a Kconfig fragment into an existing .config.
#
# Handles the three shapes a symbol can have in a .config:
#   CONFIG_FOO=y            enabled
#   CONFIG_FOO="string"     value
#   # CONFIG_FOO is not set disabled
#
# For every symbol the fragment mentions, the fragment's value wins; the
# kernel's "olddefconfig" pass then resolves the resulting dependencies. This
# mirrors scripts/kconfig/merge_config.sh, which is not available in partial
# clones, so the build works either way.
#
# Usage: merge-fragment.sh <config> <fragment>
set -euo pipefail

CONFIG=$1
FRAGMENT=$2

[[ -f $CONFIG   ]] || { echo "no such config: $CONFIG" >&2; exit 1; }
[[ -f $FRAGMENT ]] || { echo "no such fragment: $FRAGMENT" >&2; exit 1; }

declare -A WANT=()
declare -a ORDER=()
while IFS= read -r line; do
	line=${line%%#*}
	line=${line//[$'\r\t ']/}
	[[ $line == CONFIG_*=* ]] || continue
	sym=${line%%=*}
	[[ ${WANT[$sym]+set} ]] || ORDER+=("$sym")
	WANT["$sym"]=$line
done < "$FRAGMENT"

tmp=$(mktemp)
keep_symbol() { # $1 = .config line
	local l=$1 sym
	if [[ $l =~ ^(CONFIG_[A-Za-z0-9_]+)= ]]; then
		sym=${BASH_REMATCH[1]}
		[[ ${WANT[$sym]+set} ]] && return 1
	elif [[ $l =~ ^#\ (CONFIG_[A-Za-z0-9_]+)\ is\ not\ set$ ]]; then
		sym=${BASH_REMATCH[1]}
		[[ ${WANT[$sym]+set} ]] && return 1
	fi
	return 0
}

while IFS= read -r line || [[ $line ]]; do
	keep_symbol "$line" && printf '%s\n' "$line"
done < "$CONFIG" > "$tmp"

for sym in "${ORDER[@]}"; do printf '%s\n' "${WANT[$sym]}"; done >> "$tmp"

{ grep '^CONFIG_' "$tmp" | sort; grep -v '^CONFIG_' "$tmp" | grep -v '^$' || true; } > "$CONFIG"
rm -f "$tmp"

echo "merged ${#ORDER[@]} symbols from $(basename "$FRAGMENT")"
