#!/system/bin/sh
# Common functions for HyperGPM Router.
# Scope: restore Google Password Manager / GMS as Android Credential Manager provider on HyperOS CN where settings-based routing is available.

MODDIR=${MODDIR:-${0%/*}}
DATA_DIR=/data/adb/hypergpm-router
LOG_DIR=$DATA_DIR/logs
CONF_DIR=$DATA_DIR/conf
BACKUP_DIR=$DATA_DIR/backup
mkdir -p "$LOG_DIR" "$CONF_DIR" "$BACKUP_DIR" 2>/dev/null || true

GMS_PKG=com.google.android.gms
CHROME_PKG=com.android.chrome
XIAOMI_SECURITY=com.miui.securitycenter

# Known GMS components used by credential/autofill routing research.
GMS_PASSKEY_COMPONENT="$GMS_PKG/.auth.api.credentials.credman.service.PasswordAndPasskeyService"
GMS_REMOTE_COMPONENT="$GMS_PKG/.auth.api.credentials.credman.service.RemoteService"
GMS_UI_COMPONENT="$GMS_PKG/.identitycredentials.ui.CredentialChooserActivity"
GMS_AUTOFILL_COMPONENT="$GMS_PKG/.autofill.service.AutofillService"

now() { date '+%Y-%m-%d %H:%M:%S' 2>/dev/null || toybox date '+%Y-%m-%d %H:%M:%S'; }
log_file() { echo "$LOG_DIR/router.log"; }
log() { echo "[$(now)] $*" >> "$(log_file)"; }
println() { echo "$*"; log "$*"; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }
getprop_safe() { getprop "$1" 2>/dev/null | tr -d '\r'; }

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
  local user="$1" key="$2" out
  out=$(settings get --user "$user" secure "$key" 2>/dev/null)
  if [ $? -ne 0 ]; then out=$(settings get secure "$key" 2>/dev/null); fi
  echo "$out" | tr -d '\r'
}

settings_put() {
  local user="$1" key="$2" value="$3"
  settings put --user "$user" secure "$key" "$value" 2>>"$(log_file)" || settings put secure "$key" "$value" 2>>"$(log_file)"
}

settings_delete() {
  local user="$1" key="$2"
  settings delete --user "$user" secure "$key" 2>>"$(log_file)" || settings delete secure "$key" 2>>"$(log_file)"
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

flatten_gms_component() {
  # Convert com.google.android.gms/com.google.android.gms.X to com.google.android.gms/.X.
  sed 's#^com\.google\.android\.gms/com\.google\.android\.gms\.#com.google.android.gms/.#'
}

component_exists() {
  local comp="$1" pkg cls
  pkg=${comp%%/*}
  cls=${comp#*/}
  [ -z "$pkg" ] && return 1
  [ "$pkg" = "$comp" ] && return 1
  cmd package resolve-activity --user 0 -c android.intent.category.DEFAULT -a android.intent.action.MAIN -n "$comp" >/dev/null 2>&1 && return 0
  dumpsys package "$pkg" 2>/dev/null | grep -F "$cls" >/dev/null 2>&1
}

enable_component() {
  local comp="$1"
  [ -z "$comp" ] && return 0
  pm enable --user 0 "$comp" >/dev/null 2>&1 || pm enable "$comp" >/dev/null 2>&1 || true
}

gms_installed() {
  pm path "$GMS_PKG" >/dev/null 2>&1
}

discover_gms_credential_providers() {
  # Return flattened ComponentName candidates declaring android.service.credentials.CredentialProviderService.
  # It intentionally probes multiple Android command syntaxes because OEM builds vary.
  local tmp out
  tmp="$DATA_DIR/discover.tmp"
  : > "$tmp" 2>/dev/null || true
  cmd package query-services --user 0 -a android.service.credentials.CredentialProviderService "$GMS_PKG" >> "$tmp" 2>/dev/null || true
  cmd package query-services --user 0 -a android.service.credentials.CredentialProviderService >> "$tmp" 2>/dev/null || true
  dumpsys package "$GMS_PKG" >> "$tmp" 2>/dev/null || true

  # Extract service names around CredentialProviderService and known credman strings.
  out=$(cat "$tmp" 2>/dev/null \
    | grep -Ei 'CredentialProviderService|credman|identitycredentials|com\.google\.android\.gms/' \
    | grep -Eo 'com\.google\.android\.gms/[A-Za-z0-9_.$]+' \
    | sed 's/[),;:]$//' \
    | flatten_gms_component \
    | sort -u)
  rm -f "$tmp" 2>/dev/null || true
  echo "$out"
}

