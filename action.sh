#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"

echo "HyperOS Google Passkey Router"
echo "Action: apply route, collect report, open settings/passkey pages"
echo ""
println "Action button pressed"
echo "[1/4] Current status before applying:"
show_status | sed -n '1,80p'
echo ""
echo "[2/4] Applying Google Password Manager route..."
if apply_google_route; then
  echo "done"
else
  echo "failed: no Google credential provider found"
fi
echo ""
echo "[3/4] Collecting report..."
report=$(collect_report)
echo "report=$report"
echo ""
echo "[4/4] Opening Credential Provider settings and Google passkey page..."
open_settings_pages
echo "done"
echo ""
echo "If passkey creation still fails, send this report path/content:"
echo "$report"
echo ""
echo "Tip: run as root for manual commands:"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh status"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report"
