#!/system/bin/sh
# Shared routing and diagnostics helpers for HyperGPM Router.

MODDIR=${MODDIR:-${0%/*}}
DATA_DIR=${HYPERGPM_DATA_DIR:-/data/adb/hypergpm-router}
LOG_DIR=$DATA_DIR/logs
CONF_DIR=$DATA_DIR/conf
BACKUP_DIR=$DATA_DIR/backup
STATE_DIR=$DATA_DIR/state
APPLY_LOCK_DIR=$DATA_DIR/apply.lock
PROFILE_FILE=${HYPERGPM_PROFILE_FILE:-$MODDIR/compat-profiles.conf}
FINGERPRINT_FILE=$STATE_DIR/success.fingerprint
QUICK_CHECK_FILE=$STATE_DIR/quick-check
CONFLICT_FILE=$STATE_DIR/conflicts.summary
MODULES_ROOT=${HYPERGPM_MODULES_ROOT:-/data/adb/modules}
mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR" "$STATE_DIR" 2>/dev/null || true
chmod 0700 "$DATA_DIR" "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR" "$STATE_DIR" 2>/dev/null || true

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
LOG_MAX_BYTES=131072
CONFLICT_MAX_MODULES=64
CONFLICT_MAX_FILES=128
CONFLICT_MAX_FILES_PER_MODULE=12
CONFLICT_MAX_FILE_BYTES=65536
CONFLICT_TOTAL_SECONDS=4

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || toybox date '+%Y-%m-%d %H:%M:%S'; }
log_file() { echo "$LOG_DIR/router.log"; }

rotate_router_log() {
  local file size
  file=$(log_file)
  [ -f "$file" ] || return 0
  size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -le "$LOG_MAX_BYTES" ] && return 0
  [ ! -f "$file.1" ] || mv "$file.1" "$file.2" 2>/dev/null || true
  mv "$file" "$file.1" 2>/dev/null || true
}

log() {
  rotate_router_log
  echo "[$(now)] $*" >> "$(log_file)"
}
println() { echo "$*"; log "$*"; }

secure_state_file() {
  [ -e "$1" ] && chmod 0600 "$1" 2>/dev/null || true
}

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

framework_resource_value() {
  local user="$1" resource_name="$2" out rc
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd overlay lookup --user "$user" \
    android "android:string/$resource_name" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || return 1
  printf '%s\n' "$out" | tr -d '\r' | tail -n 1
}

framework_component_resource_state() {
  local user="$1" resource_name="$2" value
  value=$(framework_resource_value "$user" "$resource_name" 2>/dev/null) || {
    echo unknown
    return
  }
  value=$(printf '%s' "$value" | sed 's/^[^=]*=[[:space:]]*//')
  if is_component_name "$value"; then
    echo configured
  elif [ -z "$value" ] || [ "$value" = null ]; then
    echo not_configured
  else
    echo unknown
  fi
}

framework_provider_array_state() {
  local user="$1" resource_name="$2" out rc value
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd overlay lookup --user "$user" \
    android "android:array/$resource_name" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 0 ] || { echo unknown; return; }
  value=$(printf '%s\n' "$out" | tr -d '\r' | sed 's/^[^=]*=[[:space:]]*//' | tail -n 1)
  if printf '%s\n' "$value" | grep -Eq '[A-Za-z0-9_.-]+/[A-Za-z0-9_.$-]+'; then
    echo configured
  elif [ -z "$value" ] || [ "$value" = null ] || [ "$value" = '[]' ]; then
    echo not_configured
  else
    echo unknown
  fi
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

build_stability() {
  local incremental display_id build_type build_tags codename combined
  incremental=$(getprop_safe ro.build.version.incremental | tr '[:upper:]' '[:lower:]')
  display_id=$(getprop_safe ro.build.display.id | tr '[:upper:]' '[:lower:]')
  build_type=$(getprop_safe ro.build.type | tr '[:upper:]' '[:lower:]')
  build_tags=$(getprop_safe ro.build.tags | tr '[:upper:]' '[:lower:]')
  codename=$(getprop_safe ro.build.version.codename)
  combined="$incremental $display_id"
  case "$combined" in
    *beta*|*alpha*|*preview*|*canary*|*developer*|*dev*) echo beta; return ;;
  esac
  case "$codename" in
    ""|REL) ;;
    *) echo beta; return ;;
  esac
  if [ "$build_type" = user ] && printf '%s\n' "$build_tags" | grep -Fq release-keys \
    && [ "$codename" = REL ]; then
    echo stable
  else
    echo unknown
  fi
}

profile_field() {
  local line="$1" wanted="$2"
  printf '%s\n' "$line" | awk -F'|' -v wanted="$wanted" '
    {
      for (i = 1; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == wanted) {
          count++
          if (count == 1) value=substr($i, index($i, "=") + 1)
        }
      }
    }
    END {
      if (count == 1) { print value; exit 0 }
      if (count > 1) exit 2
      exit 1
    }
  '
}

profile_line_is_valid() {
  local line="$1" id os api stability status auto_apply
  id=$(profile_field "$line" id 2>/dev/null) || return 1
  os=$(profile_field "$line" os 2>/dev/null) || return 1
  api=$(profile_field "$line" api 2>/dev/null) || return 1
  stability=$(profile_field "$line" stability 2>/dev/null) || return 1
  status=$(profile_field "$line" status 2>/dev/null) || return 1
  auto_apply=$(profile_field "$line" auto_apply 2>/dev/null) || return 1
  printf '%s\n' "$id" | grep -Eq '^[a-z0-9][a-z0-9._-]{2,63}$' || return 1
  case "$os" in 3|4) ;; *) return 1 ;; esac
  case "$api" in 36|37) ;; *) return 1 ;; esac
  case "$stability" in any|beta|stable|unknown) ;; *) return 1 ;; esac
  case "$status" in planned|reported|verified|unsupported) ;; *) return 1 ;; esac
  case "$auto_apply" in true|false) ;; *) return 1 ;; esac
  if [ "$auto_apply" = true ]; then
    case "$id:$status" in
      generic-os3-api36:reported|*:verified) ;;
      *) return 1 ;;
    esac
  fi
  return 0
}

