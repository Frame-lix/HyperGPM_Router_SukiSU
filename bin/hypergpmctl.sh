#!/system/bin/sh
MODDIR=$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)
. "$MODDIR/common.sh"
trap 'release_apply_lock' EXIT
trap 'exit 143' TERM
trap 'exit 130' INT
case "$1" in
  apply)
    HYPERGPM_REFRESH_CONFLICT=1
    apply_google_route "${2:-}"
    rc=$?
    show_status
    exit "$rc"
    ;;
  status|"")
    scan_module_conflicts public >/dev/null 2>&1 || true
    show_status
    ;;
  report)
    HYPERGPM_REPORT_PROGRESS=1
    collect_report "${2:-public}"
    ;;
  plan)
    show_route_plan "${2:-}"
    ;;
  open)
    open_settings_pages
    ;;
  restore)
    restore_settings "${2:-safe}"
    rc=$?
    show_status
    exit "$rc"
    ;;
  log)
    cat "$(log_file)" 2>/dev/null || true
    ;;
  *)
    echo "usage: $0 {apply [observe-only|conservative|force]|plan [mode]|status|report [public|private]|open|restore [safe|force]|log}"
    exit 1
    ;;
esac
