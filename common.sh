#!/system/bin/sh
# Shared routing and diagnostics helpers for HyperGPM Router.

MODDIR=${MODDIR:-${0%/*}}
DATA_DIR=${HYPERGPM_DATA_DIR:-/data/adb/hypergpm-router}
LOG_DIR=$DATA_DIR/logs
CONF_DIR=$DATA_DIR/conf
BACKUP_DIR=$DATA_DIR/backup
STATE_DIR=$DATA_DIR/state
APPLY_LOCK_DIR=$DATA_DIR/apply.lock
mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR" "$STATE_DIR" 2>/dev/null || true

GMS_PKG=com.google.android.gms
CHROME_PKG=com.android.chrome

CREDENTIAL_PROVIDER_ACTION=android.service.credentials.CredentialProviderService
SYSTEM_CREDENTIAL_PROVIDER_ACTION=android.service.credentials.system.CredentialProviderService
GMS_PASSKEY_COMPONENT="$GMS_PKG/.auth.api.credentials.credman.service.PasswordAndPasskeyService"
GMS_AUTOFILL_COMPONENT="$GMS_PKG/.autofill.service.AutofillService"
AUTOFILL_SERVICE_ACTION=android.service.autofill.AutofillService
CREDENTIAL_PROVIDER_PERMISSION=android.permission.BIND_CREDENTIAL_PROVIDER_SERVICE
AUTOFILL_SERVICE_PERMISSION=android.permission.BIND_AUTOFILL_SERVICE

MAX_GMS_PROVIDERS=4
MAX_ENABLED_PROVIDERS=12
MAX_PROVIDER_VALUE_BYTES=2048
QUERY_TIMEOUT_SECONDS=4
SETTINGS_TIMEOUT_SECONDS=3
REPORT_TIMEOUT_SECONDS=6
REPORT_TOTAL_SECONDS=30

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || toybox date '+%Y-%m-%d %H:%M:%S'; }
log_file() { echo "$LOG_DIR/router.log"; }
log() { echo "[$(now)] $*" >> "$(log_file)"; }
println() { echo "$*"; log "$*"; }

sanitize_event_value() {
  printf '%s' "$1" | tr '\r\n\t ' '____' | cut -c 1-200
}

log_event() {
  local phase="$1" category="$2" user="$3" attempt="$4" rc="$5" status="$6" detail="$7"
  log "event phase=$(sanitize_event_value "$phase") category=$(sanitize_event_value "$category") user=$(sanitize_event_value "$user") attempt=$(sanitize_event_value "$attempt") rc=$(sanitize_event_value "$rc") status=$(sanitize_event_value "$status") detail=$(sanitize_event_value "$detail")"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }
getprop_safe() { getprop "$1" 2>/dev/null | tr -d '\r'; }

run_with_timeout() {
  local seconds="$1" temporary_stdout temporary_stderr timeout_marker child watchdog rc
  shift
  if [ "${HYPERGPM_DISABLE_TIMEOUT_CMD:-0}" != "1" ] && have_cmd timeout; then
    timeout "$seconds" "$@"
    return $?
  fi

  temporary_stdout=$(mktemp "$DATA_DIR/timeout-out.XXXXXX" 2>/dev/null) || return 125
  temporary_stderr=$(mktemp "$DATA_DIR/timeout-err.XXXXXX" 2>/dev/null) || {
    rm -f "$temporary_stdout" 2>/dev/null || true
    return 125
  }
  timeout_marker=$(mktemp "$DATA_DIR/timeout-marker.XXXXXX" 2>/dev/null) || {
    rm -f "$temporary_stdout" "$temporary_stderr" 2>/dev/null || true
    return 125
  }
  (
    unset HYPERGPM_DISABLE_TIMEOUT_CMD
    "$@"
  ) > "$temporary_stdout" 2> "$temporary_stderr" &
  child=$!
  (
    timeout_sleeper=""
    trap '[ -z "$timeout_sleeper" ] || kill "$timeout_sleeper" 2>/dev/null || true; exit 0' TERM INT
    command sleep "$seconds" &
    timeout_sleeper=$!
    wait "$timeout_sleeper" 2>/dev/null || exit 0
    if kill -0 "$child" 2>/dev/null; then
      echo timeout > "$timeout_marker"
      kill "$child" 2>/dev/null || true
      command sleep 1
      kill -9 "$child" 2>/dev/null || true
    fi
  ) &
  watchdog=$!
  wait "$child"
  rc=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  [ -s "$timeout_marker" ] && rc=124
  cat "$temporary_stdout"
  cat "$temporary_stderr" >&2
  rm -f "$temporary_stdout" "$temporary_stderr" "$timeout_marker" 2>/dev/null || true
  return "$rc"
}

output_has_transaction_error() {
  printf '%s\n' "$1" | grep -Eiq 'failed transaction|failure calling service|dead object|transaction failed'
}

single_line_detail() {
  printf '%s\n' "$1" | tr '\r\n' '  ' | cut -c 1-200
}

platform_api() {
  local value
  value=$(getprop_safe ro.build.version.sdk)
  case "$value" in
    36|37) echo "$value" ;;
    *) echo unknown ;;
  esac
}

hyperos_major() {
  local value
  value=$(getprop_safe ro.mi.os.version.name)
  case "$value" in
    OS3|OS3.*|3|3.*) echo 3 ;;
    OS4|OS4.*|4|4.*) echo 4 ;;
    *) echo unknown ;;
  esac
}

device_region() {
  local value mod_device
  value=$(getprop_safe ro.miui.region | tr '[:lower:]' '[:upper:]')
  mod_device=$(getprop_safe ro.product.mod_device | tr '[:upper:]' '[:lower:]')
  case "$value:$mod_device" in
    CN:*|CHINA:*) echo cn ;;
    *:*_global|GLOBAL:*) echo global ;;
    *) echo unknown ;;
  esac
}

user_state() {
  local user="$1" value
  value=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd user is-user-unlocked "$user" 2>/dev/null \
    | tr -d '\r' | tail -n 1)
  case "$value" in
    true|1) echo unlocked ;;
    false|0) echo locked ;;
    *) echo unknown ;;
  esac
}

credential_feature_state() {
  local value rc
  value=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" pm has-feature android.software.credentials 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { echo unknown; return; }
  case "$value" in
    true|*true*) echo true ;;
    false|*false*) echo false ;;
    *) echo unknown ;;
  esac
}

read_policy_value() {
  local key="$1" policy_file="$CONF_DIR/policy.conf"
  [ -f "$policy_file" ] || return 1
  awk -F= -v wanted="$key" '
    /^[[:space:]]*#/ { next }
    $1 == wanted { count++; if (count == 1) value=substr($0, index($0, "=") + 1) }
    END { if (count == 1) { print value; exit 0 } if (count > 1) exit 2; exit 1 }
  ' "$policy_file"
}

requested_mode() {
  local explicit="${1:-}" configured api os feature
  case "$explicit" in
    observe-only|conservative|force) echo "$explicit"; return ;;
    "") ;;
    *) echo invalid; return ;;
  esac

  configured=$(read_policy_value mode 2>/dev/null || true)
  case "$configured" in
    observe-only|conservative|force) echo "$configured"; return ;;
  esac

  api=$(platform_api)
  os=$(hyperos_major)
  feature=$(credential_feature_state)
  if [ "$api" = "37" ] || [ "$os" = "4" ] || [ "$feature" = "false" ]; then
    echo observe-only
  else
    echo conservative
  fi
}

autofill_policy() {
  local configured
  configured=$(read_policy_value manage_autofill 2>/dev/null || true)
  case "$configured" in
    true|false|auto) echo "$configured" ;;
    *) echo auto ;;
  esac
}

list_users() {
  local users
  users=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd user list 2>/dev/null \
    | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -n | uniq)
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
    out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings get --user "$user" secure "$key" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      printf '%s\n' "$out" | tr -d '\r'
      log_event settings_read secure "$user" "$attempt" "$rc" ok "$key"
      return 0
    fi
    detail=$(single_line_detail "$out")
    log_event settings_read secure "$user" "$attempt" "$rc" failed "$key:$detail"
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
    out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings put --user "$user" secure "$key" "$value" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      actual=$(settings_get "$user" "$key") || actual="__read_failed__"
      if [ "$actual" = "$value" ]; then
        log_event settings_write secure "$user" "$attempt" "$rc" ok "$key"
        return 0
      fi
    fi
    detail=$(single_line_detail "$out")
    log_event settings_write secure "$user" "$attempt" "$rc" failed "$key:$detail"
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

settings_delete() {
  local user="$1" key="$2" out actual rc attempt detail
  attempt=1
  while [ "$attempt" -le 3 ]; do
    out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings delete --user "$user" secure "$key" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      actual=$(settings_get "$user" "$key") || actual="__read_failed__"
      case "$actual" in
        ""|null)
          log_event settings_delete secure "$user" "$attempt" "$rc" ok "$key"
          return 0
          ;;
      esac
    fi
    detail=$(single_line_detail "$out")
    log_event settings_delete secure "$user" "$attempt" "$rc" failed "$key:$detail"
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
    log_event provider_query package "$user" "$attempt" "$rc" failed "$action:$package_name:$detail"
    [ "$rc" -eq 124 ] && break
    attempt=$((attempt + 1))
    sleep 1
  done
  return 1
}

query_service_details() {
  local user="$1" action="$2" package_name="$3" out rc attempt detail
  attempt=1
  while [ "$attempt" -le 2 ]; do
    out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package query-services \
      --user "$user" -a "$action" -p "$package_name" 2>&1)
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      printf '%s\n' "$out"
      return 0
    fi
    detail=$(single_line_detail "$out")
    log_event provider_details package "$user" "$attempt" "$rc" failed "$action:$package_name:$detail"
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
  local user="${1:-0}" standard system standard_details system_details raw dump provider
  gms_installed "$user" || return 0
  gms_package_disabled "$user" && return 0
  standard=$(query_service_components "$user" "$CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG") || standard=""
  system=$(query_service_components "$user" "$SYSTEM_CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG") || system=""
  standard_details=$(query_service_details "$user" "$CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG") || standard_details=""
  system_details=$(query_service_details "$user" "$SYSTEM_CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG") || system_details=""
  raw=$(printf '%s\n%s\n' "$standard" "$system" | extract_gms_components)
  dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)

  if [ -z "$raw" ] && dump_declares_service "$dump" "$GMS_PASSKEY_COMPONENT" \
    "$CREDENTIAL_PROVIDER_ACTION" "$CREDENTIAL_PROVIDER_PERMISSION"; then
    raw="$GMS_PASSKEY_COMPONENT"
    log_event provider_query package "$user" 1 0 fallback "$GMS_PASSKEY_COMPONENT"
  fi

  for provider in $raw; do
    if service_permission_in_details "$standard_details" "$provider" "$CREDENTIAL_PROVIDER_PERMISSION" \
      || service_permission_in_details "$system_details" "$provider" "$CREDENTIAL_PROVIDER_PERMISSION" \
      || service_permission_visible "$dump" "$provider" "$CREDENTIAL_PROVIDER_PERMISSION"; then
      echo "$provider"
    else
      log_event provider_validate package "$user" 1 1 invalid_permission "$provider"
    fi
  done | sort -u
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
    run_with_timeout "$QUERY_TIMEOUT_SECONDS" pm path --user "$user" "$GMS_PKG" >/dev/null 2>&1
  else
    run_with_timeout "$QUERY_TIMEOUT_SECONDS" pm path "$GMS_PKG" >/dev/null 2>&1
  fi
}

gms_package_disabled() {
  local user="$1"
  run_with_timeout "$QUERY_TIMEOUT_SECONDS" pm list packages --user "$user" -d "$GMS_PKG" 2>/dev/null \
    | grep -Fq "package:$GMS_PKG"
}

service_permission_visible() {
  local dump="$1" comp="$2" permission="$3" cls
  cls=${comp#*/}
  cls=${cls#.}
  printf '%s\n' "$dump" | grep -Fq "$cls" || return 1
  printf '%s\n' "$dump" | grep -Fq "$permission"
}

service_permission_in_details() {
  local details="$1" comp="$2" permission="$3" cls
  cls=${comp#*/}
  case "$cls" in
    .*) cls="${comp%%/*}${cls}" ;;
  esac
  printf '%s\n' "$details" | awk -v cls="$cls" -v permission="$permission" '
    /^[[:space:]]*Service #[0-9]+:/ { matched=0 }
    index($0, "name=" cls) { matched=1 }
    matched && index($0, "permission=" permission) { valid=1 }
    END { exit(valid ? 0 : 1) }
  '
}

dump_declares_service() {
  local dump="$1" comp="$2" action="$3" permission="$4"
  service_permission_visible "$dump" "$comp" "$permission" || return 1
  printf '%s\n' "$dump" | grep -Fq "$action"
}

provider_query_state() {
  local user="${1:-0}" standard system raw dump
  gms_installed "$user" || { echo failed; return; }
  gms_package_disabled "$user" && { echo failed; return; }
  standard=$(query_service_components "$user" "$CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG" 2>/dev/null || true)
  system=$(query_service_components "$user" "$SYSTEM_CREDENTIAL_PROVIDER_ACTION" "$GMS_PKG" 2>/dev/null || true)
  raw=$(printf '%s\n%s\n' "$standard" "$system")
  if [ -n "$(printf '%s\n' "$raw" | extract_gms_components)" ]; then
    echo supported
    return
  fi
  dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)
  if dump_declares_service "$dump" "$GMS_PASSKEY_COMPONENT" \
    "$CREDENTIAL_PROVIDER_ACTION" "$CREDENTIAL_PROVIDER_PERMISSION"; then
    echo fallback
  else
    echo failed
  fi
}

