#!/system/bin/sh
ui_print "- HyperOS Google Passkey Router"
ui_print "- Script-only SukiSU/KernelSU module"
ui_print "- Installs action.sh, boot enforcement, and diagnostics"
ui_print "- Reboot after installation, then press module Action once"
chmod 0755 "$MODPATH/action.sh" 2>/dev/null || true
chmod 0755 "$MODPATH/service.sh" 2>/dev/null || true
chmod 0755 "$MODPATH/boot-completed.sh" 2>/dev/null || true
chmod 0755 "$MODPATH/post-fs-data.sh" 2>/dev/null || true
chmod 0755 "$MODPATH/uninstall.sh" 2>/dev/null || true
chmod 0755 "$MODPATH/bin"/*.sh 2>/dev/null || true
mkdir -p /data/adb/hypergpm-router/logs 2>/dev/null || true
chmod 0700 /data/adb/hypergpm-router /data/adb/hypergpm-router/logs 2>/dev/null || true
