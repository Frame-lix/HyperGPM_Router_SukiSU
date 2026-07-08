#!/system/bin/sh
MODDIR=${0%/*}/..
. "$MODDIR/common.sh"
# Wait until Android has finished booting.
i=0
while [ "$(getprop sys.boot_completed 2>/dev/null)" != "1" ] && [ $i -lt 120 ]; do
  sleep 2
  i=$((i + 1))
done
log "watchdog start"
# Re-apply several times during the first minutes because HyperOS SecurityCenter/Settings can rewrite secure settings.
count=0
while [ $count -lt 12 ]; do
  apply_google_route >/dev/null 2>&1 || true
  sleep 30
  count=$((count + 1))
done
log "watchdog done"
