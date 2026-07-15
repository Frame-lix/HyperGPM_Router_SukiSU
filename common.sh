#!/system/bin/sh
# Shared routing and diagnostics helpers for HyperGPM Router.

MODDIR=${MODDIR:-${0%/*}}
DATA_DIR=${HYPERGPM_DATA_DIR:-/data/adb/hypergpm-router}
LOG_DIR=$DATA_DIR/logs
CONF_DIR=$DATA_DIR/conf
BACKUP_DIR=$DATA_DIR/backup
APPLY_LOCK_DIR=$DATA_DIR/apply.lock
mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR" 2>/dev/null || true

GMS_PKG=com.google.android.gms
CHROME_PKG=com.android.chrome

CREDENTIAL_PROVIDER_ACTION=android.service.credentials.CredentialProviderService
SYSTEM_CREDENTIAL_PROVIDER_ACTION=android.service.credentials.system.CredentialProviderService
GMS_PASSKEY_COMPONENT="$GMS_PKG/.auth.api.credentials.credman.service.PasswordAndPasskeyService"
GMS_AUTOFILL_COMPONENT="$GMS_PKG/.autofill.service.AutofillService"

MAX_GMS_PROVIDERS=4
MAX_ENABLED_PROVIDERS=12
MAX_PROVIDER_VALUE_BYTES=2048
QUERY_TIMEOUT_SECONDS=4
REPORT_TIMEOUT_SECONDS=6

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || toybox date '+%Y-%m-%d %H:%M:%S'; }
log_file() { echo "$LOG_DIR/router.log"; }
log() { echo "[$(now)] $*" >> "$(log_file)"; }
println() { echo "$*"; log "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
getprop_safe() { getprop "$1" 2>/dev/null | tr -d '\r'; }

run_with_timeout() {
  local seconds="$1"
  shift
  if have_cmd timeout; then
    timeout "$seconds" "$@"
  else
    "$@"
  fi
}

output_has_transaction_error() {
  printf '%s\n' "$1" | grep -Eiq 'failed transaction|failure calling service|dead object|transaction failed'
}

single_line_detail() {
  printf '%s\n' "$1" | tr '\r\n' '  ' | cut -c 1-200
}

list_users() {
  local users
  users=$(cmd user list 2>/dev/null | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -n | uniq)
  if [ -z "$users" ]; then
    echo 0
  else
    echo "$users"
  fi
}

settings_get() {
  local user="$1" key="$2" out rc attempt detail
  attempt=1
  while [ "$attempt" -le 3 ]; do
    out=$(settings get --user "$user" secure "$key" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      printf '%s\n' "$out" | tr -d '\r'
      return 0
    fi
    detail=$(single_line_detail "$out")
    log "settings get failed: user=$user key=$key attempt=$attempt rc=$rc detail=$detail"
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

settings_put() {
  local user="$1" key="$2" value="$3" out actual rc attempt detail
  actual=$(settings_get "$user" "$key") || actual="__read_failed__"
  [ "$actual" = "$value" ] && return 0

  attempt=1
  while [ "$attempt" -le 3 ]; do
    out=$(settings put --user "$user" secure "$key" "$value" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      actual=$(settings_get "$user" "$key") || actual="__read_failed__"
      [ "$actual" = "$value" ] && return 0
    fi
    detail=$(single_line_detail "$out")
    log "settings put failed: user=$user key=$key attempt=$attempt rc=$rc detail=$detail"
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

settings_delete() {
  local user="$1" key="$2" out actual rc attempt detail
  attempt=1
  while [ "$attempt" -le 3 ]; do
    out=$(settings delete --user "$user" secure "$key" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      actual=$(settings_get "$user" "$key") || actual="__read_failed__"
      case "$actual" in
        ""|null) return 0 ;;
      esac
    fi
    detail=$(single_line_detail "$out")
    log "settings delete failed: user=$user key=$key attempt=$attempt rc=$rc detail=$detail"
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

is_component_name() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.$-]+$'
}

append_unique_component() {
  local list="$1" comp="$2"
  [ -z "$comp" ] && { echo "$list"; return; }
  case ":$list:" in
    *":$comp:"*) echo "$list" ;;
    ::) echo "$comp" ;;
    *) echo "$list:$comp" ;;
  esac
}

component_count() {
  local list="$1"
  [ -z "$list" ] && { echo 0; return; }
  printf '%s\n' "$list" | tr ':' '\n' | sed '/^$/d' | wc -l | tr -d ' '
}

append_bounded_component() {
  local list="$1" comp="$2" max_count="$3" candidate count bytes
  is_component_name "$comp" || { echo "$list"; return; }
  candidate=$(append_unique_component "$list" "$comp")
  count=$(component_count "$candidate")
  bytes=$(printf '%s' "$candidate" | wc -c | tr -d ' ')
  if [ "$count" -le "$max_count" ] && [ "$bytes" -le "$MAX_PROVIDER_VALUE_BYTES" ]; then
    echo "$candidate"
  else
    echo "$list"
  fi
}

flatten_gms_component() {
  sed 's#^com\.google\.android\.gms/com\.google\.android\.gms\.#com.google.android.gms/.#'
}

query_service_components() {
  local user="$1" action="$2" package_name="$3" out rc attempt detail
  attempt=1
  while [ "$attempt" -le 2 ]; do
    if [ -n "$package_name" ]; then
      out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package query-services \
        --brief --components --user "$user" -a "$action" -p "$package_name" 2>&1)
    else
      out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package query-services \
        --brief --components --user "$user" -a "$action" 2>&1)
    fi
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      printf '%s\n' "$out"
      return 0
    fi
    detail=$(single_line_detail "$out")
    log "query-services failed: user=$user action=$action package=$package_name attempt=$attempt rc=$rc detail=$detail"
    [ "$rc" -eq 124 ] && break
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

extract_gms_components() {
  grep -Eo 'com\.google\.android\.gms/[A-Za-z0-9_.$-]+' \
    | flatten_gms_component \
    | sort -u
}

discover_gms_credential_providers() {
  local user="${1:-0}"
  {
    query_service_components "$user" "$CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG" || true
    query_service_components "$user" "$SYSTEM_CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG" || true
  } | extract_gms_components
}

discover_xiaomi_credential_providers() {
  local user="${1:-0}"
  {
    query_service_components "$user" "$CREDENTIAL_PROVIDER_ACTION" "" || true
    query_service_components "$user" "$SYSTEM_CREDENTIAL_PROVIDER_ACTION" "" || true
  } | grep -Eo '(com\.(fido|miui|xiaomi)[A-Za-z0-9_.-]*)/[A-Za-z0-9_.$-]+' | sort -u
}

gms_installed() {
  local user="${1:-}"
  if [ -n "$user" ]; then
    pm path --user "$user" "$GMS_PKG" >/dev/null 2>&1
  else
    pm path "$GMS_PKG" >/dev/null 2>&1
  fi
}

enable_component() {
  local user="$1" comp="$2" out rc
  out=$(pm enable --user "$user" "$comp" 2>&1)
  rc=$?
  [ -n "$out" ] && log "pm enable: user=$user component=$comp rc=$rc output=$out"
  return "$rc"
}

component_declared() {
  local comp="$1" cls out
  cls=${comp#*/}
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null \
    | grep -F "$cls" | head -n 1)
  [ -n "$out" ]
}

