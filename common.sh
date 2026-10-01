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
umask 077
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

file_size() {
  stat -c '%s' "$1" 2>/dev/null || stat -f '%z' "$1" 2>/dev/null
}

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || toybox date '+%Y-%m-%d %H:%M:%S'; }
log_file() { echo "$LOG_DIR/router.log"; }

rotate_router_log() {
  local file size
  file=$(log_file)
  [ -f "$file" ] || return 0
  size=$(file_size "$file")
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
  local event
  event=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$@" | awk -F '\t' '
    { for (i=1; i<=7; i++) { gsub(/[\r\n ]/, "_", $i); $i=substr($i,1,200) }
      printf "event phase=%s category=%s user=%s attempt=%s rc=%s status=%s detail=%s", $1,$2,$3,$4,$5,$6,$7; exit }')
  log "$event"
}

getprop_safe() { getprop "$1" 2>/dev/null | tr -d '\r'; }

terminate_process_tree() {
  local pid="$1" child children stat line parent
  case "$pid" in ''|*[!0-9]*) return ;; esac
  # Stop parents before enumerating children: a stopped shell cannot launch
  # another settings writer between enumeration and termination.
  kill -STOP "$pid" 2>/dev/null || return 0
  children=''
  if [ -d /proc/self ]; then
    for stat in /proc/[0-9]*/stat; do
      IFS= read -r line < "$stat" 2>/dev/null || continue
      child=${line%% *}; line=${line##*) }; line=${line#* }
      parent=${line%% *}
      [ "$parent" != "$pid" ] || children="$children $child"
    done
  else
    children=$(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent {print $1}')
  fi
  for child in $children; do terminate_process_tree "$child"; done
  kill -KILL "$pid" 2>/dev/null || true
}

run_with_timeout() {
  (
    seconds=$1
    shift
    HYPERGPM_TIMEOUT_DIR=$(mktemp -d "${HYPERGPM_TIMEOUT_DIR:-$DATA_DIR}/command.XXXXXX") || exit 125
    export HYPERGPM_TIMEOUT_DIR
    HYPERGPM_TIMEOUT_CHILD='' HYPERGPM_TIMEOUT_WATCHDOG=''
    trap 'trap - EXIT INT TERM; [ -z "$HYPERGPM_TIMEOUT_CHILD" ] || terminate_process_tree "$HYPERGPM_TIMEOUT_CHILD"; [ -z "$HYPERGPM_TIMEOUT_WATCHDOG" ] || terminate_process_tree "$HYPERGPM_TIMEOUT_WATCHDOG"; rm -rf "$HYPERGPM_TIMEOUT_DIR"' EXIT
    trap 'exit 143' TERM
    trap 'exit 130' INT
    # File-size limits also bound diagnostics produced without newline breaks.
    (
      ulimit -f 1024 2>/dev/null || exit 125
      "$@"
    ) > "$HYPERGPM_TIMEOUT_DIR/out" 2> "$HYPERGPM_TIMEOUT_DIR/err" &
    HYPERGPM_TIMEOUT_CHILD=$!
    (
      command sleep "$seconds" &
      sleeper=$!
      trap 'kill "$sleeper" 2>/dev/null; wait "$sleeper" 2>/dev/null; exit 0' TERM INT
      : > "$HYPERGPM_TIMEOUT_DIR/timer-ready"
      wait "$sleeper" || exit 0
      : > "$HYPERGPM_TIMEOUT_DIR/expired"
      terminate_process_tree "$HYPERGPM_TIMEOUT_CHILD"
    ) &
    HYPERGPM_TIMEOUT_WATCHDOG=$!
    wait "$HYPERGPM_TIMEOUT_CHILD"
    rc=$?
    HYPERGPM_TIMEOUT_CHILD=''
    # A fast child can finish before the timer installs its signal handler.
    # Wait for that handshake so cancellation cannot orphan its sleep process.
    while [ ! -f "$HYPERGPM_TIMEOUT_DIR/timer-ready" ] && kill -0 "$HYPERGPM_TIMEOUT_WATCHDOG" 2>/dev/null; do
      command sleep 0.01
    done
    kill "$HYPERGPM_TIMEOUT_WATCHDOG" 2>/dev/null || true
    wait "$HYPERGPM_TIMEOUT_WATCHDOG" 2>/dev/null || true
    HYPERGPM_TIMEOUT_WATCHDOG=''
    [ ! -f "$HYPERGPM_TIMEOUT_DIR/expired" ] || rc=124
    cat "$HYPERGPM_TIMEOUT_DIR/out"
    cat "$HYPERGPM_TIMEOUT_DIR/err" >&2
    exit "$rc"
  )
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
  local line="$1" wanted="$2" field value found=0
  while :; do
    field=${line%%|*}
    case "$field" in "$wanted="*) value=${field#*=}; found=$((found + 1)) ;; esac
    case "$line" in *'|'*) line=${line#*|} ;; *) break ;; esac
  done
  [ "$found" -eq 1 ] || return 1
  printf '%s\n' "$value"
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
  writers=$(cached_conflict_value settings_writers)
  gms=$(cached_conflict_value gms_managers)
  hook=$(cached_conflict_value deep_hooks)
  case "$writers:$gms:$hook" in
    *[!0-9:]*|::) echo unknown ;;
    0:0:0) [ "$status" = ok ] && echo none || echo unknown ;;
    *) echo ownership_unclear ;;
  esac
}