discover_gms_autofill_services() {
  local user="${1:-0}" raw details dump provider
  gms_installed "$user" || return 0
  gms_package_disabled "$user" && return 0
  raw=$(query_service_components "$user" "$AUTOFILL_SERVICE_ACTION" "$GMS_PKG" 2>/dev/null \
    | extract_gms_components || true)
  details=$(query_service_details "$user" "$AUTOFILL_SERVICE_ACTION" "$GMS_PKG" 2>/dev/null || true)
  dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)
  for provider in $raw; do
    if service_permission_in_details "$details" "$provider" "$AUTOFILL_SERVICE_PERMISSION" \
      || service_permission_visible "$dump" "$provider" "$AUTOFILL_SERVICE_PERMISSION"; then
      echo "$provider"
    else
      log_event autofill_validate package "$user" 1 1 invalid_permission "$provider"
    fi
  done | sort -u
}

choose_gms_autofill_provider() {
  local user="${1:-0}" providers provider first
  providers=$(discover_gms_autofill_services "$user")
  if printf '%s\n' "$providers" | grep -Fxq "$GMS_AUTOFILL_COMPONENT"; then
    echo "$GMS_AUTOFILL_COMPONENT"
    return
  fi
  first=""
  for provider in $providers; do
    first="$provider"
    break
  done
  echo "$first"
}

