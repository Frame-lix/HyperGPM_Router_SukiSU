#!/system/bin/sh
MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
. "$MODDIR/common.sh"
case "$1" in
  apply)
    apply_google_route
    show_status
    ;;
  status|"")
    show_status
    ;;
  report)
    collect_report
    ;;
  open)
    open_settings_pages
    ;;
  restore)
    restore_settings
    show_status
    ;;
  log)
    cat "$(log_file)" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 {apply|status|report|open|restore|log}"
    exit 1
    ;;
esac