scan_conflicts_worker() {
  local work="$1" module file size id flags category count=0 files=0 skipped=0 per status=ok
  local writers=0 managers=0 hooks=0 overlays=0 writer_ids='' manager_ids='' hook_ids='' overlay_ids=''
  if [ ! -d "$MODULES_ROOT" ]; then
    status=unavailable
    : > "$work/modules"
  else
    # Read one extra entry so truncation cannot be mistaken for completeness.
    find "$MODULES_ROOT" -mindepth 1 -maxdepth 1 -type d 2> "$work/find-errors" \
      | head -n $((CONFLICT_MAX_MODULES + 1)) > "$work/modules"
    [ ! -s "$work/find-errors" ] || status=incomplete
  fi
  while IFS= read -r module; do
    count=$((count + 1))
    [ "$count" -le "$CONFLICT_MAX_MODULES" ] || { status=limit_reached; break; }
    [ -d "$module" ] && [ -r "$module" ] || { status=incomplete; continue; }
    [ ! -L "$module" ] && [ ! -e "$module/disable" ] && [ ! -e "$module/remove" ] || continue
    id=${module##*/}
    [ "$id" != hypergpm-router ] || continue
    case "$id" in ''|*[!A-Za-z0-9._-]*) id=unidentified ;; esac
    {
      for file in module.prop service.sh boot-completed.sh post-fs-data.sh action.sh uninstall.sh common.sh system.prop sepolicy.rule; do
        [ ! -f "$module/$file" ] || printf '%s\n' "$module/$file"
      done
      for file in "$module/bin" "$module/system"; do
        [ ! -d "$file" ] || [ -L "$file" ] || find "$file" -maxdepth 3 -type f 2>> "$work/find-errors"
      done
    } | head -n $((CONFLICT_MAX_FILES_PER_MODULE + 1)) > "$work/files"
    [ ! -s "$work/find-errors" ] || status=incomplete
    per=0
    : > "$work/categories"
    while IFS= read -r file; do
      per=$((per + 1)); files=$((files + 1))
      if [ "$per" -gt "$CONFLICT_MAX_FILES_PER_MODULE" ] || [ "$files" -gt "$CONFLICT_MAX_FILES" ]; then
        status=limit_reached; break
      fi
      if [ -L "$file" ] || [ ! -r "$file" ]; then skipped=$((skipped + 1)); status=incomplete; continue; fi
      size=$(file_size "$file")
      case "$size" in ''|*[!0-9]*) skipped=$((skipped + 1)); status=incomplete; continue ;; esac
      if [ "$size" -gt "$CONFLICT_MAX_FILE_BYTES" ]; then skipped=$((skipped + 1)); status=incomplete; continue; fi
      # Bound content even if another process grows the file after stat.
      head -c "$CONFLICT_MAX_FILE_BYTES" "$file" | awk '
        { line=tolower($0)
          if (line ~ /credential_service|autofill_service/) setting=1
          if (line ~ /settings[[:space:]]+(put|delete|reset)/) write=1
          if (line ~ /com[.]google[.]android[.]gms/) gms=1
          if (line ~ /freeze|disable|suspend|denylist|detach|pm[[:space:]]/) manager=1
          if (line ~ /hyperpasskey|lsposed|xposed|zygisk|system_server|kpm/) hook=1
          if (line ~ /credential|passkey|credman|fido/) credential=1
          if (line ~ /config_oemcredentialmanagerdialogcomponent|config_defaultcredentialmanagerhybridservice|credentialmanagerservice/) overlay=1 }
        END { if(setting && write) print "writer"; if(gms && manager) print "manager"
          if(hook && credential) print "hook"; if(overlay) print "overlay" }' >> "$work/categories"
      case "$file" in */system/framework/*|*/system/system_ext/*|*/system/product/*|*/system/vendor/*) echo overlay >> "$work/categories" ;; esac
    done < "$work/files"
    for category in $(sort -u "$work/categories"); do
      case "$category" in
        writer) writers=$((writers + 1)); writer_ids="${writer_ids}${writer_ids:+,}$id" ;;
        manager) managers=$((managers + 1)); manager_ids="${manager_ids}${manager_ids:+,}$id" ;;
        hook) hooks=$((hooks + 1)); hook_ids="${hook_ids}${hook_ids:+,}$id" ;;
        overlay) overlays=$((overlays + 1)); overlay_ids="${overlay_ids}${overlay_ids:+,}$id" ;;
      esac
    done
    [ "$files" -le "$CONFLICT_MAX_FILES" ] || break
  done < "$work/modules"
  printf 'scan_status=%s\nsettings_writers=%s\ngms_managers=%s\ndeep_hooks=%s\nframework_overlays=%s\nmodules_scanned=%s\nfiles_scanned=%s\nentries_skipped=%s\n' \
    "$status" "$writers" "$managers" "$hooks" "$overlays" "$count" "$files" "$skipped" > "$work/summary"
  printf 'settings_writer_ids=%s\ngms_manager_ids=%s\ndeep_hook_ids=%s\nframework_overlay_ids=%s\n' \
    "${writer_ids:-none}" "${manager_ids:-none}" "${hook_ids:-none}" "${overlay_ids:-none}" > "$work/private"
}

scan_module_conflicts() {
  local report_mode="${1:-public}" work rc summary status
  case "$report_mode" in public|private) ;; *) return 2 ;; esac
  work=$(mktemp -d "${HYPERGPM_TIMEOUT_DIR:-$DATA_DIR}/scan.XXXXXX") || return 1
  run_with_timeout "$CONFLICT_TOTAL_SECONDS" scan_conflicts_worker "$work" >/dev/null 2>&1
  rc=$?
  if [ "$rc" -ne 0 ]; then
    case "$rc" in 124|137|143) status=timeout ;; *) status=failed ;; esac
    printf 'scan_status=%s\nsettings_writers=0\ngms_managers=0\ndeep_hooks=0\nframework_overlays=0\n' "$status" > "$work/summary"
  fi
  printf 'scanned_at=%s\nboot_id=%s\nmodules_identity=%s\n' \
    "$(epoch_seconds)" "$(current_boot_id)" "$(modules_identity)" >> "$work/summary"
  # Each reader receives its own scan, independent of a concurrent report.
  sed '/^boot_id=/d; /^modules_identity=/d' "$work/summary"
  if [ "$report_mode" = private ] && [ -f "$work/private" ]; then cat "$work/private"; fi
  mv "$work/summary" "$CONFLICT_FILE"
  rm -rf "$work"
  return "$rc"
}

modules_identity() {
  local value
  [ -d "$MODULES_ROOT" ] || { echo unavailable; return; }
  value=$(stat -c '%Y' "$MODULES_ROOT" 2>/dev/null || stat -f '%m' "$MODULES_ROOT" 2>/dev/null)
  case "$value" in ''|*[!0-9]*) echo unknown ;; *) echo "$value" ;; esac
}

list_users() {
  local out users
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd user list 2>/dev/null) || return 1
  output_has_transaction_error "$out" && return 1
  users=$(printf '%s\n' "$out" | sed -n 's/.*UserInfo{\([0-9][0-9]*\):.*/\1/p' | sort -nu)
  [ -n "$users" ] || return 1
  printf '%s\n' "$users"
}