build_gms_provider_list() {
  local providers="$1" list provider
  list=""
  if printf '%s\n' "$providers" | grep -Fxq "$GMS_PASSKEY_COMPONENT"; then
    list="$GMS_PASSKEY_COMPONENT"
  fi
  for provider in $providers; do
    list=$(append_bounded_component "$list" "$provider" "$MAX_GMS_PROVIDERS")
  done
  echo "$list"
}

choose_gms_provider_list() {
  local user="${1:-0}" providers
  gms_installed "$user" || { echo ""; return; }
  providers=$(discover_gms_credential_providers "$user")
  build_gms_provider_list "$providers"
}

backup_settings_once() {
  local user="$1" credential_value="$2" primary_value="$3" autofill_value="$4"
  local backup_file="$BACKUP_DIR/user_${user}.secure" temporary_file
  [ -f "$backup_file" ] && return 0
  temporary_file="$backup_file.tmp.$$"
  {
    echo "credential_service=$credential_value"
    echo "credential_service_primary=$primary_value"
    echo "autofill_service=$autofill_value"
  } > "$temporary_file" 2>/dev/null || return 1
  mv "$temporary_file" "$backup_file" 2>/dev/null || return 1
}

restore_user_values() {
  local user="$1" credential_value="$2" primary_value="$3" autofill_value="$4" rc
  rc=0
  case "$credential_value" in
    ""|null) settings_delete "$user" credential_service || rc=1 ;;
    *) settings_put "$user" credential_service "$credential_value" || rc=1 ;;
  esac
  case "$primary_value" in
    ""|null) settings_delete "$user" credential_service_primary || rc=1 ;;
    *) settings_put "$user" credential_service_primary "$primary_value" || rc=1 ;;
  esac
  case "$autofill_value" in
    ""|null) settings_delete "$user" autofill_service || rc=1 ;;
    *) settings_put "$user" autofill_service "$autofill_value" || rc=1 ;;
  esac
  return "$rc"
}