discover_xiaomi_credential_providers() {
  local tmp
  tmp="$DATA_DIR/discover_xiaomi.tmp"
  : > "$tmp" 2>/dev/null || true
  cmd package query-services --user 0 -a android.service.credentials.CredentialProviderService >> "$tmp" 2>/dev/null || true
  dumpsys package com.fido.asm >> "$tmp" 2>/dev/null || true
  dumpsys package com.miui.cloudservice >> "$tmp" 2>/dev/null || true
  cat "$tmp" 2>/dev/null \
    | grep -Ei 'CredentialProviderService|fido|passkey|credential|xiaomi|miui' \
    | grep -Eo '(com\.(fido|miui|xiaomi)[A-Za-z0-9_.-]*)/[A-Za-z0-9_.$]+' \
    | sed 's/[),;:]$//' \
    | sort -u
  rm -f "$tmp" 2>/dev/null || true
}

choose_gms_provider_list() {
  local providers list p
  gms_installed || { echo ""; return; }
  providers=$(discover_gms_credential_providers)
  list=""
  for p in $providers; do
    echo "$p" | grep -Eiq 'PasswordAndPasskeyService' || continue
    list=$(append_unique_component "$list" "$p")
  done
  if [ -z "$list" ] && component_exists "$GMS_PASSKEY_COMPONENT"; then
    list="$GMS_PASSKEY_COMPONENT"
  fi
  for p in $providers; do
    # Keep candidates that look like provider/credman service entries. UI Activity is not a provider.
    echo "$p" | grep -Eiq 'provider|credential|credman|identity' || continue
    echo "$p" | grep -Eiq 'ChooserActivity|RemoteService|GoogleIdService' && continue
    list=$(append_unique_component "$list" "$p")
  done
  # If GMS provider service is hidden from query on the ROM, use the known GMS passkey provider component.
  if [ -z "$list" ]; then
    list="$GMS_PASSKEY_COMPONENT"
  fi
  echo "$list"
}

backup_settings_once() {
  local user="$1" f="$BACKUP_DIR/user_${user}.secure"
  [ -f "$f" ] && return 0
  {
    echo "credential_service=$(settings_get "$user" credential_service)"
    echo "credential_service_primary=$(settings_get "$user" credential_service_primary)"
    echo "autofill_service=$(settings_get "$user" autofill_service)"
  } > "$f" 2>/dev/null || true
}

restore_settings() {
  local user f key val
  for user in $(list_users); do
    f="$BACKUP_DIR/user_${user}.secure"
    [ -f "$f" ] || continue
    while IFS='=' read -r key val; do
      case "$val" in
        ""|null) settings_delete "$user" "$key" ;;
        *) settings_put "$user" "$key" "$val" ;;
      esac
    done < "$f"
  done
}

apply_google_route() {
  local user providers current newlist
  providers=$(choose_gms_provider_list)
  if [ -z "$providers" ]; then
    log "No Google credential provider found; skip applying route"
    return 1
  fi
  enable_component "$GMS_REMOTE_COMPONENT"
  enable_component "$GMS_UI_COMPONENT"
  enable_component "$GMS_AUTOFILL_COMPONENT"

  for user in $(list_users); do
    backup_settings_once "$user"
    current=$(settings_get "$user" credential_service)
    [ "$current" = "null" ] && current=""
    newlist="$providers"
    # Keep enabled non-Xiaomi providers, but put Google first.
    IFS=":"
    for p in $current; do
      echo "$p" | grep -Eiq 'xiaomi|miui|fido\.asm|mipass|passkey' && continue
      echo "$p" | grep -Eiq 'google\.android\.gms' && continue
      newlist=$(append_unique_component "$newlist" "$p")
    done
    unset IFS
    settings_put "$user" credential_service "$newlist"
    settings_put "$user" credential_service_primary "$providers"
    settings_put "$user" autofill_service "$GMS_AUTOFILL_COMPONENT"
    log "user=$user credential_service=$newlist"
    log "user=$user credential_service_primary=$providers"
    log "user=$user autofill_service=$GMS_AUTOFILL_COMPONENT"
  done

  # Ask system services to refresh by bouncing Settings and SecurityCenter UI processes only.
  am force-stop com.android.settings >/dev/null 2>&1 || true
  am force-stop "$XIAOMI_SECURITY" >/dev/null 2>&1 || true
  cmd package compile -m speed-profile -f "$GMS_PKG" >/dev/null 2>&1 || true
}