platform_identity() {
  local incremental display
  incremental=$(getprop_safe ro.build.version.incremental)
  display=$(getprop_safe ro.build.display.id)
  sanitize_event_value "$(platform_api)|$(hyperos_major)|$(build_stability)|$incremental|$display"
}

gms_version_identity() {
  local user="${1:-0}" out
  out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package list packages \
    --show-versioncode --user "$user" "$GMS_PKG" 2>/dev/null) || return 1
  output_has_transaction_error "$out" && return 1
  printf '%s\n' "$out" | awk '/^package:com[.]google[.]android[.]gms[[:space:]]/ {
    for (i=2;i<=NF;i++) if ($i ~ /^versionCode[:=][0-9]+$/) { print $i; found=1; exit }
  } END { if (!found) exit 1 }'
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
  [ "$(plan_value "$QUICK_CHECK_FILE" result)" != "$result" ] \
    || [ "$(plan_value "$QUICK_CHECK_FILE" reason)" != "$reason" ] || return 0
  temporary_file=$(mktemp "$STATE_DIR/quick.XXXXXX") || return 1
  printf 'result=%s\nreason=%s\n' "$result" "$reason" > "$temporary_file"
  mv "$temporary_file" "$QUICK_CHECK_FILE"
}

quick_check_reason() {
  plan_value "$QUICK_CHECK_FILE" reason 2>/dev/null || echo unavailable
}

fingerprint_snapshot() {
  local mode="$1" user users key value version
  users=$(list_users) || return 1
  printf 'schema=2\nmode=%s\nplatform=%s\n' "$mode" "$(platform_identity)"
  echo "config=$(cksum "$MODDIR/module.prop" "$PROFILE_FILE" "$CONF_DIR/policy.conf" 2>/dev/null | awk '{print $1, $2}' | cksum)"
  echo "users=$(printf '%s' "$users" | tr '\n' ',')"
  echo "modules=$(modules_identity)"
  for user in $users; do
    [ "$(user_state "$user")" = unlocked ] || return 1
    version=$(gms_version_identity "$user") || return 1
    gms_package_disabled "$user" && return 1
    echo "gms_$user=$version"
    for key in credential_service credential_service_primary autofill_service; do
      value=$(settings_get_once "$user" "$key") || return 1
      case "$value" in *'
'*) return 1 ;; esac
      echo "user_${user}_$key=$value"
    done
  done
}

