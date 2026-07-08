#!/system/bin/sh
MODDIR=${0%/*}
# Run watchdog in background; KernelSU service stage is non-blocking, but we keep it explicit.
sh "$MODDIR/bin/watchdog.sh" >/dev/null 2>&1 &
