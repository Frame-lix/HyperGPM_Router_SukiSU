#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
log "boot-completed apply"
apply_google_route >/dev/null 2>&1 || true
collect_report >/dev/null 2>&1 || true