# Package replacement invalidates permission evidence via version identity. This
# targeted action query also detects per-user component disablement without dumps.
validate_cached_services() {
  local user users key value component action permission out
  users=$(list_users) || return 1
  for user in $users; do
    for key in credential_service autofill_service; do
      value=$(plan_value "$FINGERPRINT_FILE" "user_${user}_$key")
      action=$CREDENTIAL_PROVIDER_ACTION
      permission=$CREDENTIAL_PROVIDER_PERMISSION
      if [ "$key" = autofill_service ]; then action=$AUTOFILL_SERVICE_ACTION; permission=$AUTOFILL_SERVICE_PERMISSION; fi
      for component in $(printf '%s' "$value" | tr ':' ' '); do
        case "$component" in com.google.android.gms/*) ;; *) continue ;; esac
        out=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" cmd package query-services \
          --user "$user" -a "$action" -n "$component" 2>/dev/null) || return 1
        output_has_transaction_error "$out" && return 1
        service_permission_in_details "$out" "$component" "$permission" || return 1
      done
    done
  done
}

save_route_fingerprint() {
  local snapshot temporary_file
  snapshot=$(fingerprint_snapshot "$1") || { rm -f "$FINGERPRINT_FILE"; return 0; }
  temporary_file=$(mktemp "$STATE_DIR/fingerprint.XXXXXX") || return 1
  printf '%s\n' "$snapshot" > "$temporary_file"
  mv "$temporary_file" "$FINGERPRINT_FILE"
}

quick_route_check() {
  local mode="$1" snapshot user key expected actual
  [ -f "$FINGERPRINT_FILE" ] || { set_quick_check_result changed fingerprint_missing; return 1; }
  [ "$(plan_value "$FINGERPRINT_FILE" schema)" = 2 ] \
    || { set_quick_check_result changed fingerprint_schema; return 1; }
  snapshot=$(fingerprint_snapshot "$mode") \
    || { set_quick_check_result changed environment_unreadable_or_unavailable; return 1; }
  if [ "$snapshot" = "$(cat "$FINGERPRINT_FILE")" ] && validate_cached_services; then
    set_quick_check_result stable fingerprint_match
    return 0
  fi
  set_quick_check_result changed environment_or_route_changed
  return 1
}

settings_operation() {
  local operation="$1" user="$2" key="$3" value="${4:-}" attempt=1 out rc actual
  if [ "$operation" = put ]; then
    actual=$(settings_get "$user" "$key") || actual='__read_failed__'
    [ "$actual" != "$value" ] || return 0
  fi
  while [ "$attempt" -le 3 ]; do
    if [ "$operation" = put ]; then
      out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings put --user "$user" secure "$key" "$value" 2>&1)
    else
      out=$(run_with_timeout "$SETTINGS_TIMEOUT_SECONDS" settings "$operation" --user "$user" secure "$key" 2>&1)
    fi
    rc=$?
    if [ "$rc" -eq 0 ] && ! output_has_transaction_error "$out"; then
      if [ "$operation" = get ]; then printf '%s\n' "$out" | tr -d '\r'; return 0; fi
      actual=$(settings_get "$user" "$key") || actual='__read_failed__'
      if { [ "$operation" = put ] && [ "$actual" = "$value" ]; } \
        || { [ "$operation" = delete ] && { [ -z "$actual" ] || [ "$actual" = null ]; }; }; then
        log_event "settings_$operation" secure "$user" "$attempt" 0 ok "$key"
        return 0
      fi
    fi
    log_event "settings_$operation" secure "$user" "$attempt" "$rc" failed "$key:$(single_line_detail "$out")"
    attempt=$((attempt + 1))
    [ "$attempt" -gt 3 ] || sleep 1
  done
  return 1
}

settings_get() { settings_operation get "$@"; }
settings_put() { settings_operation put "$@"; }
settings_delete() { settings_operation delete "$@"; }

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
  if [ "${HYPERGPM_ALLOW_PACKAGE_DUMP:-1}" = 1 ] && {
    [ -z "$raw" ] || { [ -n "$standard" ] && [ -z "$standard_details" ]; } \
      || { [ -n "$system" ] && [ -z "$system_details" ]; }
  }; then
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
      || dump_declares_service "$dump" "$provider" "$CREDENTIAL_PROVIDER_ACTION" "$CREDENTIAL_PROVIDER_PERMISSION"; then
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

service_permission_in_details() {
  local details="$1" comp="$2" permission="$3" action="${4:-}" cls
  cls=${comp#*/}
  case "$cls" in .*) cls="${comp%%/*}${cls}" ;; esac
  printf '%s\n' "$details" | awk -v cls="$cls" -v permission="$permission" -v action="$action" '
    function finish() { if (matched && permitted && (action == "" || declared)) valid=1 }
    /^[[:space:]]*(Service|ResolveInfo) #[0-9]+:/ { finish(); matched=0; permitted=0; declared=0 }
    { compact=$0; gsub(/[[:space:]]/, "", compact)
      if (compact == "name=" cls || compact == "name:" cls) matched=1
      if (compact == "permission=" permission || compact == "permission:" permission) permitted=1
      if (compact == "action=" action || compact == "action:" action) declared=1 }
    END { finish(); exit(valid ? 0 : 1) }'
}

dump_declares_service() {
  service_permission_in_details "$1" "$2" "$4" "$3"
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
  if [ "${HYPERGPM_ALLOW_PACKAGE_DUMP:-1}" = 1 ] && { [ -z "$raw" ] || [ -z "$details" ]; }; then
    dump=$(run_with_timeout "$QUERY_TIMEOUT_SECONDS" dumpsys package "$GMS_PKG" 2>/dev/null || true)
  fi
  if [ -z "$raw" ] && dump_declares_service "$dump" "$GMS_AUTOFILL_COMPONENT" \
    "$AUTOFILL_SERVICE_ACTION" "$AUTOFILL_SERVICE_PERMISSION"; then
    raw=$GMS_AUTOFILL_COMPONENT
  fi
  for provider in $raw; do
    if service_permission_in_details "$details" "$provider" "$AUTOFILL_SERVICE_PERMISSION" \
      || dump_declares_service "$dump" "$provider" "$AUTOFILL_SERVICE_ACTION" "$AUTOFILL_SERVICE_PERMISSION"; then
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
  local plan="${5:-}" file="$BACKUP_DIR/user_${user}.secure" tmp key value state
  tmp=$(mktemp "$BACKUP_DIR/backup.XXXXXX") || return 1
  if [ -f "$file" ]; then cat "$file" > "$tmp"; else echo schema=2 > "$tmp"; fi
  for key in credential_service credential_service_primary autofill_service; do
    if [ -f "$file" ] && { [ "$(plan_value "$file" schema)" != 2 ] \
      || [ "$(plan_value "$file" "${key}_backed_up")" = 1 ]; }; then continue; fi
    [ -z "$plan" ] || [ "$(plan_value "$plan" "${key}_state")" != unsupported ] || continue
    case "$key" in
      credential_service) value=$credential_value ;;
      credential_service_primary) value=$primary_value ;;
      autofill_service) value=$autofill_value ;;
    esac
    printf '%s=%s\n%s_backed_up=1\n' "$key" "$value" "$key" >> "$tmp"
  done
  mv "$tmp" "$file"
}

