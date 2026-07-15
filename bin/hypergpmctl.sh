#!/system/bin/sh
MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
. "$MODDIR/common.sh"
case "$1" in
  apply)
    apply_google_route
    rc=$?
    show_status
    exit "$rc"
    ;;
  status|"")
    show_status
    ;;
  report)
    REPORT_PROGRESS=1
    collect_report
    ;;
  open)
    open_settings_pages
    ;;
  restore)
    restore_settings
    rc=$?
    show_status
    exit "$rc"
    ;;
  log)
    cat "$(log_file)" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 {apply|status|report|open|restore|log}"
    exit 1
    ;;
esac
