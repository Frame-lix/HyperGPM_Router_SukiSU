#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/common.sh"
# Wait until Android has finished booting, then exit permanently after the bounded window.
HYPERGPM_WAIT_COUNT=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ "$HYPERGPM_WAIT_COUNT" -lt 120 ]; do
  sleep 2
  HYPERGPM_WAIT_COUNT=$((HYPERGPM_WAIT_COUNT + 1))
done
if [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ]; then
  log_event watchdog lifecycle all 120 1 timeout boot_not_completed
  exit 0
fi
log "watchdog start"
# Apply at most once per boot. A later read-only check records OEM rewrites without a retry storm.
apply_google_route_once_per_boot watchdog >/dev/null 2>&1 || true
sleep 15
verify_owned_routes >/dev/null 2>&1 || true
log "watchdog done"
