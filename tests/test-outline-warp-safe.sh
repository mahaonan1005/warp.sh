#!/usr/bin/env bash
# Mock functions and sourced globals are intentionally invoked indirectly by the SUT.
# shellcheck disable=SC2034,SC2329

set -Eeuo pipefail

ROOT=$(cd -- "$(dirname -- "$0")/.." && pwd)
SCRIPT="$ROOT/warp-d12-safe.sh"

fail() {
  printf 'FAIL: %s\n' "$1" >&2
  return 1
}

assert_eq() {
  local expected actual message
  expected="$1"
  actual="$2"
  message="$3"
  [ "$actual" = "$expected" ] ||
    fail "$message (expected: [$expected], actual: [$actual])"
}

assert_file_contains() {
  grep -Fq -- "$2" "$1" || fail "missing expected string [$2] in $1"
}

assert_file_missing() {
  if grep -Fq -- "$2" "$1"; then
    fail "unexpected string [$2] in $1"
  fi
}

assert_empty_file() {
  [ ! -s "$1" ] || {
    printf 'Unexpected calls in %s:\n' "$1" >&2
    sed 's/^/  /' "$1" >&2
    fail "$2"
  }
}

[ -f "$SCRIPT" ] || fail "required release artifact is missing: $SCRIPT"
bash -n "$SCRIPT"