restore_settings() {
  local user backup_file key value rc
  rc=0
  for user in $(list_users); do
    backup_file="$BACKUP_DIR/user_${user}.secure"
    [ -f "$backup_file" ] || continue
    while IFS='=' read -r key value; do
      case "$value" in
        ""|null) settings_delete "$user" "$key" || rc=1 ;;
        *) settings_put "$user" "$key" "$value" || rc=1 ;;
      esac
    done < "$backup_file"
  done
  return "$rc"
}

acquire_apply_lock() {
  local attempt owner
  attempt=1
  while [ "$attempt" -le 10 ]; do
    if mkdir "$APPLY_LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$APPLY_LOCK_DIR/pid" 2>/dev/null || true
      return 0
    fi
    owner=$(cat "$APPLY_LOCK_DIR/pid" 2>/dev/null)
    if [ -n "$owner" ] && ! kill -0 "$owner" 2>/dev/null; then
      rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    if [ -z "$owner" ] && [ "$attempt" -gt 1 ]; then
      rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
      continue
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  log "apply lock busy; owner=${owner:-unknown}"
  return 1
}

release_apply_lock() {
  rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
}

apply_google_route_for_user() {
  local user="$1" providers primary current current_primary current_autofill
  local newlist provider kept

  gms_installed "$user" || {
    log "Google Play services is unavailable for user=$user"
    return 1
  }
  providers=$(choose_gms_provider_list "$user")
  if ! printf '%s\n' "$providers" | tr ':' '\n' | grep -Fxq "$GMS_PASSKEY_COMPONENT"; then
    enable_component "$user" "$GMS_PASSKEY_COMPONENT" >/dev/null 2>&1 || true
    providers=$(choose_gms_provider_list "$user")
  fi
  if [ -z "$providers" ] && component_declared "$GMS_PASSKEY_COMPONENT"; then
    providers="$GMS_PASSKEY_COMPONENT"
  fi
  if [ -z "$providers" ]; then
    log "No Google credential provider found for user=$user"
    return 1
  fi
  primary=${providers%%:*}

  current=$(settings_get "$user" credential_service) || return 1
  current_primary=$(settings_get "$user" credential_service_primary) || return 1
  current_autofill=$(settings_get "$user" autofill_service) || return 1
  [ "$current" = "null" ] && current=""

  backup_settings_once "$user" "$current" "$current_primary" "$current_autofill" || {
    log "Failed to back up secure settings for user=$user"
    return 1
  }

  newlist="$providers"
  kept=0
  for provider in $(printf '%s\n' "$current" | tr ':' '\n'); do
    is_component_name "$provider" || continue
    printf '%s\n' "$provider" | grep -Eiq 'xiaomi|miui|com\.fido\.asm|mipass' && continue
    printf '%s\n' "$provider" | grep -Eiq '^com\.google\.android\.gms/' && continue
    [ "$kept" -ge "$MAX_ENABLED_PROVIDERS" ] && break
    newlist=$(append_bounded_component "$newlist" "$provider" "$MAX_ENABLED_PROVIDERS")
    kept=$((kept + 1))
  done

  if ! settings_put "$user" credential_service "$newlist" \
    || ! settings_put "$user" credential_service_primary "$primary" \
    || ! settings_put "$user" autofill_service "$GMS_AUTOFILL_COMPONENT"; then
    log "Route write failed for user=$user; restoring values from before this apply"
    restore_user_values "$user" "$current" "$current_primary" "$current_autofill" || true
    return 1
  fi

  log "user=$user credential_service=$newlist"
  log "user=$user credential_service_primary=$primary"
  log "user=$user autofill_service=$GMS_AUTOFILL_COMPONENT"
  return 0
}