plan_value() {
  local file="$1" key="$2" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "$key="*) printf '%s\n' "${line#*=}"; return 0 ;; esac
  done < "$file"
  return 1
}

write_plan_value() {
  local plan_file="$1" key="$2" value="$3"
  value=$(printf '%s' "$value" | tr '\r\n' '__')
  printf '%s=%s\n' "$key" "$value" >> "$plan_file"
}

is_oem_provider() {
  printf '%s\n' "$1" | grep -Eiq 'xiaomi|miui|com\.fido\.asm|mipass'
}

write_failure_class() {
  local tmp
  tmp=$(mktemp "$STATE_DIR/failure.XXXXXX") || return 1
  printf '%s\n' "$1" > "$tmp"
  mv "$tmp" "$STATE_DIR/last-failure-class"
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

  if [ "$state" != "unlocked" ]; then
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

  if [ "$state" != "unlocked" ]; then
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
    plan_file=$(mktemp "${HYPERGPM_TIMEOUT_DIR:-$DATA_DIR}/plan.XXXXXX" 2>/dev/null) || return 1
    if plan_google_route_for_user "$user" "$mode" "$plan_file"; then
      print_route_plan_file "$plan_file"
    else
      rc=1
    fi
    rm -f "$plan_file" 2>/dev/null || true
  done
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
    echo "transaction_id=$(plan_value "$STATE_DIR/user_${user}.txn" transaction_id 2>/dev/null || true)"
    echo "applied_at=$(epoch_seconds)"
    echo "reason=$(sanitize_event_value "$reason")"
  } > "$temporary_file" 2>/dev/null || return 1
  mv "$temporary_file" "$state_file" 2>/dev/null || return 1
  secure_state_file "$state_file"
  write_failure_class none 2>/dev/null || true
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
  local mode="${1:-safe}" rc
  case "$mode" in safe|force) ;; *) return 2 ;; esac
  acquire_apply_lock restore || return 1
  if recover_transactions; then
    # Persist intent before touching settings so interrupted restore does not
    # let automatic boot reclaim the route. An explicit apply resumes it.
    : > "$STATE_DIR/restore-paused"
    restore_settings_locked "$mode"
    rc=$?
  else
    rc=1
  fi
  release_apply_lock
  return "$rc"
}

restore_settings_locked() {
  local restore_mode="${1:-safe}" user backup_file state_file key original last current user_rc rc users
  case "$restore_mode" in safe|force) ;; *) return 2 ;; esac
  rc=0
  users=$(list_users) || return 1
  for user in $users; do
    [ "$(user_state "$user")" = unlocked ] || { rc=1; continue; }
    backup_file="$BACKUP_DIR/user_${user}.secure"
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$backup_file" ] && [ -f "$state_file" ] || continue
    user_rc=0
    for key in credential_service credential_service_primary autofill_service; do
      ownership_key_managed "$state_file" "$key" || continue
      if [ "$(plan_value "$backup_file" schema)" = 2 ] \
        && [ "$(plan_value "$backup_file" "${key}_backed_up")" != 1 ]; then continue; fi
      original=$(plan_value "$backup_file" "$key") || { user_rc=1; continue; }
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

current_pid() {
  local line
  if [ -r /proc/self/stat ]; then
    IFS= read -r line < /proc/self/stat
    HYPERGPM_CURRENT_PID=${line%% *}
  else
    local pid_file
    pid_file=$(mktemp "$DATA_DIR/pid.XXXXXX") || return 1
    sh -c 'echo "$PPID"' > "$pid_file"
    IFS= read -r HYPERGPM_CURRENT_PID < "$pid_file"
    rm -f "$pid_file"
  fi
}

process_identity() {
  local line
  case "$1" in ''|*[!0-9]*) return 1 ;; esac
  if [ -r "/proc/$1/stat" ]; then
    IFS= read -r line < "/proc/$1/stat" || return 1
    line=${line##*) }
    printf '%s\n' "$line" | awk '{ print $20 }'
  else
    ps -p "$1" -o lstart= 2>/dev/null
  fi
}