SOURCE_PROBE=$(bash -c '
  set -Eeuo pipefail
  source "$1"
  declare -F main >/dev/null
  printf source-ok
' bash "$SCRIPT")
assert_eq "source-ok" "$SOURCE_PROBE" "the release script must be safely sourceable"

# The runtime path is calculated so the same test works from any checkout path.
# shellcheck source=/dev/null
source "$SCRIPT"

SUITE_TMP=$(mktemp -d)
SUITE_PID=$BASHPID
TEST_TOTAL=0
TEST_PASSED=0

cleanup_suite() {
  [ "$BASHPID" -eq "$SUITE_PID" ] || return 0
  cleanup_sensitive_temps
  rm -rf -- "$SUITE_TMP"
}
trap cleanup_suite EXIT

run_test() {
  local name test_function rc
  name="$1"
  test_function="$2"
  TEST_TOTAL=$((TEST_TOTAL + 1))

  set +e
  (
    set -Eeuo pipefail
    trap cleanup_sensitive_temps EXIT
    "$test_function"
  )
  rc=$?
  set -e

  if [ "$rc" -eq 0 ]; then
    TEST_PASSED=$((TEST_PASSED + 1))
    printf 'PASS: %s\n' "$name"
  else
    printf 'FAIL: %s (exit %s)\n' "$name" "$rc" >&2
  fi
}

test_static_contract() {
  local case_dir help_output plan_output
  case_dir=$(mktemp -d "$SUITE_TMP/static.XXXXXX")
  help_output="$case_dir/help"
  plan_output="$case_dir/plan"

  bash "$SCRIPT" help >"$help_output" 2>&1
  bash "$SCRIPT" plan >"$plan_output" 2>&1

  assert_file_contains "$help_output" "install --yes"
  assert_file_contains "$help_output" "confirm --yes"
  assert_file_contains "$help_output" "Any start failure removes only owned WARP routes"
  assert_file_contains "$plan_output" "Plan only; no changes will be made."
  assert_file_contains "$plan_output" "Will not:"
  assert_file_contains "$plan_output" "change /etc/resolv.conf"

  assert_file_contains "$SCRIPT" 'WGCF_VERSION="2.2.32"'
  assert_file_contains "$SCRIPT" 'AllowedIPs = 0.0.0.0/0, ::/0'
  assert_file_contains "$SCRIPT" 'Table = off'
  assert_file_contains "$SCRIPT" 'FwMark = %s'
  assert_file_contains "$SCRIPT" 'PersistentKeepalive = 25'
  assert_file_contains "$SCRIPT" 'ManageForeignRoutingPolicyRules=no'
  assert_file_contains "$SCRIPT" 'ManageForeignRoutes=no'
  assert_file_contains "$SCRIPT" 'TimeoutStartSec=150'
  assert_file_contains "$SCRIPT" 'outline-warp-rollback-'
  file_has_managed_marker "$SCRIPT" || fail "release script is missing its exact ownership marker"
  ln -s "$SCRIPT" "$case_dir/script-link"
  if file_has_managed_marker "$case_dir/script-link"; then
    fail "a symbolic link must never satisfy the ownership marker check"
  fi

  assert_file_missing "$SCRIPT" 'chattr '
  assert_file_missing "$SCRIPT" 'curl -k'
  assert_file_missing "$SCRIPT" 'curl --insecure'
  assert_file_missing "$SCRIPT" 'wget '
  assert_file_missing "$SCRIPT" '| bash'
  assert_file_missing "$SCRIPT" 'nft flush ruleset'
  assert_file_missing "$SCRIPT" 'ip rule flush'
  assert_file_missing "$SCRIPT" 'iptables -F'

  VERSION="program-version-sentinel"
  die() { :; }
  require_supported_os
  assert_eq "program-version-sentinel" "$VERSION" \
    "OS detection must not overwrite the program VERSION"
}

test_multiline_address_merge() {
  local case_dir source_fixture prepared
  case_dir=$(mktemp -d "$SUITE_TMP/address.XXXXXX")
  source_fixture="$case_dir/source.conf"
  printf '%s\n' \
    '[Interface]' \
    'PrivateKey = fake-private-key' \
    'Address = 172.16.0.2/32' \
    'Address = 2606:4700:110:8f2a::2/128' \
    '' \
    '[Peer]' \
    'PublicKey = fake-peer-key' \
    'Endpoint = 162.159.192.1:2408' \
    'Address = 198.51.100.9/32' >"$source_fixture"

  generate_source_profile() {
    PROFILE_WORK_DIR="$case_dir/work"
    SOURCE_PROFILE="$PROFILE_WORK_DIR/wgcf-profile.conf"
    mkdir -p -- "$PROFILE_WORK_DIR"
    cp -- "$source_fixture" "$SOURCE_PROFILE"
  }

  wg-quick() {
    [ "$1" = "strip" ] && [ -s "$2" ] &&
      [[ "${2##*/}" =~ ^[a-zA-Z0-9_=+.-]{1,15}\.conf$ ]]
  }

  prepare_managed_profile
  prepared="$PREPARED_PROFILE"
  assert_eq "wgcf.conf" "${prepared##*/}" \
    "wg-quick requires a short interface-style .conf filename"
  assert_file_contains "$prepared" \
    'Address = 172.16.0.2/32, 2606:4700:110:8f2a::2/128'
  assert_eq "1" "$(grep -Fc 'Address = ' "$prepared")" \
    "prepared profile should contain one normalized Address line"
  assert_file_missing "$prepared" '198.51.100.9/32'
}

test_real_wg_quick_strip_path() {
  local case_dir source_fixture
  command -v wg-quick >/dev/null 2>&1 || return 0
  case_dir=$(mktemp -d "$SUITE_TMP/real-strip.XXXXXX")
  source_fixture="$case_dir/source.conf"
  printf '%s\n' \
    '[Interface]' \
    'PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=' \
    'Address = 172.16.0.2/32, 2606:4700:110:8f2a::2/128' \
    '[Peer]' \
    'PublicKey = BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB=' \
    'Endpoint = 162.159.192.1:2408' >"$source_fixture"
  PROFILE_SOURCE="$source_fixture"
  PROFILE_WORK_DIR=""
  SOURCE_PROFILE=""
  PREPARED_PROFILE=""

  prepare_managed_profile
  [ "${PREPARED_PROFILE##*/}" = "wgcf.conf" ] ||
    fail "prepared profile filename is not accepted as a WireGuard interface config"
  wg-quick strip "$PREPARED_PROFILE" >/dev/null
}

test_exact_native_device_match() {
  local case_dir rc
  case_dir=$(mktemp -d "$SUITE_TMP/device.XXXXXX")
  RUN_DIR="$case_dir/run"
  mkdir -p -- "$RUN_DIR"
  printf 'eth0\n' >"$RUN_DIR/dev4"
  printf '192.0.2.10/32\n' >"$RUN_DIR/native4"
  : >"$RUN_DIR/native6"

  ip() {
    case "$*" in
      '-4 route get 1.1.1.1 from 192.0.2.10')
        printf '1.1.1.1 from 192.0.2.10 dev eth0.100 src 192.0.2.10\n'
        ;;
      *) return 97 ;;
    esac
  }

  set +e
  check_native_return_routes >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "2" "$rc" "eth0.100 must not be accepted as eth0"
}

