# Sourced by the demo's scripts: `at <second>` waits until that many seconds
# after DEMO_T0 (set once by stage.sh), so the lanes, the orchestrator and the
# feed of tower events stay in step.
at() { local now; : "${DEMO_T0:?set by demo/stage.sh}"; now=$(( $(date +%s) - DEMO_T0 )); [ "$now" -ge "$1" ] || sleep $(( $1 - now )); }
say() { printf '%s\n' "$@"; }