apply_google_route_locked() {
  local user rc
  rc=0
  gms_installed || {
    log "Google Play services is not installed; skip applying route"
    return 1
  }
  for user in $(list_users); do
    apply_google_route_for_user "$user" || rc=1
  done
  return "$rc"
}

apply_google_route() {
  local rc
  acquire_apply_lock || return 1
  apply_google_route_locked
  rc=$?
  release_apply_lock
  return "$rc"
}

show_status() {
  local user providers discovered
  echo "=== Device ==="
  echo "brand=$(getprop_safe ro.product.brand) model=$(getprop_safe ro.product.model) device=$(getprop_safe ro.product.device) sdk=$(getprop_safe ro.build.version.sdk)"
  echo "mi.os=$(getprop_safe ro.mi.os.version.name) mod_device=$(getprop_safe ro.product.mod_device) build=$(getprop_safe ro.build.version.incremental)"
  echo ""
  echo "=== Google components ==="
  echo "gms installed: $(pm path "$GMS_PKG" 2>/dev/null | head -n 1)"
  echo "chrome installed: $(pm path "$CHROME_PKG" 2>/dev/null | head -n 1)"
  echo ""
  for user in $(list_users); do
    discovered=$(discover_gms_credential_providers "$user")
    providers=$(build_gms_provider_list "$discovered")
    echo "=== User $user ==="
    echo "discovered GMS providers:"
    printf '%s\n' "$discovered" | sed '/^$/d; s/^/  /'
    echo "chosen provider list: $providers"
    echo "Xiaomi providers found:"
    discover_xiaomi_credential_providers "$user" | sed 's/^/  /'
    echo "credential_service=$(settings_get "$user" credential_service 2>/dev/null || echo '<read failed>')"
    echo "credential_service_primary=$(settings_get "$user" credential_service_primary 2>/dev/null || echo '<read failed>')"
    echo "autofill_service=$(settings_get "$user" autofill_service 2>/dev/null || echo '<read failed>')"
    echo ""
  done
}

report_progress() {
  [ "${REPORT_PROGRESS:-0}" = "1" ] && echo "  - $*" >&2
}

capture_report_command() {
  local destination="$1" section_id="$2" seconds="$3" line_limit="$4"
  shift 4
  local temporary_file status
  temporary_file="$destination.$section_id.tmp"
  if ! have_cmd timeout; then
    echo "[skipped: timeout command unavailable]" >> "$destination"
    return 0
  fi
  timeout "$seconds" "$@" > "$temporary_file" 2>&1
  status=$?
  head -n "$line_limit" "$temporary_file" >> "$destination" 2>/dev/null || true
  case "$status" in
    0) ;;
    124|137|143) echo "[timed out after ${seconds}s]" >> "$destination" ;;
    *) echo "[command exited with status $status]" >> "$destination" ;;
  esac
  rm -f "$temporary_file" 2>/dev/null || true
}

capture_report_filtered() {
  local destination="$1" section_id="$2" seconds="$3" pattern="$4" line_limit="$5"
  shift 5
  local temporary_file status
  temporary_file="$destination.$section_id.tmp"
  if ! have_cmd timeout; then
    echo "[skipped: timeout command unavailable]" >> "$destination"
    return 0
  fi
  timeout "$seconds" "$@" > "$temporary_file" 2>&1
  status=$?
  grep -Ei "$pattern" "$temporary_file" | head -n "$line_limit" >> "$destination" 2>/dev/null || true
  case "$status" in
    0) ;;
    124|137|143) echo "[timed out after ${seconds}s]" >> "$destination" ;;
    *) echo "[command exited with status $status]" >> "$destination" ;;
  esac
  rm -f "$temporary_file" 2>/dev/null || true
}

