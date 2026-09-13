#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/common.sh"
# Compatibility fallback only. It exits after at most 120 seconds.
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
apply_google_route_once_per_boot service-fallback >/dev/null 2>&1 || true
verify_owned_routes_once service-fallback >/dev/null 2>&1 || true
log "watchdog done"