policy_mock_ip() {
  local args
  args="$*"
  case "$args" in
    '-N -4 rule show priority 11220')
      if [ "${MOCK_FAIL_QUERY4:-0}" -eq 1 ]; then
        return 71
      elif [ "${MOCK_FOREIGN4:-0}" -eq 1 ]; then
        printf '11220: from all fwmark 0x1234 lookup 999\n'
      elif [ "${MOCK_CAPTURE4:-0}" -eq 1 ]; then
        printf '11220: not from all fwmark 0xcab0 lookup 51888\n'
      fi
      ;;
    '-N -6 rule show priority 11220')
      if [ "${MOCK_CAPTURE6:-0}" -eq 1 ]; then
        printf '11220: not from all fwmark 0xcab0 lookup 51888\n'
      fi
      ;;
    '-N -4 rule show')
      if [ "${MOCK_FOREIGN4:-0}" -eq 1 ]; then
        printf '11220: from all fwmark 0x1234 lookup 999\n'
      fi
      ;;
    '-N -6 rule show')
      ;;
    '-4 rule delete priority 11220 not fwmark 51888 table 51888')
      printf '%s\n' "$args" >>"$MOCK_IP_LOG"
      if [ "${MOCK_FAIL_DELETE4:-0}" -eq 1 ]; then
        return 1
      fi
      MOCK_CAPTURE4=0
      ;;
    '-6 rule delete priority 11220 not fwmark 51888 table 51888')
      printf '%s\n' "$args" >>"$MOCK_IP_LOG"
      MOCK_CAPTURE6=0
      ;;
    '-4 route show table 51888 default'|'-6 route show table 51888 default')
      ;;
    '-4 route flush cache'|'-6 route flush cache')
      ;;
    *)
      # Other owned-rule queries are intentionally empty in these cases.
      ;;
  esac
}

make_policy_runtime() {
  local case_dir
  case_dir="$1"
  RUN_DIR="$case_dir/run"
  mkdir -p -- "$RUN_DIR"
  printf '1.0.0 test\n' >"$RUN_DIR/owned"
  : >"$RUN_DIR/rules4"
  : >"$RUN_DIR/rules6"
}

test_foreign_priority_is_preserved() {
  local case_dir rc
  case_dir=$(mktemp -d "$SUITE_TMP/foreign-rule.XXXXXX")
  make_policy_runtime "$case_dir"
  MOCK_IP_LOG="$case_dir/ip.log"
  : >"$MOCK_IP_LOG"
  MOCK_FOREIGN4=1
  MOCK_CAPTURE4=0
  MOCK_CAPTURE6=0
  MOCK_FAIL_DELETE4=0
  ip() { policy_mock_ip "$@"; }

  set +e
  policy_down >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "foreign reserved priority must keep cleanup unconfirmed"
  assert_empty_file "$MOCK_IP_LOG" "foreign priority 11220 was deleted"
  [ -f "$RUN_DIR/owned" ] || fail "ownership marker must remain while a reserved foreign rule exists"
}

test_rule_identity_never_crosses_lines() {
  ip() {
    case "$*" in
      '-N -4 rule show priority 11220')
        printf '%s\n' \
          '11220: not from all fwmark 0xcab0 lookup 999' \
          '11220: from all fwmark 0x1234 lookup 51888'
        ;;
      *) return 0 ;;
    esac
  }
  if fixed_rule_present -4 11220 capture; then
    fail "rule identity fragments from different lines were combined"
  fi
}

test_policy_down_deletes_capture_rules() {
  local case_dir
  case_dir=$(mktemp -d "$SUITE_TMP/policy-ok.XXXXXX")
  make_policy_runtime "$case_dir"
  MOCK_IP_LOG="$case_dir/ip.log"
  : >"$MOCK_IP_LOG"
  MOCK_FOREIGN4=0
  MOCK_CAPTURE4=1
  MOCK_CAPTURE6=1
  MOCK_FAIL_DELETE4=0
  ip() { policy_mock_ip "$@"; }

  policy_down
  assert_file_contains "$MOCK_IP_LOG" \
    '-4 rule delete priority 11220 not fwmark 51888 table 51888'
  assert_file_contains "$MOCK_IP_LOG" \
    '-6 rule delete priority 11220 not fwmark 51888 table 51888'
  assert_eq "0" "$MOCK_CAPTURE4" "IPv4 capture rule should be removed"
  assert_eq "0" "$MOCK_CAPTURE6" "IPv6 capture rule should be removed"
  [ ! -f "$RUN_DIR/owned" ] || fail "ownership marker should be removed after complete cleanup"
}

