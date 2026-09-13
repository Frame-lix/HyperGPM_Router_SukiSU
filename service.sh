#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

# KernelSU/SukiSU provides a dedicated boot-completed stage. Keep service only as
# a bounded compatibility fallback for managers that do not expose that stage.
if [ "${KSU:-}" = true ] || [ "${KSU_LATE_LOAD:-0}" = 1 ]; then
  log_event service_fallback lifecycle all 0 0 skipped boot_completed_supported
  exit 0
fi
sh "$MODDIR/bin/watchdog.sh" >/dev/null 2>&1 &