select_platform_profile() {
  local os api stability wanted line line_os line_api line_stability
  os=$(hyperos_major)
  api=$(platform_api)
  stability=$(build_stability)
  [ -f "$PROFILE_FILE" ] || return 1
  case "$os:$api" in
    3:36|3:37|4:36|4:37) ;;
    *) return 1 ;;
  esac
  for wanted in "$stability" any; do
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in ""|\#*) continue ;; esac
      profile_line_is_valid "$line" || continue
      line_os=$(profile_field "$line" os)
      line_api=$(profile_field "$line" api)
      line_stability=$(profile_field "$line" stability)
      if [ "$line_os" = "$os" ] && [ "$line_api" = "$api" ] \
        && [ "$line_stability" = "$wanted" ]; then
        echo "$line"
        return 0
      fi
    done < "$PROFILE_FILE"
    [ "$wanted" = any ] && break
  done
  return 1
}

platform_profile_field() {
  local wanted="$1" line
  line=$(select_platform_profile 2>/dev/null) || return 1
  profile_field "$line" "$wanted"
}

platform_profile_id() {
  platform_profile_field id 2>/dev/null || echo generic-observe
}

platform_profile_status() {
  platform_profile_field status 2>/dev/null || echo planned
}

compatibility_reason() {
  local feature auto_apply
  feature=$(credential_feature_state)
  [ "$feature" != false ] || { echo credential_feature_unavailable; return; }
  auto_apply=$(platform_profile_field auto_apply 2>/dev/null || echo false)
  if [ "$auto_apply" = true ]; then
    echo stage1_foundation_profile
  elif select_platform_profile >/dev/null 2>&1; then
    echo profile_requires_device_validation_or_explicit_mode
  else
    echo unknown_os_api_or_build_profile
  fi
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
  local explicit="${1:-}" configured feature auto_apply
  case "$explicit" in
    observe-only|conservative|force) echo "$explicit"; return ;;
    "") ;;
    *) echo invalid; return ;;
  esac

  configured=$(read_policy_value mode 2>/dev/null || true)
  case "$configured" in
    observe-only|conservative|force) echo "$configured"; return ;;
  esac

  feature=$(credential_feature_state)
  auto_apply=$(platform_profile_field auto_apply 2>/dev/null || echo false)
  if [ "$feature" != false ] && [ "$auto_apply" = true ]; then
    echo conservative
  else
    echo observe-only
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

cached_conflict_value() {
  local key="$1"
  plan_value "$CONFLICT_FILE" "$key" 2>/dev/null || true
}

conflict_level() {
  local status writers gms hook
  status=$(cached_conflict_value scan_status)
  [ "$status" = ok ] || { echo unknown; return; }
  writers=$(cached_conflict_value settings_writers)
  gms=$(cached_conflict_value gms_managers)
  hook=$(cached_conflict_value deep_hooks)
  case "$writers:$gms:$hook" in
    *[!0-9:]*|::) echo unknown ;;
    0:0:0) echo none ;;
    *) echo ownership_unclear ;;
  esac
}

append_private_id() {
  local list="$1" id="$2"
  case "$id" in *[!A-Za-z0-9._-]*|"") id=unidentified ;; esac
  append_unique_component "$(printf '%s' "$list" | tr ',' ':')" "$id" | tr ':' ','
}