acquire_apply_lock() {
  local owner_type="${1:-manual}" max_wait="${2:-${HYPERGPM_LOCK_WAIT_SECONDS:-5}}"
  local attempt=0 owner identity recorded token pid claim live
  case "$max_wait" in ''|*[!0-9]*) max_wait=5 ;; esac
  [ "$max_wait" -le 30 ] || max_wait=30
  current_pid || return 1
  pid=$HYPERGPM_CURRENT_PID
  token=$(mktemp "$DATA_DIR/lock-claim.$pid.XXXXXX") || return 1
  process_identity "$pid" > "$token"
  while [ "$attempt" -le "$max_wait" ]; do
    if mkdir "$APPLY_LOCK_DIR" 2>/dev/null; then
      ln "$token" "$APPLY_LOCK_DIR/owner" || { rm -f "$token"; rmdir "$APPLY_LOCK_DIR"; return 1; }
      printf '%s\n' "$pid" > "$APPLY_LOCK_DIR/pid"
      process_identity "$pid" > "$APPLY_LOCK_DIR/identity"
      printf '%s\n' "$owner_type" > "$APPLY_LOCK_DIR/type"
      HYPERGPM_LOCK_TOKEN=$token
      return 0
    fi
    owner=$(cat "$APPLY_LOCK_DIR/pid" 2>/dev/null)
    recorded=$(cat "$APPLY_LOCK_DIR/identity" 2>/dev/null)
    identity=$(process_identity "$owner")
    # Claims exist before mkdir. A live initializing owner prevents reaping;
    # after a crash, an empty directory can be reclaimed without guessing age.
    if [ -z "$owner" ]; then
      live=0
      for claim in "$DATA_DIR"/lock-claim.*; do
        [ -f "$claim" ] && [ "$claim" != "$token" ] || continue
        owner=${claim##*/lock-claim.}; owner=${owner%%.*}
        if kill -0 "$owner" 2>/dev/null && [ "$(cat "$claim")" = "$(process_identity "$owner")" ]; then
          live=1
        else rm -f "$claim"; fi
      done
      owner=''
      if [ "$live" -eq 0 ] && mkdir "$APPLY_LOCK_DIR/reaper" 2>/dev/null; then
        if [ -s "$APPLY_LOCK_DIR/pid" ]; then
          rmdir "$APPLY_LOCK_DIR/reaper" 2>/dev/null || true
        else rm -rf "$APPLY_LOCK_DIR"; fi
      fi
    fi
    if [ -n "$owner" ] && { ! kill -0 "$owner" 2>/dev/null \
      || { [ -n "$recorded" ] && [ -n "$identity" ] && [ "$recorded" != "$identity" ]; }; }; then
      # One reaper owns this directory until it is removed. Never reap an
      # uninitialized lock: its creator could still be writing the owner record.
      if mkdir "$APPLY_LOCK_DIR/reaper" 2>/dev/null; then
        if [ "$(cat "$APPLY_LOCK_DIR/pid" 2>/dev/null)" = "$owner" ]; then
          for claim in "$DATA_DIR"/lock-claim."$owner".*; do
            [ ! "$claim" -ef "$APPLY_LOCK_DIR/owner" ] || rm -f "$claim"
          done
          rm -rf "$APPLY_LOCK_DIR"
        else
          rmdir "$APPLY_LOCK_DIR/reaper" 2>/dev/null || true
        fi
      fi
    fi
    attempt=$((attempt + 1))
    [ "$attempt" -gt "$max_wait" ] || sleep 1
  done
  rm -f "$token"
  log_event lock lifecycle all "$attempt" 1 busy "$owner_type"
  return 1
}

release_apply_lock() {
  if [ -n "${HYPERGPM_LOCK_TOKEN:-}" ] && [ "$HYPERGPM_LOCK_TOKEN" -ef "$APPLY_LOCK_DIR/owner" ]; then
    rm -rf "$APPLY_LOCK_DIR"
    rm -f "$HYPERGPM_LOCK_TOKEN"
  fi
  HYPERGPM_LOCK_TOKEN=''
}

recover_user_transaction() {
  local user="$1" journal="$STATE_DIR/user_${1}.txn" key before target actual rc=0
  [ -f "$journal" ] || return 0
  local transaction_id
  transaction_id=$(plan_value "$journal" transaction_id)
  if [ -n "$transaction_id" ] && [ "$transaction_id" = "$(plan_value "$STATE_DIR/user_${user}.last" transaction_id)" ]; then
    rm -f "$journal"
    return 0
  fi
  [ "$(user_state "$user")" = unlocked ] || return 1
  for key in autofill_service credential_service_primary credential_service; do
    before=$(plan_value "$journal" "${key}_before") || continue
    target=$(plan_value "$journal" "${key}_target") || { rc=1; continue; }
    actual=$(settings_get "$user" "$key") || { rc=1; continue; }
    if [ "$actual" = "$target" ]; then
      restore_key_value "$user" "$key" "$before" || rc=1
    fi
  done
  [ "$rc" -ne 0 ] || rm -f "$journal"
  return "$rc"
}

recover_transactions() {
  local file user rc=0
  for file in "$STATE_DIR"/user_*.txn; do
    [ -f "$file" ] || continue
    user=${file##*/user_}; user=${user%.txn}
    case "$user" in ''|*[!0-9]*) return 1 ;; esac
    recover_user_transaction "$user" || rc=1
  done
  return "$rc"
}

journal_key() {
  local user="$1" key="$2" before="$3" target="$4" tmp file="$STATE_DIR/user_${1}.txn"
  tmp=$(mktemp "$STATE_DIR/journal.XXXXXX") || return 1
  if [ -f "$file" ]; then cat "$file" > "$tmp"
  else printf 'transaction_id=%s\n' "${tmp##*/}" > "$tmp"; fi
  printf '%s_before=%s\n%s_target=%s\n' "$key" "$before" "$key" "$target" >> "$tmp"
  mv "$tmp" "$file"
}