show_status() {
  local user
  echo "=== Device ==="
  echo "brand=$(getprop_safe ro.product.brand) model=$(getprop_safe ro.product.model) device=$(getprop_safe ro.product.device) sdk=$(getprop_safe ro.build.version.sdk)"
  echo "mi.os=$(getprop_safe ro.mi.os.version.name) mod_device=$(getprop_safe ro.product.mod_device) build=$(getprop_safe ro.build.version.incremental)"
  echo ""
  echo "=== Google components ==="
  echo "gms installed: $(pm path "$GMS_PKG" 2>/dev/null | head -n 1)"
  echo "chrome installed: $(pm path "$CHROME_PKG" 2>/dev/null | head -n 1)"
  echo "discovered GMS providers:"
  discover_gms_credential_providers | sed 's/^/  /'
  echo "chosen provider list: $(choose_gms_provider_list)"
  echo ""
  echo "=== Xiaomi providers found ==="
  discover_xiaomi_credential_providers | sed 's/^/  /'
  echo ""
  echo "=== Secure settings ==="
  for user in $(list_users); do
    echo "-- user $user --"
    echo "credential_service=$(settings_get "$user" credential_service)"
    echo "credential_service_primary=$(settings_get "$user" credential_service_primary)"
    echo "autofill_service=$(settings_get "$user" autofill_service)"
  done
  echo ""
  echo "=== dumpsys credential summary ==="
  dumpsys credential 2>/dev/null | head -n 160 || true
}

collect_report() {
  local f ts roots
  ts=$(date '+%Y%m%d-%H%M%S' 2>/dev/null || echo now)
  f="$LOG_DIR/report-$ts.txt"
  {
    echo "HyperGPM Router report $ts"
    echo ""
    show_status
    echo ""
    echo "=== Features and system files ==="
    pm has-feature android.software.credentials 2>/dev/null || true
    roots="/system/etc /system_ext/etc /product/etc /vendor/etc /odm/etc"
    for r in $roots; do
      [ -d "$r" ] || continue
      echo "-- grep $r --"
      grep -RIlE 'credential_service|credential_service_primary|CredentialProviderService|passkey|fido|autofill_service' "$r" 2>/dev/null | head -n 80
    done
    echo ""
    echo "=== Package snippets: com.android.settings ==="
    dumpsys package com.android.settings 2>/dev/null | grep -Ei 'credentials|credential|autofill|passkey|default' | head -n 200 || true
    echo ""
    echo "=== Package snippets: com.miui.securitycenter ==="
    dumpsys package com.miui.securitycenter 2>/dev/null | grep -Ei 'credential|autofill|passkey|fido|settings' | head -n 200 || true
    echo ""
    echo "=== Package snippets: com.google.android.gms ==="
    dumpsys package "$GMS_PKG" 2>/dev/null | grep -Ei 'CredentialProviderService|credman|identitycredentials|CredentialChooser|autofill|RemoteService' | head -n 240 || true
    echo ""
    echo "=== Recent Credential logcat ==="
    logcat -d -t 2500 2>/dev/null | grep -Ei 'Credential|CredMan|CreateCredential|TYPE_NO_CREATE_OPTIONS|Remote entry|Provider|HyperPasskey|gms|FIDO|passkey' | tail -n 350 || true
  } > "$f" 2>&1
  echo "$f"
}

open_settings_pages() {
  am start -a android.settings.CREDENTIAL_PROVIDER >/dev/null 2>&1 || true
  sleep 1
  am start -a android.intent.action.VIEW -d 'https://myaccount.google.com/signinoptions/passkeys' "$CHROME_PKG" >/dev/null 2>&1 \
    || am start -a android.intent.action.VIEW -d 'https://myaccount.google.com/signinoptions/passkeys' >/dev/null 2>&1 || true
}
