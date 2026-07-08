#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
log "uninstall: restoring backed-up secure settings"
restore_settings >/dev/null 2>&1 || true