apply_google_route_for_user() {
  local user="$1" mode="$2" plan action key before target rc=0 managed tmp old actual
  local credential_managed=0 primary_managed=0 autofill_managed=0 credential='' primary='' autofill='' completed=0
  plan=$(mktemp "${HYPERGPM_TIMEOUT_DIR:-$DATA_DIR}/plan.XXXXXX") || return 1
  plan_google_route_for_user "$user" "$mode" "$plan" || { rm -f "$plan"; return 1; }
  [ "${HYPERGPM_EXPLAIN:-0}" != 1 ] || print_route_plan_file "$plan" >&2
  action=$(plan_value "$plan" action)
  if [ "$action" != apply ]; then
    log_event route_plan secure "$user" 1 0 "$action" "$(plan_value "$plan" reason)"
    printf '%s\n' "$(plan_value "$plan" reason)" > "$STATE_DIR/last-apply-class"
    rm -f "$plan"
    [ "$action" != blocked ] || return 1
    return 2
  fi
  backup_settings_once "$user" "$(plan_value "$plan" current_credential_service)" \
    "$(plan_value "$plan" current_credential_service_primary)" \
    "$(plan_value "$plan" current_autofill_service)" "$plan" || { rm -f "$plan"; return 1; }
  old="$STATE_DIR/user_${user}.last"
  for key in credential_service credential_service_primary autofill_service; do
    action=$(plan_value "$plan" "${key}_action")
    before=$(plan_value "$plan" "current_$key")
    target=$(plan_value "$plan" "target_$key")
    if [ "$key" = autofill_service ]; then
      action=$(plan_value "$plan" autofill_action)
      target=$(plan_value "$plan" gms_autofill_provider)
    fi
    managed=0
    if [ -f "$old" ] && ownership_key_managed "$old" "$key" \
      && [ "$before" = "$(plan_value "$old" "$key")" ]; then managed=1; fi
    if [ "$action" = set ] && [ "$before" != "$target" ]; then
      if ! journal_key "$user" "$key" "$before" "$target"; then rc=1; break; fi
      if settings_put "$user" "$key" "$target"; then
        before=$target
        managed=1
      else
        rc=1
        # Roll back this key first. Keep the journal on failure for next entry.
        actual=$(settings_get "$user" "$key") || break
        if [ "$actual" = "$target" ]; then
          restore_key_value "$user" "$key" "$before" || break
        elif [ "$actual" != "$before" ]; then
          before=$actual
          managed=0
        fi
        if [ "$key" != autofill_service ] && [ "$mode" != force ]; then break; fi
        # The failed key was restored; remove its intent, preserving earlier keys.
        tmp=$(mktemp "$STATE_DIR/journal.XXXXXX") || break
        awk -v key="$key" 'index($0,key "_before=") != 1 && index($0,key "_target=") != 1' \
          "$STATE_DIR/user_${user}.txn" > "$tmp"
        mv "$tmp" "$STATE_DIR/user_${user}.txn"
      fi
    fi
    case "$key" in
      credential_service) credential_managed=$managed; credential=$before ;;
      credential_service_primary) primary_managed=$managed; primary=$before ;;
      autofill_service) autofill_managed=$managed; autofill=$before ;;
    esac
    completed=$((completed + 1))
  done
  if [ "$completed" -eq 3 ]; then
    if record_route_ownership "$user" "$credential_managed" "$credential" \
      "$primary_managed" "$primary" "$autofill_managed" "$autofill" "$mode"; then
      rm -f "$STATE_DIR/user_${user}.txn"
    else rc=1; recover_user_transaction "$user" || true; fi
  else
    recover_user_transaction "$user" || true
    rc=1
  fi
  [ "$rc" -eq 0 ] && action=none || action=settings_binder_transient
  printf '%s\n' "$action" > "$STATE_DIR/last-apply-class"
  log_event route_apply secure "$user" 1 "$rc" completed "$mode"
  rm -f "$plan"
  return "$rc"
}

apply_google_route_locked() {
  local mode="$1" user result rc=0 users complete=1
  users=$(list_users) || return 1
  for user in $users; do
    apply_google_route_for_user "$user" "$mode"
    result=$?
    [ "$result" -ne 1 ] || rc=1
    [ "$result" -eq 0 ] || complete=0
  done
  if [ "$rc" -eq 0 ] && [ "$complete" -eq 1 ] && [ "$mode" != observe-only ]; then
    save_route_fingerprint "$mode" || rc=1
    rm -f "$STATE_DIR/deferred-users"
  else
    rm -f "$FINGERPRINT_FILE"
    if [ "$complete" -eq 0 ] && [ "$mode" != observe-only ]; then : > "$STATE_DIR/deferred-users"; fi
  fi
  return "$rc"
}

