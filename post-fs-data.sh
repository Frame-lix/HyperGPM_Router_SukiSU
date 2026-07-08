#!/system/bin/sh
# Keep this lightweight. Settings provider is not ready here on many devices.
MODDIR=${0%/*}
mkdir -p /data/adb/hypergpm-router/logs 2>/dev/null || true
printf '[post-fs-data] HyperGPM Router loaded\n' >> /data/adb/hypergpm-router/logs/router.log 2>/dev/null || true