gms_state() {
  local user="${1:-0}" providers
  gms_installed "$user" || { echo missing; return; }
  gms_package_disabled "$user" && { echo disabled; return; }
  providers=$(discover_gms_credential_providers "$user")
  if [ -n "$providers" ]; then
    echo ready
  else
    echo visible
  fi
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
  gms_package_disabled "$user" && { echo ""; return; }
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

plan_value() {
  local plan_file="$1" key="$2"
  sed -n "s/^${key}=//p" "$plan_file" | head -n 1
}

write_plan_value() {
  local plan_file="$1" key="$2" value="$3"
  value=$(printf '%s' "$value" | tr '\r\n' '__')
  printf '%s=%s\n' "$key" "$value" >> "$plan_file"
}

is_oem_provider() {
  printf '%s\n' "$1" | grep -Eiq 'xiaomi|miui|com\.fido\.asm|mipass'
}

plan_google_route_for_user() {
  local user="$1" mode="$2" plan_file="$3"
  local providers primary current current_primary current_autofill newlist provider kept removed
  local state autofill_provider autofill_mode autofill_action autofill_reason action reason
  local ownership_file owned_credential owned_primary owned_autofill owned_autofill_managed

  : > "$plan_file" 2>/dev/null || return 1
  state=$(user_state "$user")
  action=apply
  reason=os3_api36_settings_route
  providers=""
  primary=""
  current=""
  current_primary=""
  current_autofill=""
  newlist=""
  removed=""
  autofill_provider=""
  autofill_action=preserve
  autofill_reason=credential_and_autofill_are_independent

  if [ "$state" = "locked" ]; then
    action=skip
    reason=user_locked
  elif [ "$mode" = "observe-only" ]; then
    action=observe
    reason=compatibility_mode_observe_only
  fi

  if [ "$state" = "locked" ]; then
    write_plan_value "$plan_file" user "$user"
    write_plan_value "$plan_file" mode "$mode"
    write_plan_value "$plan_file" user_state "$state"
    write_plan_value "$plan_file" action "$action"
    write_plan_value "$plan_file" reason "$reason"
    write_plan_value "$plan_file" credential_provider ""
    write_plan_value "$plan_file" current_credential_service ""
    write_plan_value "$plan_file" target_credential_service ""
    write_plan_value "$plan_file" current_credential_service_primary ""
    write_plan_value "$plan_file" target_credential_service_primary ""
    write_plan_value "$plan_file" removed_providers ""
    write_plan_value "$plan_file" kept_provider_count 0
    write_plan_value "$plan_file" current_autofill_service ""
    write_plan_value "$plan_file" gms_autofill_provider ""
    write_plan_value "$plan_file" autofill_action preserve
    write_plan_value "$plan_file" autofill_reason user_locked
    return 0
  fi

  if [ "$action" = "apply" ]; then
    providers=$(choose_gms_provider_list "$user")
    if [ -z "$providers" ]; then
      action=blocked
      reason=provider_missing_or_invalid
    else
      primary=${providers%%:*}
    fi
  else
    providers=$(choose_gms_provider_list "$user")
    [ -n "$providers" ] && primary=${providers%%:*}
  fi

  current=$(settings_get "$user" credential_service) || {
    action=blocked
    reason=settings_not_readable
    current="<read-failed>"
  }
  current_primary=$(settings_get "$user" credential_service_primary) || {
    action=blocked
    reason=settings_not_readable
    current_primary="<read-failed>"
  }
  current_autofill=$(settings_get "$user" autofill_service) || {
    action=blocked
    reason=settings_not_readable
    current_autofill="<read-failed>"
  }
  [ "$current" = "null" ] && current=""

  ownership_file="$STATE_DIR/user_${user}.last"
  if [ "$action" = "apply" ] && [ "$mode" = "conservative" ] && [ -f "$ownership_file" ]; then
    owned_credential=$(plan_value "$ownership_file" credential_service)
    owned_primary=$(plan_value "$ownership_file" credential_service_primary)
    owned_autofill=$(plan_value "$ownership_file" autofill_service)
    owned_autofill_managed=$(plan_value "$ownership_file" autofill_managed)
    if [ "$current" != "$owned_credential" ] || [ "$current_primary" != "$owned_primary" ] \
      || { [ "$owned_autofill_managed" = "1" ] && [ "$current_autofill" != "$owned_autofill" ]; }; then
      action=skip
      reason=selection_changed_since_last_apply
    fi
  fi

  newlist="$providers"
  kept=0
  for provider in $(printf '%s\n' "$current" | tr ':' '\n'); do
    is_component_name "$provider" || continue
    if is_oem_provider "$provider"; then
      removed=$(append_unique_component "$removed" "$provider")
      continue
    fi
    printf '%s\n' "$provider" | grep -Eiq '^com\.google\.android\.gms/' && continue
    [ "$kept" -ge "$MAX_ENABLED_PROVIDERS" ] && break
    newlist=$(append_bounded_component "$newlist" "$provider" "$MAX_ENABLED_PROVIDERS")
    kept=$((kept + 1))
  done

  autofill_provider=$(choose_gms_autofill_provider "$user")
  autofill_mode=$(autofill_policy)
  if [ "$action" = "apply" ] && [ -n "$autofill_provider" ] && [ "$autofill_mode" != "false" ]; then
    case "$mode:$autofill_mode:$current_autofill" in
      force:*:*|*:true:*)
        autofill_action=set
        autofill_reason=explicit_policy
        ;;
      *:auto:""|*:auto:null)
        autofill_action=set
        autofill_reason=no_existing_autofill
        ;;
      *:auto:com.google.android.gms/*)
        autofill_action=set
        autofill_reason=refresh_existing_google_autofill
        ;;
      *:auto:*)
        if is_oem_provider "$current_autofill"; then
          autofill_action=set
          autofill_reason=replace_oem_autofill
        else
          autofill_action=preserve
          autofill_reason=preserve_third_party_autofill
        fi
        ;;
    esac
  elif [ -z "$autofill_provider" ]; then
    autofill_reason=gms_autofill_missing_or_invalid
  elif [ "$autofill_mode" = "false" ]; then
    autofill_reason=autofill_disabled_by_policy
  fi

  write_plan_value "$plan_file" user "$user"
  write_plan_value "$plan_file" mode "$mode"
  write_plan_value "$plan_file" user_state "$state"
  write_plan_value "$plan_file" action "$action"
  write_plan_value "$plan_file" reason "$reason"
  write_plan_value "$plan_file" credential_provider "$primary"
  write_plan_value "$plan_file" current_credential_service "$current"
  write_plan_value "$plan_file" target_credential_service "$newlist"
  write_plan_value "$plan_file" current_credential_service_primary "$current_primary"
  write_plan_value "$plan_file" target_credential_service_primary "$primary"
  write_plan_value "$plan_file" removed_providers "$removed"
  write_plan_value "$plan_file" kept_provider_count "$kept"
  write_plan_value "$plan_file" current_autofill_service "$current_autofill"
  write_plan_value "$plan_file" gms_autofill_provider "$autofill_provider"
  write_plan_value "$plan_file" autofill_action "$autofill_action"
  write_plan_value "$plan_file" autofill_reason "$autofill_reason"
}

print_route_plan_file() {
  local plan_file="$1"
  echo "user=$(plan_value "$plan_file" user) mode=$(plan_value "$plan_file" mode) action=$(plan_value "$plan_file" action)"
  echo "reason=$(plan_value "$plan_file" reason)"
  echo "credential_service: $(plan_value "$plan_file" current_credential_service) -> $(plan_value "$plan_file" target_credential_service)"
  echo "credential_service_primary: $(plan_value "$plan_file" current_credential_service_primary) -> $(plan_value "$plan_file" target_credential_service_primary)"
  echo "removed_providers=$(plan_value "$plan_file" removed_providers)"
  echo "autofill_action=$(plan_value "$plan_file" autofill_action) reason=$(plan_value "$plan_file" autofill_reason)"
  echo "autofill_service: $(plan_value "$plan_file" current_autofill_service) -> $(plan_value "$plan_file" gms_autofill_provider)"
}

show_route_plan() {
  local explicit="${1:-}" mode user plan_file rc
  mode=$(requested_mode "$explicit")
  [ "$mode" != "invalid" ] || { echo "invalid mode: $explicit" >&2; return 1; }
  rc=0
  for user in $(list_users); do
    plan_file=$(mktemp "$DATA_DIR/plan.XXXXXX" 2>/dev/null) || return 1
    if plan_google_route_for_user "$user" "$mode" "$plan_file"; then
      print_route_plan_file "$plan_file"
    else
      rc=1
    fi
    rm -f "$plan_file" 2>/dev/null || true
  done
  return "$rc"
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

restore_key_value() {
  local user="$1" key="$2" value="$3"
  case "$value" in
    ""|null) settings_delete "$user" "$key" ;;
    *) settings_put "$user" "$key" "$value" ;;
  esac
}

record_route_ownership() {
  local user="$1" credential="$2" primary="$3" autofill_managed="$4" autofill="$5"
  local state_file="$STATE_DIR/user_${user}.last" temporary_file
  temporary_file="$state_file.tmp.$$"
  {
    echo "credential_service=$credential"
    echo "credential_service_primary=$primary"
    echo "autofill_managed=$autofill_managed"
    echo "autofill_service=$autofill"
  } > "$temporary_file" 2>/dev/null || return 1
  mv "$temporary_file" "$state_file" 2>/dev/null || return 1
  printf '%s\n' none > "$STATE_DIR/last-failure-class" 2>/dev/null || true
  return 0
}

restore_settings() {
  local user backup_file state_file key original last current managed user_rc rc
  rc=0
  for user in $(list_users); do
    backup_file="$BACKUP_DIR/user_${user}.secure"
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$backup_file" ] && [ -f "$state_file" ] || continue
    user_rc=0
    managed=$(plan_value "$state_file" autofill_managed)
    for key in credential_service credential_service_primary autofill_service; do
      [ "$key" = "autofill_service" ] && [ "$managed" != "1" ] && continue
      original=$(plan_value "$backup_file" "$key")
      last=$(plan_value "$state_file" "$key")
      current=$(settings_get "$user" "$key") || { user_rc=1; continue; }
      if [ "$current" != "$last" ]; then
        log_event restore secure "$user" 1 0 skipped_user_changed "$key"
        continue
      fi
      if restore_key_value "$user" "$key" "$original"; then
        log_event restore secure "$user" 1 0 restored "$key"
      else
        user_rc=1
      fi
    done
    if [ "$user_rc" -eq 0 ]; then
      rm -f "$backup_file" "$state_file" 2>/dev/null || true
    else
      rc=1
    fi
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
  local user="$1" mode="$2" plan_file action current current_primary current_autofill
  local target target_primary autofill_action target_autofill changed_credential changed_primary changed_autofill

  plan_file=$(mktemp "$DATA_DIR/plan.XXXXXX" 2>/dev/null) || return 1
  plan_google_route_for_user "$user" "$mode" "$plan_file" || {
    rm -f "$plan_file" 2>/dev/null || true
    return 1
  }
  [ "${HYPERGPM_EXPLAIN:-0}" = "1" ] && print_route_plan_file "$plan_file" >&2
  action=$(plan_value "$plan_file" action)
  case "$action" in
    observe|skip)
      log_event route_plan secure "$user" 1 0 "$action" "$(plan_value "$plan_file" reason)"
      rm -f "$plan_file" 2>/dev/null || true
      return 2
      ;;
    blocked)
      log_event route_plan secure "$user" 1 1 blocked "$(plan_value "$plan_file" reason)"
      rm -f "$plan_file" 2>/dev/null || true
      return 1
      ;;
  esac

  current=$(plan_value "$plan_file" current_credential_service)
  current_primary=$(plan_value "$plan_file" current_credential_service_primary)
  current_autofill=$(plan_value "$plan_file" current_autofill_service)
  target=$(plan_value "$plan_file" target_credential_service)
  target_primary=$(plan_value "$plan_file" target_credential_service_primary)
  autofill_action=$(plan_value "$plan_file" autofill_action)
  target_autofill=$(plan_value "$plan_file" gms_autofill_provider)
  changed_credential=0
  changed_primary=0
  changed_autofill=0

  if [ "$current" = "$target" ] && [ "$current_primary" = "$target_primary" ] \
    && { [ "$autofill_action" != "set" ] || [ "$current_autofill" = "$target_autofill" ]; }; then
    log_event route_apply secure "$user" 1 0 no_changes already_matches_plan
    rm -f "$plan_file" 2>/dev/null || true
    return 0
  fi

  backup_settings_once "$user" "$current" "$current_primary" "$current_autofill" || {
    log_event route_apply backup "$user" 1 1 failed backup_write
    rm -f "$plan_file" 2>/dev/null || true
    return 1
  }

  if [ "$current" != "$target" ]; then
    settings_put "$user" credential_service "$target" || {
      restore_key_value "$user" credential_service "$current" || true
      rm -f "$plan_file" 2>/dev/null || true
      return 1
    }
    changed_credential=1
  fi
  if [ "$current_primary" != "$target_primary" ]; then
    if settings_put "$user" credential_service_primary "$target_primary"; then
      changed_primary=1
    else
      restore_key_value "$user" credential_service_primary "$current_primary" || true
      [ "$changed_credential" -eq 1 ] && restore_key_value "$user" credential_service "$current" || true
      rm -f "$plan_file" 2>/dev/null || true
      return 1
    fi
  fi
  if [ "$autofill_action" = "set" ] && [ "$current_autofill" != "$target_autofill" ]; then
    if settings_put "$user" autofill_service "$target_autofill"; then
      changed_autofill=1
    else
      restore_key_value "$user" autofill_service "$current_autofill" || true
      [ "$changed_primary" -eq 1 ] && restore_key_value "$user" credential_service_primary "$current_primary" || true
      [ "$changed_credential" -eq 1 ] && restore_key_value "$user" credential_service "$current" || true
      rm -f "$plan_file" 2>/dev/null || true
      return 1
    fi
  fi

  if ! record_route_ownership "$user" "$target" "$target_primary" \
    "$([ "$autofill_action" = "set" ] && echo 1 || echo 0)" "$target_autofill"; then
    [ "$changed_autofill" -eq 1 ] && restore_key_value "$user" autofill_service "$current_autofill" || true
    [ "$changed_primary" -eq 1 ] && restore_key_value "$user" credential_service_primary "$current_primary" || true
    [ "$changed_credential" -eq 1 ] && restore_key_value "$user" credential_service "$current" || true
    rm -f "$plan_file" 2>/dev/null || true
    return 1
  fi

  log_event route_apply secure "$user" 1 0 ok "writes=$((changed_credential + changed_primary + changed_autofill))"
  rm -f "$plan_file" 2>/dev/null || true
  return 0
}

apply_google_route_locked() {
  local mode="$1" user result rc
  rc=0
  for user in $(list_users); do
    apply_google_route_for_user "$user" "$mode"
    result=$?
    [ "$result" -eq 1 ] && rc=1
  done
  return "$rc"
}

apply_google_route() {
  local explicit="${1:-}" mode rc
  mode=$(requested_mode "$explicit")
  [ "$mode" != "invalid" ] || {
    log_event route_apply policy all 1 2 invalid_mode "$explicit"
    return 2
  }
  acquire_apply_lock || return 1
  apply_google_route_locked "$mode"
  rc=$?
  release_apply_lock
  return "$rc"
}

current_boot_id() {
  local value
  value=$(cat /proc/sys/kernel/random/boot_id 2>/dev/null | tr -d '\r\n')
  [ -n "$value" ] || value=$(getprop_safe ro.runtime.firstboot)
  [ -n "$value" ] || value=unknown
  echo "$value"
}

apply_google_route_once_per_boot() {
  local source="${1:-boot}" marker_file="$STATE_DIR/boot-apply" boot_id previous mode rc
  boot_id=$(current_boot_id)
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  if [ "$boot_id" != "unknown" ] && [ "$previous" = "$boot_id" ]; then
    log_event boot_apply lifecycle all 1 0 skipped_already_attempted "$source"
    return 0
  fi

  acquire_apply_lock || return 1
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  if [ "$boot_id" != "unknown" ] && [ "$previous" = "$boot_id" ]; then
    release_apply_lock
    return 0
  fi
  mode=$(requested_mode "")
  apply_google_route_locked "$mode"
  rc=$?
  {
    echo "boot_id=$boot_id"
    echo "source=$source"
    echo "mode=$mode"
    echo "result=$rc"
  } > "$marker_file.tmp.$$" 2>/dev/null && mv "$marker_file.tmp.$$" "$marker_file" 2>/dev/null || true
  release_apply_lock
  log_event boot_apply lifecycle all 1 "$rc" attempted "$source:$mode"
  return "$rc"
}

classify_failure_text() {
  local text="$1"
  if printf '%s\n' "$text" | grep -Eiq \
    'Remote entry being dropped as it is not from the service configured by the OEM|Remote entry being dropped as it does not meet the restriction checks'; then
    echo deep_oem_hybrid_restriction
  elif printf '%s\n' "$text" | grep -Eiq 'TYPE_NO_CREATE_OPTIONS|NoCreateOptionException'; then
    echo no_create_options
  elif output_has_transaction_error "$text"; then
    echo settings_binder_transient
  else
    echo none
  fi
}

classify_recent_failure() {
  local raw output rc
  raw=$(run_with_timeout 3 logcat -d -t 500 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { echo unknown; return; }
  output=$(printf '%s\n' "$raw" \
    | grep -Ei 'Remote entry being dropped|TYPE_NO_CREATE_OPTIONS|NoCreateOptionException|Failed transaction' \
    | tail -n 80)
  classify_failure_text "$output"
}

verify_owned_routes() {
  local user state_file key managed expected actual rc
  rc=0
  for user in $(list_users); do
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$state_file" ] || continue
    managed=$(plan_value "$state_file" autofill_managed)
    for key in credential_service credential_service_primary autofill_service; do
      [ "$key" = "autofill_service" ] && [ "$managed" != "1" ] && continue
      expected=$(plan_value "$state_file" "$key")
      actual=$(settings_get "$user" "$key") || { rc=1; continue; }
      if [ "$actual" != "$expected" ]; then
        log_event route_verify secure "$user" 1 1 settings_rewritten_by_oem "$key"
        printf '%s\n' settings_rewritten_by_oem > "$STATE_DIR/last-failure-class" 2>/dev/null || true
        rc=1
      fi
    done
  done
  [ "$rc" -ne 0 ] \
    || printf '%s\n' none > "$STATE_DIR/last-failure-class" 2>/dev/null \
    || true
  return "$rc"
}

capability_snapshot() {
  local user="${1:-0}" mode providers autofill secure_state failure stored_failure profile reason
  mode=$(requested_mode "")
  providers=$(choose_gms_provider_list "$user")
  autofill=$(choose_gms_autofill_provider "$user")
  if settings_get "$user" credential_service >/dev/null 2>&1 \
    && settings_get "$user" credential_service_primary >/dev/null 2>&1 \
    && settings_get "$user" autofill_service >/dev/null 2>&1; then
    if [ -f "$STATE_DIR/user_${user}.last" ]; then
      secure_state=writable
    else
      secure_state=present
    fi
  else
    secure_state=unknown
  fi
  stored_failure=none
  if [ -f "$STATE_DIR/last-failure-class" ]; then
    stored_failure=$(sed -n '1p' "$STATE_DIR/last-failure-class" 2>/dev/null)
    case "$stored_failure" in
      settings_rewritten_by_oem|deep_oem_hybrid_restriction|no_create_options|settings_binder_transient|unknown|none) ;;
      *) stored_failure=unknown ;;
    esac
  fi
  [ "$stored_failure" != settings_rewritten_by_oem ] || secure_state=rewritten
  failure=$(classify_recent_failure)
  case "$failure" in
    none|unknown)
      [ "$stored_failure" = none ] || failure=$stored_failure
      ;;
  esac
  case "$(hyperos_major):$(platform_api)" in
    3:36) profile=generic-os3-api36 ;;
    *) profile=generic-observe ;;
  esac
  case "$mode" in
    observe-only) reason=os4_or_api37_not_supported_in_stage1 ;;
    conservative) reason=os3_api36_or_legacy_conservative_route ;;
    force) reason=user_explicit_force ;;
  esac
  echo "platform_api=$(platform_api)"
  echo "hyperos_major=$(hyperos_major)"
  echo "region=$(device_region)"
  echo "profile=$profile"
  echo "user_state=$(user_state "$user")"
  echo "gms_state=$(gms_state "$user")"
  echo "credential_feature=$(credential_feature_state)"
  echo "provider_query=$(provider_query_state "$user")"
  echo "secure_keys=$secure_state"
  echo "gms_credential_provider=${providers%%:*}"
  echo "gms_autofill_provider=$autofill"
  case "$failure" in
    deep_oem_hybrid_restriction) echo "oem_hybrid=detected" ;;
    unknown) echo "oem_hybrid=unknown" ;;
    *) echo "oem_hybrid=not_detected" ;;
  esac
  echo "failure_class=$failure"
  echo "compat_mode=$mode"
  echo "compat_reason=$reason"
}

show_status() {
  local user providers discovered autofill
  echo "=== Device ==="
  echo "brand=$(getprop_safe ro.product.brand)"
  echo "model=$(getprop_safe ro.product.model)"
  echo "device=$(getprop_safe ro.product.device)"
  echo "security_patch=$(getprop_safe ro.build.version.security_patch)"
  echo ""
  for user in $(list_users); do
    discovered=$(discover_gms_credential_providers "$user")
    providers=$(build_gms_provider_list "$discovered")
    autofill=$(choose_gms_autofill_provider "$user")
    echo "=== User $user capabilities ==="
    capability_snapshot "$user"
    echo ""
    echo "=== User $user routing ==="
    echo "discovered GMS providers:"
    printf '%s\n' "$discovered" | sed '/^$/d; s/^/  /'
    echo "chosen provider list: $providers"
    echo "chosen GMS autofill: $autofill"
    echo "Xiaomi providers found:"
    discover_xiaomi_credential_providers "$user" | sed 's/^/  /'
    echo "credential_service=$(settings_get "$user" credential_service 2>/dev/null || echo '<read failed>')"
    echo "credential_service_primary=$(settings_get "$user" credential_service_primary 2>/dev/null || echo '<read failed>')"
    echo "autofill_service=$(settings_get "$user" autofill_service 2>/dev/null || echo '<read failed>')"
    echo ""
  done
}

report_progress() {
  [ "${HYPERGPM_REPORT_PROGRESS:-0}" = "1" ] && echo "  - $*" >&2
}

epoch_seconds() {
  date '+%s' 2>/dev/null || echo 0
}

report_seconds_left() {
  local deadline="$1" now remaining
  now=$(epoch_seconds)
  case "$deadline:$now" in
    *[!0-9:]*|0:*|*:0) echo "$REPORT_TOTAL_SECONDS"; return ;;
  esac
  remaining=$((deadline - now))
  [ "$remaining" -gt 0 ] || remaining=0
  echo "$remaining"
}

capture_report_command() {
  local destination="$1" summary="$2" section_id="$3" requested="$4" line_limit="$5" deadline="$6"
  shift 6
  local temporary_file status remaining seconds start finish elapsed section_status
  temporary_file="$destination.$section_id.$$.tmp"
  remaining=$(report_seconds_left "$deadline")
  if [ "$remaining" -le 0 ]; then
    echo "[skipped: report total budget exhausted]" >> "$destination"
    echo "section=$section_id status=skipped elapsed=0s" >> "$summary"
    return 0
  fi
  seconds="$requested"
  [ "$remaining" -lt "$seconds" ] && seconds="$remaining"
  start=$(epoch_seconds)
  run_with_timeout "$seconds" "$@" > "$temporary_file" 2>&1
  status=$?
  head -n "$line_limit" "$temporary_file" >> "$destination" 2>/dev/null || true
  case "$status" in
    0) section_status=ok ;;
    124|137|143)
      section_status=timeout
      echo "[timed out after ${seconds}s]" >> "$destination"
      ;;
    *)
      section_status=failed
      echo "[command exited with status $status]" >> "$destination"
      ;;
  esac
  finish=$(epoch_seconds)
  elapsed=$((finish - start))
  [ "$elapsed" -ge 0 ] 2>/dev/null || elapsed=0
  echo "section=$section_id status=$section_status elapsed=${elapsed}s" >> "$summary"
  rm -f "$temporary_file" 2>/dev/null || true
}

capture_report_filtered() {
  local destination="$1" summary="$2" section_id="$3" requested="$4" pattern="$5" line_limit="$6" deadline="$7"
  shift 7
  local temporary_file filtered_file status remaining seconds start finish elapsed section_status
  temporary_file="$destination.$section_id.$$.tmp"
  filtered_file="$temporary_file.filtered"
  remaining=$(report_seconds_left "$deadline")
  if [ "$remaining" -le 0 ]; then
    echo "[skipped: report total budget exhausted]" >> "$destination"
    echo "section=$section_id status=skipped elapsed=0s" >> "$summary"
    return 0
  fi
  seconds="$requested"
  [ "$remaining" -lt "$seconds" ] && seconds="$remaining"
  start=$(epoch_seconds)
  run_with_timeout "$seconds" "$@" > "$temporary_file" 2>&1
  status=$?
  grep -Ei "$pattern" "$temporary_file" | head -n "$line_limit" > "$filtered_file" 2>/dev/null || true
  cat "$filtered_file" >> "$destination" 2>/dev/null || true
  case "$status" in
    0) section_status=ok ;;
    124|137|143)
      section_status=timeout
      echo "[timed out after ${seconds}s]" >> "$destination"
      ;;
    *)
      section_status=failed
      echo "[command exited with status $status]" >> "$destination"
      ;;
  esac
  finish=$(epoch_seconds)
  elapsed=$((finish - start))
  [ "$elapsed" -ge 0 ] 2>/dev/null || elapsed=0
  echo "section=$section_id status=$section_status elapsed=${elapsed}s" >> "$summary"
  rm -f "$temporary_file" "$filtered_file" 2>/dev/null || true
}

sanitize_report() {
  local source="$1" destination="$2" intermediate
  intermediate="$source.redacted.$$"
  awk '
    {
      lower=tolower($0)
      if (lower ~ /(android[_ ]?id|imei|meid|subscriber[_ ]?id|phone[_ ]?number|ssid|bssid|wifi[_ ]?mac|serial[_ ]?number)[=:]/) {
        print "[redacted sensitive field]"
      } else {
        print
      }
    }
  ' "$source" > "$intermediate" 2>/dev/null || return 1
  sed -E \
    -e 's/[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}/[REDACTED_EMAIL]/g' \
    -e 's/([0-9]{1,3}\.){3}[0-9]{1,3}/[REDACTED_IP]/g' \
    -e 's/([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}/[REDACTED_MAC]/g' \
    -e 's#/(Users|home)/[^ /]+/#[REDACTED_HOST_PATH]/#g' \
    -e 's/(Bearer|Basic)[[:space:]]+[A-Za-z0-9._~+\/-]+/\1 [REDACTED_TOKEN]/g' \
    -e 's/(gh[pousr]_[A-Za-z0-9_]+|github_pat_[A-Za-z0-9_]+)/[REDACTED_TOKEN]/g' \
    "$intermediate" > "$destination" 2>/dev/null
  rm -f "$intermediate" 2>/dev/null || true
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
  local report_mode="${1:-public}" report_file raw_file summary_file timestamp config_dir config_index
  local started deadline failure
  case "$report_mode" in
    public|private) ;;
    *) echo "invalid report mode: $report_mode" >&2; return 2 ;;
  esac
  timestamp=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo now)
  report_file="$LOG_DIR/report-$report_mode-$timestamp-$$.txt"
  raw_file="$report_file.raw"
  summary_file="$report_file.summary.tmp.$$"
  : > "$raw_file" 2>/dev/null || return 1
  : > "$summary_file" 2>/dev/null || { rm -f "$raw_file" 2>/dev/null || true; return 1; }
  started=$(epoch_seconds)
  deadline=$((started + REPORT_TOTAL_SECONDS))

  {
    echo "HyperGPM Router report $timestamp mode=$report_mode"
    echo ""
  } >> "$raw_file"

  report_progress "device, providers and secure settings"
  (
    HYPERGPM_DISABLE_TIMEOUT_CMD=1
    capture_report_command "$raw_file" "$summary_file" status 12 260 "$deadline" show_status
  )

  report_progress "Credential Manager state"
  {
    echo "=== dumpsys credential ==="
  } >> "$raw_file" 2>&1
  capture_report_filtered "$raw_file" "$summary_file" credential "$REPORT_TIMEOUT_SECONDS" \
    'Credential|Provider|Create|Remote|TYPE_NO_CREATE_OPTIONS|service' 180 "$deadline" dumpsys credential

  if [ "$report_mode" = "private" ]; then
    report_progress "bounded system configuration scan"
    echo "" >> "$raw_file"
    echo "=== Credential-related system configuration files ===" >> "$raw_file"
    config_index=0
    for config_dir in \
      /system/etc/permissions /system/etc/sysconfig \
      /system_ext/etc/permissions /system_ext/etc/sysconfig \
      /product/etc/permissions /product/etc/sysconfig \
      /vendor/etc/permissions /vendor/etc/sysconfig \
      /odm/etc/permissions /odm/etc/sysconfig; do
      [ -d "$config_dir" ] || continue
      config_index=$((config_index + 1))
      echo "-- $config_dir --" >> "$raw_file"
      capture_report_command "$raw_file" "$summary_file" "config-$config_index" 1 30 "$deadline" \
        grep -RIlE 'credential_service|CredentialProviderService|passkey|fido|autofill_service' "$config_dir"
    done

    report_progress "package summaries"
    echo "" >> "$raw_file"
    echo "=== Package snippets: com.android.settings ===" >> "$raw_file"
    capture_report_filtered "$raw_file" "$summary_file" settings-package "$REPORT_TIMEOUT_SECONDS" \
      'credentials|credential|autofill|passkey|default' 120 "$deadline" dumpsys package com.android.settings
    echo "" >> "$raw_file"
    echo "=== Package snippets: com.miui.securitycenter ===" >> "$raw_file"
    capture_report_filtered "$raw_file" "$summary_file" securitycenter-package "$REPORT_TIMEOUT_SECONDS" \
      'credential|autofill|passkey|fido|settings' 120 "$deadline" dumpsys package com.miui.securitycenter
    echo "" >> "$raw_file"
    echo "=== Package snippets: com.google.android.gms ===" >> "$raw_file"
    capture_report_filtered "$raw_file" "$summary_file" gms-package "$REPORT_TIMEOUT_SECONDS" \
      'CredentialProviderService|PasswordAndPasskeyService|credman|identitycredentials|CredentialChooser|autofill|RemoteService' \
      160 "$deadline" dumpsys package "$GMS_PKG"
  fi

  report_progress "recent credential logcat"
  echo "" >> "$raw_file"
  echo "=== Recent Credential logcat ===" >> "$raw_file"
  capture_report_filtered "$raw_file" "$summary_file" logcat "$REPORT_TIMEOUT_SECONDS" \
    'Credential|CredMan|CreateCredential|TYPE_NO_CREATE_OPTIONS|Remote entry|Provider|HyperPasskey|FIDO|passkey' \
    220 "$deadline" logcat -d -t 1200

  if [ "$report_mode" = "private" ]; then
    report_progress "module operation log"
    echo "" >> "$raw_file"
    echo "=== HyperGPM Router log ===" >> "$raw_file"
    if [ -f "$(log_file)" ]; then
      tail -n 160 "$(log_file)" >> "$raw_file" 2>&1 || true
    else
      echo "[router log not found]" >> "$raw_file"
    fi
  fi

  failure=$(classify_recent_failure)
  echo "$failure" > "$STATE_DIR/last-failure-class" 2>/dev/null || true
  {
    echo ""
    echo "=== Collection summary ==="
    cat "$summary_file"
    echo "failure_class=$failure"
    echo "total_budget=${REPORT_TOTAL_SECONDS}s"
  } >> "$raw_file"

  if ! sanitize_report "$raw_file" "$report_file"; then
    rm -f "$raw_file" "$summary_file" "$report_file" 2>/dev/null || true
    return 1
  fi
  rm -f "$raw_file" "$summary_file" 2>/dev/null || true
  prune_reports
  echo "$report_file"
}

open_settings_pages() {
  run_with_timeout 4 am start -a android.settings.CREDENTIAL_PROVIDER >/dev/null 2>&1 || true
  sleep 1
  run_with_timeout 4 am start -a android.intent.action.VIEW \
    -d 'https://myaccount.google.com/signinoptions/passkeys' -p "$CHROME_PKG" >/dev/null 2>&1 \
    || run_with_timeout 4 am start -a android.intent.action.VIEW \
      -d 'https://myaccount.google.com/signinoptions/passkeys' >/dev/null 2>&1 || true
}
