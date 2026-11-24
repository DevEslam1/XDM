#!/usr/bin/env bash
#
# Coverage gate for DMX.
#
# Parses an lcov.info file produced by `flutter test --coverage` and fails if
# line coverage falls below a threshold. Machine-generated sources (Drift
# `.g.dart`, generated localizations, plugin registrants) and the app
# bootstrap (`main.dart`) are excluded from the denominator because they are
# not meaningfully unit-testable and would otherwise skew the number.
#
# Usage:
#   tool/coverage_gate.sh [lcov_file] [min_percent]
#
# Defaults: lcov_file=coverage/lcov.info, min_percent=60
#
set -euo pipefail

LCOV_FILE="${1:-coverage/lcov.info}"
MIN_COVERAGE="${2:-60}"

if [[ ! -f "$LCOV_FILE" ]]; then
  echo "ERROR: '$LCOV_FILE' not found. Run 'flutter test --coverage' first." >&2
  exit 1
fi

awk -v min="$MIN_COVERAGE" '
  function excluded(sf) {
    return (sf ~ /\.g\.dart$/) \
        || (sf ~ /l10n/) \
        || (sf ~ /main\.dart$/) \
        || (sf ~ /generated_plugin_registrant/)
  }
  /^SF:/ {
    sf = substr($0, 4)
    gsub(/\r/, "", sf)
    skip = excluded(sf)
    next
  }
  /^LF:/ { if (!skip) { lf = substr($0, 4); gsub(/\r/, "", lf); LF += lf } next }
  /^LH:/ { if (!skip) { lh = substr($0, 4); gsub(/\r/, "", lh); LH += lh } next }
  END {
    if (LF == 0) {
      print "ERROR: no instrumented lines found in " FILENAME > "/dev/stderr"
      exit 2
    }
    pct = (LH / LF) * 100
    printf "Line coverage (excl. generated/l10n/main.dart): %.2f%% (%d/%d lines)\n", pct, LH, LF
    if (pct + 0 < min + 0) {
      printf "FAIL: coverage %.2f%% is below the required %.2f%%\n", pct, min > "/dev/stderr"
      exit 1
    }
    printf "PASS: coverage %.2f%% meets the required %.2f%%\n", pct, min
  }
' "$LCOV_FILE"