prune_reports() {
  local report_file count
  count=0
  for report_file in $(ls -1t "$LOG_DIR"/report-*.txt 2>/dev/null); do
    count=$((count + 1))
    [ "$count" -le 5 ] && continue
    rm -f "$report_file" 2>/dev/null || true
  done
}

collect_report() {
  local report_file timestamp config_dir config_index
  timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo now)
  report_file="$LOG_DIR/report-$timestamp-$$.txt"
  : > "$report_file" 2>/dev/null || return 1

  {
    echo "HyperGPM Router report $timestamp"
    echo ""
  } >> "$report_file"

  report_progress "device, providers and secure settings"
  show_status >> "$report_file" 2>&1

  report_progress "Credential Manager state"
  {
    echo "=== Credential Manager feature ==="
    pm has-feature android.software.credentials 2>/dev/null || true
    echo ""
    echo "=== dumpsys credential ==="
  } >> "$report_file" 2>&1
  capture_report_command "$report_file" credential "$REPORT_TIMEOUT_SECONDS" 180 dumpsys credential

  report_progress "bounded system configuration scan"
  echo "" >> "$report_file"
  echo "=== Credential-related system configuration files ===" >> "$report_file"
  config_index=0
  for config_dir in \
    /system/etc/permissions /system/etc/sysconfig \
    /system_ext/etc/permissions /system_ext/etc/sysconfig \
    /product/etc/permissions /product/etc/sysconfig \
    /vendor/etc/permissions /vendor/etc/sysconfig \
    /odm/etc/permissions /odm/etc/sysconfig; do
    [ -d "$config_dir" ] || continue
    config_index=$((config_index + 1))
    echo "-- $config_dir --" >> "$report_file"
    capture_report_command "$report_file" "config-$config_index" 1 30 \
      grep -RIlE 'credential_service|CredentialProviderService|passkey|fido|autofill_service' "$config_dir"
  done

  report_progress "package summaries"
  echo "" >> "$report_file"
  echo "=== Package snippets: com.android.settings ===" >> "$report_file"
  capture_report_filtered "$report_file" settings-package "$REPORT_TIMEOUT_SECONDS" \
    'credentials|credential|autofill|passkey|default' 160 dumpsys package com.android.settings
  echo "" >> "$report_file"
  echo "=== Package snippets: com.miui.securitycenter ===" >> "$report_file"
  capture_report_filtered "$report_file" securitycenter-package "$REPORT_TIMEOUT_SECONDS" \
    'credential|autofill|passkey|fido|settings' 160 dumpsys package com.miui.securitycenter
  echo "" >> "$report_file"
  echo "=== Package snippets: com.google.android.gms ===" >> "$report_file"
  capture_report_filtered "$report_file" gms-package "$REPORT_TIMEOUT_SECONDS" \
    'CredentialProviderService|PasswordAndPasskeyService|credman|identitycredentials|CredentialChooser|autofill|RemoteService' \
    200 dumpsys package "$GMS_PKG"

  report_progress "recent credential logcat"
  echo "" >> "$report_file"
  echo "=== Recent Credential logcat ===" >> "$report_file"
  capture_report_filtered "$report_file" logcat "$REPORT_TIMEOUT_SECONDS" \
    'Credential|CredMan|CreateCredential|TYPE_NO_CREATE_OPTIONS|Remote entry|Provider|HyperPasskey|FIDO|passkey' \
    300 logcat -d -t 1500

  report_progress "module operation log"
  echo "" >> "$report_file"
  echo "=== HyperGPM Router log ===" >> "$report_file"
  if [ -f "$(log_file)" ]; then
    tail -n 200 "$(log_file)" >> "$report_file" 2>&1 || true
  else
    echo "[router log not found]" >> "$report_file"
  fi

  echo "" >> "$report_file"
  echo "report_file=$report_file" >> "$report_file"
  prune_reports
  echo "$report_file"
}

open_settings_pages() {
  am start -a android.settings.CREDENTIAL_PROVIDER >/dev/null 2>&1 || true
  sleep 1
  am start -a android.intent.action.VIEW -d 'https://myaccount.google.com/signinoptions/passkeys' -p "$CHROME_PKG" >/dev/null 2>&1 \
    || am start -a android.intent.action.VIEW -d 'https://myaccount.google.com/signinoptions/passkeys' >/dev/null 2>&1 || true
}