scan_module_conflicts() {
  local report_mode="${1:-public}" module_list file_list module file module_id size relative per_module_files
  local started now scanned_modules scanned_files status writer gms hook framework
  local writer_count gms_count hook_count framework_count skipped_count
  local writer_ids gms_ids hook_ids framework_ids temporary_file
  case "$report_mode" in public|private) ;; *) return 2 ;; esac
  writer_count=0
  gms_count=0
  hook_count=0
  framework_count=0
  skipped_count=0
  scanned_modules=0
  scanned_files=0
  writer_ids=""
  gms_ids=""
  hook_ids=""
  framework_ids=""
  status=ok
  started=$(epoch_seconds)
  module_list=$(mktemp "$DATA_DIR/conflict-modules.XXXXXX" 2>/dev/null) || return 1
  file_list=$(mktemp "$DATA_DIR/conflict-files.XXXXXX" 2>/dev/null) || {
    rm -f "$module_list" 2>/dev/null || true
    return 1
  }
  if [ ! -d "$MODULES_ROOT" ]; then
    status=unavailable
    : > "$module_list"
  else
    find "$MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d 2>/dev/null \
      | head -n "$CONFLICT_MAX_MODULES" > "$module_list"
  fi

  while IFS= read -r module || [ -n "$module" ]; do
    [ -d "$module" ] && [ ! -L "$module" ] || { skipped_count=$((skipped_count + 1)); continue; }
    module_id=${module##*/}
    [ "$module_id" != hypergpm-router ] || continue
    scanned_modules=$((scanned_modules + 1))
    writer=0
    gms=0
    hook=0
    framework=0
    : > "$file_list"
    for relative in module.prop service.sh boot-completed.sh post-fs-data.sh action.sh \
      uninstall.sh common.sh system.prop sepolicy.rule; do
      [ -f "$module/$relative" ] && [ ! -L "$module/$relative" ] \
        && printf '%s\n' "$module/$relative" >> "$file_list"
    done
    [ ! -d "$module/bin" ] || [ -L "$module/bin" ] \
      || find "$module/bin" -maxdepth 1 -type f 2>/dev/null >> "$file_list"
    [ ! -d "$module/system" ] || [ -L "$module/system" ] \
      || find "$module/system" -maxdepth 3 -type f 2>/dev/null >> "$file_list"
    per_module_files=0
    while IFS= read -r file || [ -n "$file" ]; do
      [ "$per_module_files" -lt "$CONFLICT_MAX_FILES_PER_MODULE" ] || break
      [ -f "$file" ] && [ ! -L "$file" ] && [ -r "$file" ] \
        || { skipped_count=$((skipped_count + 1)); continue; }
      size=$(wc -c < "$file" 2>/dev/null | tr -d ' ')
      case "$size" in ''|*[!0-9]*) skipped_count=$((skipped_count + 1)); continue ;; esac
      [ "$size" -le "$CONFLICT_MAX_FILE_BYTES" ] \
        || { skipped_count=$((skipped_count + 1)); continue; }
      per_module_files=$((per_module_files + 1))
      scanned_files=$((scanned_files + 1))
      if grep -Eiq 'credential_service(_primary)?|autofill_service' "$file" \
        && grep -Eiq '(^|[^a-z])(settings|cmd[[:space:]]+settings)[[:space:]]+(put|delete|reset)' "$file"; then
        writer=1
      fi
      if grep -Fiq 'com.google.android.gms' "$file" \
        && grep -Eiq 'freeze|unfreeze|disable|enable|suspend|unsuspend|denylist|detach|pm[[:space:]]' "$file"; then
        gms=1
      fi
      if grep -Eiq 'hyperpasskey|lsposed|xposed|zygisk|system_server|(^|[^a-z])kpm([^a-z]|$)' "$file" \
        && grep -Eiq 'credential|passkey|credman|fido' "$file"; then
        hook=1
      fi
      case "$file" in
        */system/framework/*|*/system/system_ext/*|*/system/product/*|*/system/vendor/*) framework=1 ;;
      esac
      if grep -Eiq 'config_oemCredentialManagerDialogComponent|config_defaultCredentialManagerHybridService|CredentialManagerService' "$file"; then
        framework=1
      fi
      [ "$scanned_files" -lt "$CONFLICT_MAX_FILES" ] || { status=limit_reached; break; }
      now=$(epoch_seconds)
      if [ "$started" -gt 0 ] 2>/dev/null && [ "$now" -gt 0 ] 2>/dev/null \
        && [ $((now - started)) -ge "$CONFLICT_TOTAL_SECONDS" ]; then
        status=timeout
        break
      fi
    done < "$file_list"
    if [ "$writer" -eq 1 ]; then
      writer_count=$((writer_count + 1))
      writer_ids=$(append_private_id "$writer_ids" "$module_id")
    fi
    if [ "$gms" -eq 1 ]; then
      gms_count=$((gms_count + 1))
      gms_ids=$(append_private_id "$gms_ids" "$module_id")
    fi
    if [ "$hook" -eq 1 ]; then
      hook_count=$((hook_count + 1))
      hook_ids=$(append_private_id "$hook_ids" "$module_id")
    fi
    if [ "$framework" -eq 1 ]; then
      framework_count=$((framework_count + 1))
      framework_ids=$(append_private_id "$framework_ids" "$module_id")
    fi
    case "$status" in timeout|limit_reached) break ;; esac
  done < "$module_list"

  temporary_file="$CONFLICT_FILE.tmp.$$"
  {
    echo "scan_status=$status"
    echo "settings_writers=$writer_count"
    echo "gms_managers=$gms_count"
    echo "deep_hooks=$hook_count"
    echo "framework_overlays=$framework_count"
    echo "modules_scanned=$scanned_modules"
    echo "files_scanned=$scanned_files"
    echo "entries_skipped=$skipped_count"
    echo "scanned_at=$(epoch_seconds)"
  } > "$temporary_file" 2>/dev/null && mv "$temporary_file" "$CONFLICT_FILE" 2>/dev/null
  secure_state_file "$CONFLICT_FILE"
  rm -f "$module_list" "$file_list" 2>/dev/null || true

  cat "$CONFLICT_FILE" 2>/dev/null
  if [ "$report_mode" = private ]; then
    echo "settings_writer_ids=${writer_ids:-none}"
    echo "gms_manager_ids=${gms_ids:-none}"
    echo "deep_hook_ids=${hook_ids:-none}"
    echo "framework_overlay_ids=${framework_ids:-none}"
  fi
}

modules_identity() {
  local value
  [ -d "$MODULES_ROOT" ] || { echo unavailable; return; }
  value=$(stat -c '%Y' "$MODULES_ROOT" 2>/dev/null || stat -f '%m' "$MODULES_ROOT" 2>/dev/null)
  case "$value" in ''|*[!0-9]*) echo unknown ;; *) echo "$value" ;; esac
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

users_identity() {
  list_users | tr '\n' ',' | sed 's/,$//'
}

platform_identity() {
  local incremental display
  incremental=$(getprop_safe ro.build.version.incremental)
  display=$(getprop_safe ro.build.display.id)
  sanitize_event_value "$(platform_api)|$(hyperos_major)|$(build_stability)|$incremental|$display"
}

gms_version_identity() {
  local user="${1:-0}" out version path checksum
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package list packages \
    --show-versioncode --user "$user" "$GMS_PKG" 2>/dev/null || true)
  version=$(printf '%s\n' "$out" | sed -n \
    's/.*versionCode[:=][[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1)
  if [ -n "$version" ]; then
    echo "versionCode:$version"
    return
  fi
  path=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" pm path --user "$user" "$GMS_PKG" 2>/dev/null \
    | head -n 1)
  if [ -n "$path" ]; then
    checksum=$(printf '%s' "$path" | cksum 2>/dev/null | awk '{ print $1 ":" $2 }')
    [ -n "$checksum" ] && echo "pathCksum:$checksum" || echo path:present
  else
    echo unavailable
  fi
}

settings_get_once() {
  local user="$1" key="$2" out rc
  out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings get --user "$user" secure "$key" 2>&1)
  rc=$?
  [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out" || return 1
  printf '%s\n' "$out" | tr -d '\r'
}

set_quick_check_result() {
  local result="$1" reason="$2" temporary_file
  temporary_file="$QUICK_CHECK_FILE.tmp.$$"
  {
    echo "result=$result"
    echo "reason=$reason"
    echo "checked_at=$(epoch_seconds)"
  } > "$temporary_file" 2>/dev/null && mv "$temporary_file" "$QUICK_CHECK_FILE" 2>/dev/null || true
  secure_state_file "$QUICK_CHECK_FILE"
}

quick_check_reason() {
  plan_value "$QUICK_CHECK_FILE" reason 2>/dev/null || echo unavailable
}

save_route_fingerprint() {
  local mode="$1" users first_user temporary_file user key value
  users=$(users_identity)
  first_user=${users%%,*}
  [ -n "$first_user" ] || first_user=0
  temporary_file="$FINGERPRINT_FILE.tmp.$$"
  {
    echo "schema=1"
    echo "mode=$mode"
    echo "platform=$(platform_identity)"
    echo "users=$users"
    echo "gms=$(gms_version_identity "$first_user")"
    echo "modules=$(modules_identity)"
    echo "saved_at=$(epoch_seconds)"
    for user in $(printf '%s\n' "$users" | tr ',' ' '); do
      for key in credential_service credential_service_primary autofill_service; do
        value=$(settings_get_once "$user" "$key" 2>/dev/null || echo '<unreadable>')
        value=$(printf '%s' "$value" | tr '\r\n' '__')
        echo "user_${user}_${key}=$value"
      done
    done
  } > "$temporary_file" 2>/dev/null && mv "$temporary_file" "$FINGERPRINT_FILE" 2>/dev/null \
    || return 1
  secure_state_file "$FINGERPRINT_FILE"
  return 0
}

quick_route_check() {
  local mode="$1" expected actual users first_user user state_file key
  [ -f "$FINGERPRINT_FILE" ] || { set_quick_check_result changed fingerprint_missing; return 1; }
  expected=$(plan_value "$FINGERPRINT_FILE" schema)
  [ "$expected" = 1 ] || { set_quick_check_result changed fingerprint_schema; return 1; }
  expected=$(plan_value "$FINGERPRINT_FILE" mode)
  [ "$expected" = "$mode" ] || { set_quick_check_result changed mode_changed; return 1; }
  expected=$(plan_value "$FINGERPRINT_FILE" platform)
  actual=$(platform_identity)
  [ "$expected" = "$actual" ] || { set_quick_check_result changed platform_changed; return 1; }
  users=$(users_identity)
  expected=$(plan_value "$FINGERPRINT_FILE" users)
  [ "$expected" = "$users" ] || { set_quick_check_result changed users_changed; return 1; }
  first_user=${users%%,*}
  [ -n "$first_user" ] || first_user=0
  expected=$(plan_value "$FINGERPRINT_FILE" gms)
  actual=$(gms_version_identity "$first_user")
  [ "$expected" = "$actual" ] || { set_quick_check_result changed gms_changed; return 1; }
  expected=$(plan_value "$FINGERPRINT_FILE" modules)
  actual=$(modules_identity)
  [ "$expected" = "$actual" ] || { set_quick_check_result changed modules_changed; return 1; }

  for user in $(printf '%s\n' "$users" | tr ',' ' '); do
    for key in credential_service credential_service_primary autofill_service; do
      expected=$(plan_value "$FINGERPRINT_FILE" "user_${user}_${key}")
      actual=$(settings_get_once "$user" "$key" 2>/dev/null || echo '<unreadable>')
      [ "$actual" = "$expected" ] \
        || { set_quick_check_result drift "route_drift:$user:$key"; return 1; }
    done
  done
  set_quick_check_result stable fingerprint_match
  return 0
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
  dump=""
  if [ "${HYPERGPM_ALLOW_PACKAGE_DUMP:-1}" = 1 ]; then
    dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)
  fi

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
    /^[[:space:]]*(Service|ResolveInfo) #[0-9]+:/ { matched=0 }
    {
      compact=$0
      gsub(/[[:space:]]/, "", compact)
    }
    index(compact, "name=" cls) || index(compact, "name:" cls) { matched=1 }
    matched && (index(compact, "permission=" permission) || index(compact, "permission:" permission)) {
      valid=1
    }
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
  [ "${HYPERGPM_ALLOW_PACKAGE_DUMP:-1}" = 1 ] || { echo failed; return; }
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
  dump=""
  if [ "${HYPERGPM_ALLOW_PACKAGE_DUMP:-1}" = 1 ]; then
    dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)
  fi
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
  secure_state_file "$backup_file"
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

stored_failure_class() {
  local value
  value=$(sed -n '1p' "$STATE_DIR/last-failure-class" 2>/dev/null)
  case "$value" in
    settings_rewritten_by_oem|deep_oem_hybrid_restriction|no_create_options|settings_binder_transient|unknown|none) echo "$value" ;;
    *) echo none ;;
  esac
}

failure_evidence_for_route() {
  if [ "${HYPERGPM_BOOT_PATH:-0}" = 1 ]; then
    stored_failure_class
  else
    classify_recent_failure
  fi
}

plan_google_route_for_user() {
  local user="$1" mode="$2" plan_file="$3"
  local providers primary current current_primary current_autofill newlist provider kept removed
  local state autofill_provider autofill_mode autofill_action autofill_reason action reason failure_evidence
  local credential_action primary_action credential_key_state primary_key_state autofill_key_state
  local ownership_file owned_credential owned_primary owned_autofill owned_credential_managed
  local owned_primary_managed owned_autofill_managed

  : > "$plan_file" 2>/dev/null || return 1
  state=$(user_state "$user")
  action=apply
  reason=capability_gated_settings_route
  providers=""
  primary=""
  current=""
  current_primary=""
  current_autofill=""
  newlist=""
  removed=""
  autofill_provider=""
  credential_action=set
  primary_action=set
  autofill_action=preserve
  credential_key_state=present
  primary_key_state=present
  autofill_key_state=present
  autofill_reason=credential_and_autofill_are_independent

  if [ "$state" = "locked" ]; then
    action=skip
    reason=user_locked
  elif [ "$mode" = "observe-only" ]; then
    action=observe
    reason=compatibility_mode_observe_only
  fi

  if [ "$action" = apply ]; then
    if [ "$(credential_feature_state)" = false ]; then
      action=blocked
      reason=credential_feature_unavailable
    fi
    failure_evidence=$(failure_evidence_for_route)
    if [ "$failure_evidence" = deep_oem_hybrid_restriction ]; then
      action=blocked
      reason=deep_oem_hybrid_restriction
    fi
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
    write_plan_value "$plan_file" credential_service_action unsupported
    write_plan_value "$plan_file" credential_service_state user_locked
    write_plan_value "$plan_file" current_credential_service_primary ""
    write_plan_value "$plan_file" target_credential_service_primary ""
    write_plan_value "$plan_file" credential_service_primary_action unsupported
    write_plan_value "$plan_file" credential_service_primary_state user_locked
    write_plan_value "$plan_file" removed_providers ""
    write_plan_value "$plan_file" kept_provider_count 0
    write_plan_value "$plan_file" current_autofill_service ""
    write_plan_value "$plan_file" gms_autofill_provider ""
    write_plan_value "$plan_file" autofill_action unsupported
    write_plan_value "$plan_file" autofill_service_state user_locked
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
    credential_action=unsupported
    credential_key_state=unsupported
    current=""
  }
  current_primary=$(settings_get "$user" credential_service_primary) || {
    primary_action=unsupported
    primary_key_state=unsupported
    current_primary=""
  }
  current_autofill=$(settings_get "$user" autofill_service) || {
    autofill_action=unsupported
    autofill_key_state=unsupported
    autofill_reason=setting_not_supported_or_not_readable
    current_autofill=""
  }
  [ "$current" = "null" ] && current=""
  [ "$current_primary" = "null" ] && current_primary=""
  [ "$current_autofill" = "null" ] && current_autofill=""

  if [ "$action" = apply ]; then
    if [ "$credential_action" = unsupported ] && [ "$primary_action" = unsupported ]; then
      action=blocked
      reason=credential_settings_unsupported
    elif [ "$mode" != force ] \
      && { [ "$credential_action" = unsupported ] || [ "$primary_action" = unsupported ]; }; then
      action=blocked
      reason=required_credential_setting_unsupported
    elif [ "$credential_action" = unsupported ] || [ "$primary_action" = unsupported ]; then
      reason=force_partial_setting_support
    fi
  fi

  ownership_file="$STATE_DIR/user_${user}.last"
  if [ "$action" = "apply" ] && [ "$mode" = "conservative" ] && [ -f "$ownership_file" ]; then
    owned_credential=$(plan_value "$ownership_file" credential_service)
    owned_primary=$(plan_value "$ownership_file" credential_service_primary)
    owned_autofill=$(plan_value "$ownership_file" autofill_service)
    owned_credential_managed=$(plan_value "$ownership_file" credential_service_managed)
    owned_primary_managed=$(plan_value "$ownership_file" credential_service_primary_managed)
    owned_autofill_managed=$(plan_value "$ownership_file" autofill_managed)
    [ -n "$owned_credential_managed" ] || owned_credential_managed=1
    [ -n "$owned_primary_managed" ] || owned_primary_managed=1
    if { [ "$owned_credential_managed" = 1 ] && [ "$current" != "$owned_credential" ]; } \
      || { [ "$owned_primary_managed" = 1 ] && [ "$current_primary" != "$owned_primary" ]; } \
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
  if [ "$autofill_action" != unsupported ] && [ "$action" = "apply" ] \
    && [ -n "$autofill_provider" ] && [ "$autofill_mode" != "false" ]; then
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
  write_plan_value "$plan_file" credential_service_action "$credential_action"
  write_plan_value "$plan_file" credential_service_state "$credential_key_state"
  write_plan_value "$plan_file" current_credential_service_primary "$current_primary"
  write_plan_value "$plan_file" target_credential_service_primary "$primary"
  write_plan_value "$plan_file" credential_service_primary_action "$primary_action"
  write_plan_value "$plan_file" credential_service_primary_state "$primary_key_state"
  write_plan_value "$plan_file" removed_providers "$removed"
  write_plan_value "$plan_file" kept_provider_count "$kept"
  write_plan_value "$plan_file" current_autofill_service "$current_autofill"
  write_plan_value "$plan_file" gms_autofill_provider "$autofill_provider"
  write_plan_value "$plan_file" autofill_action "$autofill_action"
  write_plan_value "$plan_file" autofill_service_state "$autofill_key_state"
  write_plan_value "$plan_file" autofill_reason "$autofill_reason"
}

print_route_plan_file() {
  local plan_file="$1"
  echo "user=$(plan_value "$plan_file" user) mode=$(plan_value "$plan_file" mode) action=$(plan_value "$plan_file" action)"
  echo "reason=$(plan_value "$plan_file" reason)"
  echo "credential_service action=$(plan_value "$plan_file" credential_service_action) state=$(plan_value "$plan_file" credential_service_state): $(plan_value "$plan_file" current_credential_service) -> $(plan_value "$plan_file" target_credential_service)"
  echo "credential_service_primary action=$(plan_value "$plan_file" credential_service_primary_action) state=$(plan_value "$plan_file" credential_service_primary_state): $(plan_value "$plan_file" current_credential_service_primary) -> $(plan_value "$plan_file" target_credential_service_primary)"
  echo "removed_providers=$(plan_value "$plan_file" removed_providers)"
  echo "autofill_action=$(plan_value "$plan_file" autofill_action) state=$(plan_value "$plan_file" autofill_service_state) reason=$(plan_value "$plan_file" autofill_reason)"
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
  local user="$1" credential_managed="$2" credential="$3" primary_managed="$4" primary="$5"
  local autofill_managed="$6" autofill="$7" reason="${8:-route_apply}"
  local state_file="$STATE_DIR/user_${user}.last" temporary_file
  temporary_file="$state_file.tmp.$$"
  {
    echo "credential_service_managed=$credential_managed"
    echo "credential_service=$credential"
    echo "credential_service_primary_managed=$primary_managed"
    echo "credential_service_primary=$primary"
    echo "autofill_managed=$autofill_managed"
    echo "autofill_service=$autofill"
    echo "applied_at=$(epoch_seconds)"
    echo "reason=$(sanitize_event_value "$reason")"
  } > "$temporary_file" 2>/dev/null || return 1
  mv "$temporary_file" "$state_file" 2>/dev/null || return 1
  secure_state_file "$state_file"
  printf '%s\n' none > "$STATE_DIR/last-failure-class" 2>/dev/null || true
  rm -f "$STATE_DIR/ownership-conflict" 2>/dev/null || true
  return 0
}

ownership_key_managed() {
  local state_file="$1" key="$2" managed
  case "$key" in
    autofill_service)
      managed=$(plan_value "$state_file" autofill_managed)
      [ -n "$managed" ] || managed=0
      ;;
    *)
      managed=$(plan_value "$state_file" "${key}_managed")
      [ -n "$managed" ] || managed=1
      ;;
  esac
  case "$managed" in 1) return 0 ;; *) return 1 ;; esac
}

restore_settings() {
  local restore_mode="${1:-safe}" user backup_file state_file key original last current user_rc rc
  case "$restore_mode" in safe|force) ;; *) return 2 ;; esac
  rc=0
  for user in $(list_users); do
    backup_file="$BACKUP_DIR/user_${user}.secure"
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$backup_file" ] && [ -f "$state_file" ] || continue
    user_rc=0
    for key in credential_service credential_service_primary autofill_service; do
      ownership_key_managed "$state_file" "$key" || continue
      original=$(plan_value "$backup_file" "$key")
      last=$(plan_value "$state_file" "$key")
      current=$(settings_get "$user" "$key") || { user_rc=1; continue; }
      if [ "$current" != "$last" ]; then
        if [ "$restore_mode" = safe ]; then
          log_event restore secure "$user" 1 0 skipped_user_changed "$key"
          continue
        fi
        log_event restore secure "$user" 1 0 force_user_changed "$key"
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
  rm -f "$FINGERPRINT_FILE" "$QUICK_CHECK_FILE" 2>/dev/null || true
  return "$rc"
}

acquire_apply_lock() {
  local owner_type="${1:-${HYPERGPM_LOCK_OWNER:-manual}}" max_wait="${2:-${HYPERGPM_LOCK_WAIT_SECONDS:-5}}"
  local attempt owner existing_type started waited
  case "$max_wait" in ''|*[!0-9]*) max_wait=5 ;; esac
  attempt=1
  started=$(epoch_seconds)
  while [ "$attempt" -le $((max_wait + 1)) ]; do
    if mkdir "$APPLY_LOCK_DIR" 2>/dev/null; then
      echo "$$" > "$APPLY_LOCK_DIR/pid" 2>/dev/null || true
      echo "$(sanitize_event_value "$owner_type")" > "$APPLY_LOCK_DIR/type" 2>/dev/null || true
      echo "$started" > "$APPLY_LOCK_DIR/started_at" 2>/dev/null || true
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
    [ "$attempt" -le $((max_wait + 1)) ] || break
    sleep 1
  done
  existing_type=$(cat "$APPLY_LOCK_DIR/type" 2>/dev/null)
  waited=$(epoch_seconds)
  if [ "$started" -gt 0 ] 2>/dev/null && [ "$waited" -ge "$started" ] 2>/dev/null; then
    waited=$((waited - started))
  else
    waited=$max_wait
  fi
  log "apply lock busy; owner_type=${existing_type:-unknown} waited=${waited}s"
  [ "${HYPERGPM_EXPLAIN:-0}" = 1 ] \
    && echo "apply lock busy: owner=${existing_type:-unknown}, waited=${waited}s" >&2
  return 1
}

release_apply_lock() {
  rm -rf "$APPLY_LOCK_DIR" 2>/dev/null || true
}

apply_google_route_for_user() {
  local user="$1" mode="$2" plan_file action current current_primary current_autofill
  local target target_primary credential_action primary_action autofill_action target_autofill
  local changed_credential changed_primary changed_autofill partial_rc

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
      printf '%s\n' "$(plan_value "$plan_file" reason)" > "$STATE_DIR/last-apply-class" 2>/dev/null || true
      rm -f "$plan_file" 2>/dev/null || true
      return 1
      ;;
  esac

  current=$(plan_value "$plan_file" current_credential_service)
  current_primary=$(plan_value "$plan_file" current_credential_service_primary)
  current_autofill=$(plan_value "$plan_file" current_autofill_service)
  target=$(plan_value "$plan_file" target_credential_service)
  target_primary=$(plan_value "$plan_file" target_credential_service_primary)
  credential_action=$(plan_value "$plan_file" credential_service_action)
  primary_action=$(plan_value "$plan_file" credential_service_primary_action)
  autofill_action=$(plan_value "$plan_file" autofill_action)
  target_autofill=$(plan_value "$plan_file" gms_autofill_provider)
  changed_credential=0
  changed_primary=0
  changed_autofill=0
  partial_rc=0

  if { [ "$credential_action" != set ] || [ "$current" = "$target" ]; } \
    && { [ "$primary_action" != set ] || [ "$current_primary" = "$target_primary" ]; } \
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

  if [ "$credential_action" = set ] && [ "$current" != "$target" ]; then
    if settings_put "$user" credential_service "$target"; then
      changed_credential=1
    else
      restore_key_value "$user" credential_service "$current" || true
      if [ "$mode" = force ]; then
        credential_action=unsupported
        partial_rc=1
        log_event route_apply secure "$user" 1 1 unsupported_setting credential_service
      else
        rm -f "$plan_file" 2>/dev/null || true
        printf '%s\n' settings_binder_transient > "$STATE_DIR/last-apply-class" 2>/dev/null || true
        return 1
      fi
    fi
  fi
  if [ "$primary_action" = set ] && [ "$current_primary" != "$target_primary" ]; then
    if settings_put "$user" credential_service_primary "$target_primary"; then
      changed_primary=1
    else
      restore_key_value "$user" credential_service_primary "$current_primary" || true
      if [ "$mode" = force ]; then
        primary_action=unsupported
        partial_rc=1
        log_event route_apply secure "$user" 1 1 unsupported_setting credential_service_primary
      else
        [ "$changed_credential" -eq 1 ] && restore_key_value "$user" credential_service "$current" || true
        rm -f "$plan_file" 2>/dev/null || true
        printf '%s\n' settings_binder_transient > "$STATE_DIR/last-apply-class" 2>/dev/null || true
        return 1
      fi
    fi
  fi
  if [ "$autofill_action" = "set" ] && [ "$current_autofill" != "$target_autofill" ]; then
    if settings_put "$user" autofill_service "$target_autofill"; then
      changed_autofill=1
    else
      restore_key_value "$user" autofill_service "$current_autofill" || true
      autofill_action=unsupported
      partial_rc=1
      log_event route_apply secure "$user" 1 1 unsupported_setting autofill_service
    fi
  fi

  if ! record_route_ownership "$user" \
    "$([ "$credential_action" = set ] && echo 1 || echo 0)" "$target" \
    "$([ "$primary_action" = set ] && echo 1 || echo 0)" "$target_primary" \
    "$([ "$autofill_action" = set ] && echo 1 || echo 0)" "$target_autofill" "$mode"; then
    [ "$changed_autofill" -eq 1 ] && restore_key_value "$user" autofill_service "$current_autofill" || true
    [ "$changed_primary" -eq 1 ] && restore_key_value "$user" credential_service_primary "$current_primary" || true
    [ "$changed_credential" -eq 1 ] && restore_key_value "$user" credential_service "$current" || true
    rm -f "$plan_file" 2>/dev/null || true
    return 1
  fi

  if [ "$partial_rc" -eq 0 ]; then
    printf '%s\n' none > "$STATE_DIR/last-apply-class" 2>/dev/null || true
    log_event route_apply secure "$user" 1 0 ok "writes=$((changed_credential + changed_primary + changed_autofill))"
  else
    log_event route_apply secure "$user" 1 1 partial "writes=$((changed_credential + changed_primary + changed_autofill))"
  fi
  rm -f "$plan_file" 2>/dev/null || true
  return "$partial_rc"
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

apply_google_route_under_lock() {
  local explicit="$1" mode="$2" rc quick_reason level temporary_file
  if quick_route_check "$mode"; then
    log_event route_apply fingerprint all 1 0 stable fingerprint_match
    return 0
  fi
  quick_reason=$(quick_check_reason)
  if [ "${HYPERGPM_BOOT_PATH:-0}" = 1 ]; then
    case "$quick_reason" in
      route_drift:*)
        temporary_file="$STATE_DIR/ownership-conflict.tmp.$$"
        {
          echo "state=detected"
          echo "reason=$quick_reason"
          echo "detected_at=$(epoch_seconds)"
        } > "$temporary_file" 2>/dev/null \
          && mv "$temporary_file" "$STATE_DIR/ownership-conflict" 2>/dev/null || true
        secure_state_file "$STATE_DIR/ownership-conflict"
        log_event route_apply ownership all 1 0 stopped "$quick_reason"
        return 0
        ;;
    esac
  fi

  if [ "${HYPERGPM_SKIP_CONFLICT_REFRESH:-0}" != 1 ]; then
    scan_module_conflicts public >/dev/null 2>&1 || true
  fi
  level=$(conflict_level)
  if [ -z "$explicit" ] && [ "$level" = ownership_unclear ]; then
    mode=observe-only
    log_event route_apply conflict all 1 0 downgraded ownership_unclear
    [ "${HYPERGPM_EXPLAIN:-0}" = 1 ] \
      && echo "conflict guard: automatic mode downgraded to observe-only" >&2
  fi

  apply_google_route_locked "$mode"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    save_route_fingerprint "$mode" || {
      log_event route_apply fingerprint all 1 1 failed save_failed
      return 1
    }
  fi
  return "$rc"
}

apply_google_route() {
  local explicit="${1:-}" mode rc owner
  mode=$(requested_mode "$explicit")
  [ "$mode" != "invalid" ] || {
    log_event route_apply policy all 1 2 invalid_mode "$explicit"
    return 2
  }
  owner=${HYPERGPM_LOCK_OWNER:-manual}
  acquire_apply_lock "$owner" || return 1
  apply_google_route_under_lock "$explicit" "$mode"
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
  local source="${1:-boot}" marker_file="$STATE_DIR/boot-apply" boot_id previous mode rc class attempt
  local HYPERGPM_BOOT_PATH=1 HYPERGPM_ALLOW_PACKAGE_DUMP=0 HYPERGPM_LOCK_OWNER="$source"
  boot_id=$(current_boot_id)
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  if [ "$boot_id" != "unknown" ] && [ "$previous" = "$boot_id" ]; then
    log_event boot_apply lifecycle all 1 0 skipped_already_attempted "$source"
    return 0
  fi

  acquire_apply_lock "$source" 5 || return 1
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  if [ "$boot_id" != "unknown" ] && [ "$previous" = "$boot_id" ]; then
    release_apply_lock
    return 0
  fi
  mode=$(requested_mode "")
  attempt=1
  apply_google_route_under_lock "" "$mode"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    class=$(sed -n '1p' "$STATE_DIR/last-apply-class" 2>/dev/null)
    case "$class" in
      provider_missing_or_invalid|settings_binder_transient)
        sleep 5
        HYPERGPM_SKIP_CONFLICT_REFRESH=1
        attempt=2
        apply_google_route_under_lock "" "$mode"
        rc=$?
        ;;
    esac
  fi
  {
    echo "boot_id=$boot_id"
    echo "source=$source"
    echo "mode=$mode"
    echo "result=$rc"
    echo "attempts=$attempt"
    echo "finished_at=$(epoch_seconds)"
  } > "$marker_file.tmp.$$" 2>/dev/null && mv "$marker_file.tmp.$$" "$marker_file" 2>/dev/null || true
  secure_state_file "$marker_file"
  release_apply_lock
  log_event boot_apply lifecycle all "$attempt" "$rc" attempted "$source:$mode"
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
  local user state_file key expected actual rc
  rc=0
  for user in $(list_users); do
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$state_file" ] || continue
    for key in credential_service credential_service_primary autofill_service; do
      ownership_key_managed "$state_file" "$key" || continue
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

verify_owned_routes_once() {
  local source="${1:-boot}" marker_file="$STATE_DIR/boot-verify" boot_id previous apply_result quick_result rc
  boot_id=$(current_boot_id)
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  [ "$boot_id" = unknown ] || [ "$previous" != "$boot_id" ] || return 0
  apply_result=$(plan_value "$STATE_DIR/boot-apply" result 2>/dev/null || echo unknown)
  quick_result=$(plan_value "$QUICK_CHECK_FILE" result 2>/dev/null || echo unknown)
  if [ "$apply_result" = 0 ] || [ "$quick_result" = stable ]; then
    rc=0
  else
    verify_owned_routes
    rc=$?
  fi
  {
    echo "boot_id=$boot_id"
    echo "source=$source"
    echo "result=$rc"
    echo "finished_at=$(epoch_seconds)"
  } > "$marker_file.tmp.$$" 2>/dev/null && mv "$marker_file.tmp.$$" "$marker_file" 2>/dev/null || true
  secure_state_file "$marker_file"
  return "$rc"
}

capability_snapshot() {
  local user="${1:-0}" mode providers autofill secure_state failure stored_failure profile reason
  local profile_status stability credential_key_state primary_key_state autofill_key_state auto_apply
  mode=$(requested_mode "")
  providers=$(choose_gms_provider_list "$user")
  autofill=$(choose_gms_autofill_provider "$user")
  settings_get "$user" credential_service >/dev/null 2>&1 \
    && credential_key_state=present || credential_key_state=unsupported
  settings_get "$user" credential_service_primary >/dev/null 2>&1 \
    && primary_key_state=present || primary_key_state=unsupported
  settings_get "$user" autofill_service >/dev/null 2>&1 \
    && autofill_key_state=present || autofill_key_state=unsupported
  if [ "$credential_key_state:$primary_key_state:$autofill_key_state" = present:present:present ]; then
    if [ -f "$STATE_DIR/user_${user}.last" ]; then
      secure_state=writable
    else
      secure_state=present
    fi
  elif [ "$credential_key_state" = present ] || [ "$primary_key_state" = present ] \
    || [ "$autofill_key_state" = present ]; then
    secure_state=partial
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
  profile=$(platform_profile_id)
  profile_status=$(platform_profile_status)
  stability=$(build_stability)
  auto_apply=$(platform_profile_field auto_apply 2>/dev/null || echo false)
  case "$mode" in
    observe-only) reason=$(compatibility_reason) ;;
    conservative)
      if [ "$auto_apply" = true ]; then
        reason=stage1_foundation_profile
      else
        reason=user_or_policy_explicit_conservative
      fi
      ;;
    force) reason=user_or_policy_explicit_force ;;
  esac
  echo "platform_api=$(platform_api)"
  echo "hyperos_major=$(hyperos_major)"
  echo "region=$(device_region)"
  echo "build_stability=$stability"
  echo "profile=$profile"
  echo "profile_status=$profile_status"
  echo "user_state=$(user_state "$user")"
  echo "gms_state=$(gms_state "$user")"
  echo "credential_feature=$(credential_feature_state)"
  echo "provider_query=$(provider_query_state "$user")"
  echo "secure_keys=$secure_state"
  echo "credential_service_key=$credential_key_state"
  echo "credential_service_primary_key=$primary_key_state"
  echo "autofill_service_key=$autofill_key_state"
  echo "gms_credential_provider=${providers%%:*}"
  echo "gms_autofill_provider=$autofill"
  echo "oem_dialog_resource=$(framework_component_resource_state "$user" config_oemCredentialManagerDialogComponent)"
  echo "hybrid_service_resource=$(framework_component_resource_state "$user" config_defaultCredentialManagerHybridService)"
  echo "credential_autofill_resource=$(framework_component_resource_state "$user" config_defaultCredentialManagerAutofillService)"
  echo "default_provider_resource=$(framework_provider_array_state "$user" config_enabledCredentialProviderService)"
  echo "primary_provider_resource=$(framework_provider_array_state "$user" config_primaryCredentialProviderService)"
  case "$failure" in
    deep_oem_hybrid_restriction) echo "oem_hybrid=detected" ;;
    unknown) echo "oem_hybrid=unknown" ;;
    *) echo "oem_hybrid=not_detected" ;;
  esac
  echo "failure_class=$failure"
  echo "compat_mode=$mode"
  echo "compat_reason=$reason"
  echo "quick_check=$(plan_value "$QUICK_CHECK_FILE" result 2>/dev/null || echo unavailable)"
  echo "quick_check_reason=$(quick_check_reason)"
  echo "conflict_scan=$(cached_conflict_value scan_status)"
  echo "conflict_level=$(conflict_level)"
  echo "conflict_settings_writers=$(cached_conflict_value settings_writers)"
  echo "conflict_gms_managers=$(cached_conflict_value gms_managers)"
  echo "conflict_deep_hooks=$(cached_conflict_value deep_hooks)"
  echo "conflict_framework_overlays=$(cached_conflict_value framework_overlays)"
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

  report_progress "bounded module conflict scan"
  {
    echo "=== Module conflict summary ==="
    scan_module_conflicts "$report_mode" 2>/dev/null || echo "scan_status=failed"
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
  local settings_rc browser_rc
  run_with_timeout 4 am start -a android.settings.CREDENTIAL_PROVIDER >/dev/null 2>&1
  settings_rc=$?
  log_event open activity all 1 "$settings_rc" credential_provider_settings android.settings.CREDENTIAL_PROVIDER
  sleep 1
  run_with_timeout 4 am start -a android.intent.action.VIEW \
    -d 'https://myaccount.google.com/signinoptions/passkeys' -p "$CHROME_PKG" >/dev/null 2>&1
  browser_rc=$?
  if [ "$browser_rc" -ne 0 ]; then
    run_with_timeout 4 am start -a android.intent.action.VIEW \
      -d 'https://myaccount.google.com/signinoptions/passkeys' >/dev/null 2>&1
    browser_rc=$?
  fi
  log_event open activity all 1 "$browser_rc" google_passkey_page android.intent.action.VIEW
  if [ "$settings_rc" -ne 0 ] && [ "$browser_rc" -ne 0 ]; then
    echo "Could not open settings automatically; open Passwords, passkeys and autofill manually." >&2
    return 1
  fi
  return 0
}
