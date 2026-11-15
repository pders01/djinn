#!/usr/bin/env bash
# Profile a running djinn process for N seconds via macOS `sample`.
# Usage: scripts/profile.sh [duration_sec]
#
# Captures process call stacks using macOS sample's default interval and
# writes its plain-text report to /tmp/djinn-sample.txt. The summary below
# ranks sampled frames across all threads; it is not folded flamegraph input.
#
# Typical workflow:
#   1. Build ReleaseFast using the pinned environment, then start that binary:
#        nix develop --command ./scripts/build.sh -Doptimize=ReleaseFast
#      Debug safety/integrity work can distort profiles. No percentage or
#      performance target is asserted without recording the build/workload.
#   2. In another shell, run scripts/profile.sh 10.
#   3. Trigger the slow operation inside djinn (e.g. scrolling terminal output).
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

# Scan the process call graph and pull the heaviest frames at each
# indent depth. `sample` prefixes frames with "<count>  <indent>+ <symbol>";
# the indent encodes call depth. Sorting by count (column 1, numeric desc)
# and slicing the top N surfaces both leaves and hot interior nodes.
echo "Heaviest sampled frames (all threads):"
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
