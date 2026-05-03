#!/usr/bin/env bash
# Profile a running djinn process for N seconds via macOS `sample`.
# Usage: scripts/profile.sh [duration_sec]
#
# Captures main-thread call stacks at 1 ms intervals and writes a
# folded text report to /tmp/djinn-sample.txt. Hot paths surface as
# the deepest "Call graph" entries with the highest sample counts.
#
# Typical workflow:
#   1. Start djinn — IMPORTANT: build with ReleaseFast for any meaningful
#      perf measurement. Debug builds run ghostty's verifyIntegrity sweep
#      on every page grow, which dominates ~70% of parse time and looks
#      like a bottleneck that doesn't exist in release.
#        zig build -Doptimize=ReleaseFast
#   2. In another shell, run scripts/profile.sh 10.
#   3. Trigger the slow operation inside djinn (e.g. CC initial paint).
#   4. Open /tmp/djinn-sample.txt and look for the heaviest leaves.

set -euo pipefail

duration="${1:-10}"
pid="$(pgrep -f '^.*/djinn$' | head -n1 || true)"

if [[ -z "$pid" ]]; then
  echo "error: no running djinn process found (pgrep returned nothing)" >&2
  exit 1
fi

out=/tmp/djinn-sample.txt
echo "Sampling djinn (pid=$pid) for ${duration}s. Trigger slow path now."
sample "$pid" "$duration" -file "$out" >/dev/null

echo
echo "wrote $out"
echo

# Find the main thread's call graph and pull the heaviest frames at each
# indent depth. `sample` prefixes frames with "<count>  <indent>+ <symbol>";
# the indent encodes call depth. Sorting by count (column 1, numeric desc)
# and slicing the top N surfaces both leaves and hot interior nodes.
echo "Heaviest main-thread frames:"
awk '
  /^Call graph:/ { in_cg = 1; next }
  /^Total number/ { in_cg = 0 }
  in_cg && /^[[:space:]]*[0-9]+/ {
    # Strip leading whitespace; print "count  symbol".
    sub(/^[[:space:]]+/, "")
    print
  }
' "$out" \
  | sort -k1,1nr \
  | head -n 30

echo
echo "Binary images of interest (djinn + ghostty) tend to dominate the"
echo "list when CPU-bound. CoreText / CoreGraphics frames at the top mean"
echo "rendering. Ghostty hash_map / wyhash means parser-bound."
