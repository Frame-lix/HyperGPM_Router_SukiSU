#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/common.sh"
# Compatibility fallback: 120 seconds for boot readiness, then a 90-second
# routing window. The outer ceiling also bounds a stuck getprop or sleep.
watchdog_cycle() {
HYPERGPM_WAIT_COUNT=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$HYPERGPM_WAIT_COUNT" -lt 60 ]; do
  sleep 2
  HYPERGPM_WAIT_COUNT=$((HYPERGPM_WAIT_COUNT + 1))
done
if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
  log_event watchdog lifecycle all 60 1 timeout boot_not_completed_120s
  exit 0
fi
log "watchdog start"
run_with_timeout 90 boot_cycle service-fallback >/dev/null 2>&1 || true
log "watchdog done"
}
run_with_timeout 210 watchdog_cycle >/dev/null 2>&1 || true