test_policy_down_failure_retains_ownership() {
  local case_dir rc
  case_dir=$(mktemp -d "$SUITE_TMP/policy-fail.XXXXXX")
  make_policy_runtime "$case_dir"
  MOCK_IP_LOG="$case_dir/ip.log"
  : >"$MOCK_IP_LOG"
  MOCK_FOREIGN4=0
  MOCK_CAPTURE4=1
  MOCK_CAPTURE6=1
  MOCK_FAIL_DELETE4=1
  ip() { policy_mock_ip "$@"; }

  set +e
  policy_down >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "policy_down must fail when an owned rule remains"
  [ -f "$RUN_DIR/owned" ] || fail "ownership marker must remain after incomplete cleanup"
  assert_eq "1" "$MOCK_CAPTURE4" "failed IPv4 deletion should remain observable"
  assert_eq "0" "$MOCK_CAPTURE6" "independent IPv6 cleanup should still run"
}

test_policy_query_failure_retains_ownership() {
  local case_dir rc
  case_dir=$(mktemp -d "$SUITE_TMP/policy-query-fail.XXXXXX")
  make_policy_runtime "$case_dir"
  MOCK_IP_LOG="$case_dir/ip.log"
  : >"$MOCK_IP_LOG"
  MOCK_FOREIGN4=0
  MOCK_CAPTURE4=0
  MOCK_CAPTURE6=0
  MOCK_FAIL_DELETE4=0
  MOCK_FAIL_QUERY4=1
  ip() { policy_mock_ip "$@"; }

  set +e
  policy_down >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "policy_down must fail when rule state cannot be read"
  [ -f "$RUN_DIR/owned" ] || fail "ownership marker must remain after a read failure"
  assert_empty_file "$MOCK_IP_LOG" "policy_down mutated state after a failed ownership query"
}

test_safe_down_without_ownership_is_read_only() {
  local case_dir mutation_log rc
  case_dir=$(mktemp -d "$SUITE_TMP/safe-foreign.XXXXXX")
  RUN_DIR="$case_dir/run"
  mkdir -p -- "$RUN_DIR"
  mutation_log="$case_dir/mutations.log"
  : >"$mutation_log"

  ip() {
    case "$*" in
      'link show wgcf') return 0 ;;
      *' delete '*) printf 'ip %s\n' "$*" >>"$mutation_log" ;;
      *) ;;
    esac
  }
  wg-quick() {
    printf 'wg-quick %s\n' "$*" >>"$mutation_log"
  }

  set +e
  safe_down >/dev/null 2>&1
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "unknown ownership must produce a nonzero teardown result"
  assert_empty_file "$mutation_log" "safe_down modified a foreign artifact without ownership"
}

test_yes_gate_precedes_all_changes() {
  local case_dir post_gate_log action rc
  case_dir=$(mktemp -d "$SUITE_TMP/yes-gate.XXXXXX")
  post_gate_log="$case_dir/post-gate.log"
  : >"$post_gate_log"
  ASSUME_YES=0

  require_root() { :; }
  require_supported_os() { :; }
  mutation_guard() {
    printf '%s\n' "$1" >>"$post_gate_log"
    exit 91
  }
  acquire_admin_lock() { mutation_guard acquire_admin_lock; }
  systemctl() { mutation_guard systemctl; }
  systemd-run() { mutation_guard systemd-run; }
  install() { mutation_guard install; }
  ip() { mutation_guard ip; }

  for action in install_action repair_action disable_action enable_action confirm_action uninstall_action; do
    : >"$post_gate_log"
    set +e
    (
      set -Eeuo pipefail
      "$action" >/dev/null 2>&1
    )
    rc=$?
    set -e
    [ "$rc" -ne 0 ] || fail "$action succeeded without --yes"
    assert_empty_file "$post_gate_log" "$action crossed the --yes gate"
  done
}

