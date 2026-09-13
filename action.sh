#!/system/bin/sh
MODDIR=${0%/*}
. "$MODDIR/common.sh"
HYPERGPM_CTL=${HYPERGPM_CTL:-$MODDIR/bin/hypergpmctl.sh}
HYPERGPM_ACTION_STARTED=$(epoch_seconds)
HYPERGPM_STATUS_RESULT=failed
HYPERGPM_APPLY_RESULT=failed
HYPERGPM_REPORT_RESULT=failed
HYPERGPM_OPEN_RESULT=failed

echo "HyperOS Google Passkey Router"
echo "Action: inspect, apply capability-selected route, collect public report, open settings"
echo ""
println "Action button pressed"
echo "[1/4] Current status before applying:"
if run_with_timeout 18 sh "$HYPERGPM_CTL" status; then
  HYPERGPM_STATUS_RESULT=ok
else
  echo "status failed or timed out; continuing"
fi
echo ""
echo "[2/4] Applying Google Password Manager route..."
if HYPERGPM_EXPLAIN=1 HYPERGPM_LOCK_OWNER=action HYPERGPM_LOCK_WAIT_SECONDS=3 \
  run_with_timeout 30 sh "$HYPERGPM_CTL" apply; then
  HYPERGPM_APPLY_RESULT=ok
  echo "done"
else
  echo "failed: route was not fully applied; see $(log_file)"
fi
echo ""
echo "[3/4] Collecting privacy-filtered public report..."
if report_output=$(HYPERGPM_REPORT_PROGRESS=1 run_with_timeout 36 sh "$HYPERGPM_CTL" report public); then
  report=$(printf '%s\n' "$report_output" | tail -n 1)
  HYPERGPM_REPORT_RESULT=ok
  echo "report=$report"
else
  report=""
  echo "failed or timed out: report could not be completed"
fi
echo ""
echo "[4/4] Opening Credential Provider settings and Google passkey page..."
if run_with_timeout 8 sh "$HYPERGPM_CTL" open; then
  HYPERGPM_OPEN_RESULT=ok
  echo "done"
else
  echo "failed or timed out; open the Credential Provider settings manually"
fi
echo ""
HYPERGPM_ACTION_FINISHED=$(epoch_seconds)
HYPERGPM_ACTION_ELAPSED=$((HYPERGPM_ACTION_FINISHED - HYPERGPM_ACTION_STARTED))
[ "$HYPERGPM_ACTION_ELAPSED" -ge 0 ] 2>/dev/null || HYPERGPM_ACTION_ELAPSED=0
echo "Summary: status=$HYPERGPM_STATUS_RESULT apply=$HYPERGPM_APPLY_RESULT report=$HYPERGPM_REPORT_RESULT open=$HYPERGPM_OPEN_RESULT elapsed=${HYPERGPM_ACTION_ELAPSED}s"
echo "If passkey creation still fails, review the public report before sharing:"
[ -n "$report" ] && echo "$report" || echo "No report was created."
echo ""
echo "Tip: run as root for manual commands:"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh status"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh apply"
echo "  sh /data/adb/modules/hypergpm-router/bin/hypergpmctl.sh report"
