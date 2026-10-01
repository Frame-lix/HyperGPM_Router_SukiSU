#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
log "boot-completed apply"
run_with_timeout 90 boot_cycle boot-completed >/dev/null 2>&1 || true