test_installer_source_guard_precedes_mutation() {
  local case_dir call_log rc
  case_dir=$(mktemp -d "$SUITE_TMP/source-preflight.XXXXXX")
  call_log="$case_dir/calls.log"
  : >"$call_log"
  ASSUME_YES=1

  require_root() { :; }
  validate_installer_source() { printf 'source-check\n' >>"$call_log"; exit 77; }
  require_supported_os() { printf 'os-check\n' >>"$call_log"; }
  acquire_admin_lock() { printf 'admin-lock\n' >>"$call_log"; }

  set +e
  ( install_action >/dev/null 2>&1 )
  rc=$?
  set -e
  assert_eq "77" "$rc" "invalid installer source should stop installation immediately"
  assert_eq "source-check" "$(cat "$call_log")" \
    "installer source validation must happen before any system preflight or mutation"
}

test_stale_candidate_refuses_service_start() {
  local case_dir mutation_log rc
  case_dir=$(mktemp -d "$SUITE_TMP/stale-candidate.XXXXXX")
  DATA_DIR="$case_dir/data"
  PENDING_ROLLBACK_FILE="$DATA_DIR/pending-rollback"
  mkdir -p -- "$DATA_DIR"
  printf 'outline-warp-rollback-123-456\n' >"$PENDING_ROLLBACK_FILE"
  mutation_log="$case_dir/mutations.log"
  : >"$mutation_log"

  systemd_unit_active() { return 1; }
  safe_down() { printf 'safe-down\n' >>"$mutation_log"; }
  assert_reserved_space_clear() { printf 'route-check\n' >>"$mutation_log"; }
  capture_native_state() { printf 'capture\n' >>"$mutation_log"; }

  set +e
  service_up >/dev/null 2>&1
  rc=$?
  set -e
  assert_eq "2" "$rc" "candidate without an active rollback timer must be refused"
  assert_empty_file "$mutation_log" "stale candidate touched routing state"
}

test_main_lock_dispatch() {
  local case_dir lock_log actual body action
  case_dir=$(mktemp -d "$SUITE_TMP/locks.XXXXXX")
  lock_log="$case_dir/locks.log"
  : >"$lock_log"

  require_root() { printf 'root\n' >>"$lock_log"; }
  acquire_runtime_lock() { printf 'runtime\n' >>"$lock_log"; }
  try_admin_lock() { printf 'admin-try\n' >>"$lock_log"; return 0; }
  service_up() { printf 'service-up\n' >>"$lock_log"; }
  service_down() { printf 'service-down\n' >>"$lock_log"; }
  health_monitor() { printf 'health\n' >>"$lock_log"; }

  main _service_up
  main _service_down
  main _health_monitor
  actual=$(cat "$lock_log")
  assert_eq $'root\nruntime\nservice-up\nroot\nruntime\nservice-down\nroot\nadmin-try\nhealth' \
    "$actual" "main must acquire the expected runtime/admin locks before dispatch"

  for action in install_action repair_action disable_action enable_action confirm_action uninstall_action; do
    body=$(declare -f "$action")
    case "$body" in
      *acquire_admin_lock*) ;;
      *) fail "$action is missing acquire_admin_lock" ;;
    esac
  done
}

run_test "static CLI and safety contract" test_static_contract
run_test "multi-line Interface Address merge" test_multiline_address_merge
run_test "real wg-quick accepts prepared profile path" test_real_wg_quick_strip_path
run_test "exact native device comparison" test_exact_native_device_match
run_test "foreign priority preservation" test_foreign_priority_is_preserved
run_test "rule identity stays within one numeric output line" test_rule_identity_never_crosses_lines
run_test "policy_down removes IPv4 and IPv6 capture rules" test_policy_down_deletes_capture_rules
run_test "policy_down failure retains ownership" test_policy_down_failure_retains_ownership
run_test "policy_down query failure retains ownership" test_policy_query_failure_retains_ownership
run_test "safe_down refuses unowned artifacts" test_safe_down_without_ownership_is_read_only
run_test "all six modifying actions require --yes before changes" test_yes_gate_precedes_all_changes
run_test "installer source guard runs before mutation" test_installer_source_guard_precedes_mutation
run_test "stale candidate cannot start after reboot" test_stale_candidate_refuses_service_start
run_test "main dispatches through admin/runtime locks" test_main_lock_dispatch

printf '%s/%s tests passed.\n' "$TEST_PASSED" "$TEST_TOTAL"
[ "$TEST_PASSED" -eq "$TEST_TOTAL" ]
