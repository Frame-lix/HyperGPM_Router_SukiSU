#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
log "boot-completed apply"
apply_google_route_once_per_boot boot-completed >/dev/null 2>&1 || true
verify_owned_routes_once boot-completed >/dev/null 2>&1 || true
