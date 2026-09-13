#!/system/bin/sh
# Keep this lightweight. Settings provider is not ready here on many devices.
MODDIR=${0%/*}
. "$MODDIR/common.sh"
log_event post_fs_data lifecycle all 0 0 loaded no_settings_access