apply_google_route_under_lock() {
  local explicit="$1" mode="$2" level now scanned boot previous
  recover_transactions || return 1
  if [ -f "$STATE_DIR/restore-paused" ] && [ -z "$explicit" ]; then
    set_quick_check_result paused restored_by_user
    return 0
  fi
  # Ownership is checked even when a different dependency invalidated the cache.
  if [ "${HYPERGPM_BOOT_PATH:-0}" = 1 ] && ! verify_owned_routes; then
    printf 'state=detected\nreason=owned_route_changed_or_unreadable\n' > "$STATE_DIR/ownership-conflict"
    set_quick_check_result drift owned_route_changed_or_unreadable
    return 0
  fi
  now=$(epoch_seconds)
  scanned=$(cached_conflict_value scanned_at)
  boot=$(current_boot_id)
  previous=$(cached_conflict_value boot_id)
  case "$scanned" in ''|*[!0-9]*) scanned=0 ;; esac
  if [ "${HYPERGPM_REFRESH_CONFLICT:-0}" = 1 ] || [ -n "$explicit" ] \
    || [ "$previous" != "$boot" ] || [ $((now - scanned)) -ge 60 ] \
    || [ "$(cached_conflict_value modules_identity)" != "$(modules_identity)" ]; then
    scan_module_conflicts public >/dev/null 2>&1 || true
  fi
  level=$(conflict_level)
  if [ -z "$explicit" ] && [ "$level" != none ]; then
    mode=observe-only
    log_event route_apply conflict all 1 0 downgraded "$level"
  fi
  if [ "$mode" != observe-only ] && [ "$level" = none ] && quick_route_check "$mode"; then
    return 0
  fi
  apply_google_route_locked "$mode"
  local rc=$?
  if [ "$rc" -eq 0 ] && [ -n "$explicit" ] && [ "$mode" != observe-only ]; then
    rm -f "$STATE_DIR/restore-paused"
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
  local user state_file key expected actual rc users
  rc=0
  users=$(list_users) || return 1
  for user in $users; do
    state_file="$STATE_DIR/user_${user}.last"
    [ -f "$state_file" ] || continue
    for key in credential_service credential_service_primary autofill_service; do
      ownership_key_managed "$state_file" "$key" || continue
      expected=$(plan_value "$state_file" "$key")
      actual=$(settings_get "$user" "$key") || { rc=1; continue; }
      if [ "$actual" != "$expected" ]; then
        log_event route_verify secure "$user" 1 1 settings_rewritten_by_oem "$key"
        write_failure_class settings_rewritten_by_oem 2>/dev/null || true
        rc=1
      fi
    done
  done
  [ "$rc" -ne 0 ] \
    || write_failure_class none 2>/dev/null \
    || true
  return "$rc"
}

verify_owned_routes_once() {
  local source="${1:-boot}" marker_file="$STATE_DIR/boot-verify" boot_id previous rc
  boot_id=$(current_boot_id)
  previous=$(plan_value "$marker_file" boot_id 2>/dev/null || true)
  [ "$boot_id" = unknown ] || [ "$previous" != "$boot_id" ] || return 0
  verify_owned_routes
  rc=$?
  printf 'boot_id=%s\nsource=%s\nresult=%s\n' "$boot_id" "$source" "$rc" > "$marker_file"
  return "$rc"
}

capability_snapshot() {
  local user="${1:-0}" mode providers autofill secure_state failure stored_failure profile reason
  local profile_status stability credential_key_state primary_key_state autofill_key_state auto_apply
  mode=$(requested_mode "")
  if [ "$#" -ge 3 ]; then
    providers=$2
    autofill=$3
  else
    providers=$(choose_gms_provider_list "$user")
    autofill=$(choose_gms_autofill_provider "$user")
  fi
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
  if ! gms_installed "$user"; then echo gms_state=missing
  elif gms_package_disabled "$user"; then echo gms_state=disabled
  elif [ -n "$providers" ]; then echo gms_state=ready
  else echo gms_state=visible; fi
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
    capability_snapshot "$user" "$providers" "$autofill"
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
  capture_report_filtered "$destination" "$summary" "$section_id" "$requested" '' "$line_limit" "$deadline" "$@"
}

capture_report_filtered() {
  local destination="$1" summary="$2" section_id="$3" requested="$4" pattern="$5" line_limit="$6" deadline="$7"
  shift 7
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
  if [ -n "$pattern" ]; then
    grep -Ei "$pattern" "$temporary_file" | head -n "$line_limit" >> "$destination" 2>/dev/null || true
  else
    head -n "$line_limit" "$temporary_file" >> "$destination" 2>/dev/null || true
  fi
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
  report_file=$(mktemp "$LOG_DIR/report-$report_mode-$timestamp-XXXXXX") || return 1
  mv "$report_file" "$report_file.txt" || return 1
  report_file="$report_file.txt"
  raw_file=$(mktemp "${HYPERGPM_TIMEOUT_DIR:-$DATA_DIR}/report.XXXXXX") || { rm -f "$report_file"; return 1; }
  summary_file="$raw_file.summary"
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
  capture_report_command "$raw_file" "$summary_file" status 12 260 "$deadline" show_status

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

  failure=$(classify_failure_text "$(tail -n 220 "$raw_file")")
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

# Entry-level budget includes discovery, backoff and a delayed read-only check.
boot_cycle() {
  local source="${1:-boot}" HYPERGPM_BOOT_PATH=1 HYPERGPM_ALLOW_PACKAGE_DUMP=0 mode
  apply_google_route_once_per_boot "$source" || true
  sleep 15
  if [ -f "$STATE_DIR/deferred-users" ] && [ ! -f "$STATE_DIR/restore-paused" ]; then
    mode=$(requested_mode '')
    if acquire_apply_lock "$source" 3; then
      apply_google_route_under_lock '' "$mode" || true
      release_apply_lock
    fi
  fi
  verify_owned_routes_once "$source"
}
