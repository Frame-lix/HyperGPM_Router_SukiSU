#!/bin/sh
set -u

TEST_DIR=$(CDPATH= cd -- "${0%/*}" 2>/dev/null && pwd)
PROJECT_DIR=${TEST_DIR%/*}
TEST_TMP=$(mktemp -d "${TMPDIR:-/tmp}/hypergpm-test.XXXXXX") || exit 1
trap 'rm -rf "$TEST_TMP"' EXIT INT TERM

HYPERGPM_DATA_DIR=$TEST_TMP/data
MODDIR=$PROJECT_DIR
export HYPERGPM_DATA_DIR MODDIR

. "$PROJECT_DIR/common.sh"

FAIL_ONCE_KEY=""
FAIL_ALWAYS_KEY=""
TIMEOUT_TARGET=""
QUERY_FAIL_ONCE=0

state_file() {
  echo "$TEST_TMP/setting-$1-$2"
}

set_state() {
  printf '%s' "$3" > "$(state_file "$1" "$2")"
}

get_state() {
  local file
  file=$(state_file "$1" "$2")
  if [ -f "$file" ]; then
    cat "$file"
  else
    echo null
  fi
}

cmd() {
  if [ "$1" = user ] && [ "$2" = list ]; then
    echo 'Users:'
    echo '  UserInfo{0:Owner:13} running'
    return 0
  fi

  if [ "$1" = package ] && [ "$2" = query-services ]; then
    if [ "$QUERY_FAIL_ONCE" -eq 1 ] && [ ! -f "$TEST_TMP/query-failed-once" ]; then
      : > "$TEST_TMP/query-failed-once"
      echo 'cmd: Failure calling service package: Failed transaction (2147483646)'
      return 1
    fi
    case " $* " in
      *' -p com.google.android.gms '*)
        echo 'com.google.android.gms/com.google.android.gms.auth.api.credentials.credman.service.PasswordAndPasskeyService'
        echo 'com.google.android.gms/.auth.api.credentials.credman.service.SecondaryCredentialProviderService'
        echo 'com.google.android.gms/.auth.api.credentials.credman.service.ThirdCredentialProviderService'
        echo 'com.google.android.gms/.auth.api.credentials.credman.service.FourthCredentialProviderService'
        echo 'com.google.android.gms/.auth.api.credentials.credman.service.FifthCredentialProviderService'
        ;;
      *)
        echo 'com.miui.contentcatcher/com.miui.credential.provider.XiaomiCredentialProviderService'
        ;;
    esac
    return 0
  fi

  return 1
}

pm() {
  case "$1" in
    path)
      echo "package:/data/app/$2/base.apk"
      ;;
    enable)
      echo 'Component state unchanged'
      ;;
    has-feature)
      echo true
      ;;
    *)
      return 1
      ;;
  esac
}

settings() {
  local operation="$1" user="$3" key="$5" value file failure_file
  file=$(state_file "$user" "$key")
  case "$operation" in
    get)
      get_state "$user" "$key"
      ;;
    put)
      value="$6"
      if [ "$key" = "$FAIL_ALWAYS_KEY" ]; then
        echo 'cmd: Failure calling service settings: Failed transaction (2147483646)'
        return 1
      fi
      if [ "$key" = "$FAIL_ONCE_KEY" ]; then
        failure_file="$TEST_TMP/failed-once-$key"
        if [ ! -f "$failure_file" ]; then
          : > "$failure_file"
          echo 'cmd: Failure calling service settings: Failed transaction (2147483646)'
          return 1
        fi
      fi
      printf '%s' "$value" > "$file"
      ;;
    delete)
      rm -f "$file"
      ;;
    *)
      return 1
      ;;
  esac
}

dumpsys() {
  case "$1:$2" in
    package:com.google.android.gms)
      echo 'com.google.android.gms.auth.api.credentials.credman.service.PasswordAndPasskeyService'
      echo 'android.service.credentials.CredentialProviderService'
      ;;
    package:*)
      echo 'credential autofill passkey settings'
      ;;
    credential:)
      echo 'CredentialManagerService: test state'
      ;;
  esac
}

timeout() {
  local seconds="$1" command="$2" subcommand="${3:-}"
  shift
  if [ "$command:$subcommand" = "$TIMEOUT_TARGET" ]; then
    echo 'partial output before timeout'
    return 124
  fi
  "$@"
}

sleep() { :; }
getprop() { echo test; }
logcat() { echo 'CredMan test log'; }
am() { :; }

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_equals() {
  [ "$1" = "$2" ] || fail "expected '$1', got '$2'"
}

assert_contains() {
  printf '%s\n' "$1" | grep -Fq "$2" || fail "missing '$2' in '$1'"
}

assert_not_contains() {
  if printf '%s\n' "$1" | grep -Fiq "$2"; then
    fail "unexpected '$2' in '$1'"
  fi
}

GPM='com.google.android.gms/.auth.api.credentials.credman.service.PasswordAndPasskeyService'
BITWARDEN='com.x8bit.bitwarden/.data.autofill.CredentialProviderService'
XIAOMI='com.miui.contentcatcher/com.miui.credential.provider.XiaomiCredentialProviderService'

set_state 0 credential_service "$XIAOMI:$BITWARDEN"
set_state 0 credential_service_primary "$XIAOMI"
set_state 0 autofill_service 'com.miui.securitycenter/.autofill.MiuiAutofillService'

original_ifs=$IFS
apply_google_route || fail 'normal apply failed'
assert_equals "$original_ifs" "$IFS"

enabled=$(get_state 0 credential_service)
assert_contains "$enabled" "$GPM"
assert_contains "$enabled" "$BITWARDEN"
assert_not_contains "$enabled" 'miui'
assert_equals "$GPM" "$(get_state 0 credential_service_primary)"
assert_equals "$GMS_AUTOFILL_COMPONENT" "$(get_state 0 autofill_service)"
[ "$(component_count "$(choose_gms_provider_list 0)")" -le "$MAX_GMS_PROVIDERS" ] \
  || fail 'GMS provider list exceeded its component limit'
[ ! -e "$DATA_DIR/discover.tmp" ] || fail 'shared discovery temp file was created'

set_state 0 credential_service "$XIAOMI"
set_state 0 credential_service_primary "$XIAOMI"
set_state 0 autofill_service 'com.miui.securitycenter/.autofill.MiuiAutofillService'
QUERY_FAIL_ONCE=1
FAIL_ONCE_KEY=credential_service_primary
apply_google_route || fail 'apply did not recover from transient Failed transaction errors'
assert_equals "$GPM" "$(get_state 0 credential_service_primary)"
QUERY_FAIL_ONCE=0
FAIL_ONCE_KEY=""

OLD_ENABLED='com.example.passwords/.CredentialProviderService'
OLD_PRIMARY='com.example.passwords/.CredentialProviderService'
OLD_AUTOFILL='com.example.passwords/.AutofillService'
set_state 0 credential_service "$OLD_ENABLED"
set_state 0 credential_service_primary "$OLD_PRIMARY"
set_state 0 autofill_service "$OLD_AUTOFILL"
FAIL_ALWAYS_KEY=autofill_service
if apply_google_route; then
  fail 'apply unexpectedly succeeded after permanent settings failure'
fi
assert_equals "$OLD_ENABLED" "$(get_state 0 credential_service)"
assert_equals "$OLD_PRIMARY" "$(get_state 0 credential_service_primary)"
assert_equals "$OLD_AUTOFILL" "$(get_state 0 autofill_service)"
FAIL_ALWAYS_KEY=""

TIMEOUT_TARGET='dumpsys:credential'
report_path=$(collect_report) || fail 'report collection failed'
[ -f "$report_path" ] || fail 'report file was not created'
grep -Fq '[timed out after 6s]' "$report_path" || fail 'report did not record command timeout'
if find "$LOG_DIR" -name '*.tmp' -print | grep -q .; then
  fail 'report left temporary files behind'
fi

echo 'PASS: routing retries, rollback, bounds, variable scope, and report timeout'
