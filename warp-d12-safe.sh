#!/usr/bin/env bash
# Managed by outline-warp-safe
#
# Safe Cloudflare WARP WireGuard dual-stack egress for Debian 11/12 servers.
# Designed for public Outline servers: native-address replies stay on main,
# while new unbound outbound flows use WARP. Failure is fail-open to native.
#
# SPDX-License-Identifier: MIT

set -Eeuo pipefail
umask 077
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
IFS=$' \t\n'
unset CDPATH ENV BASH_ENV

PROGRAM="outline-warp-safe"
VERSION="1.0.0"
INTERFACE="wgcf"
WG_CONF="/etc/wireguard/wgcf.conf"
STATE_DIR="/etc/outline-warp-safe"
ACCOUNT_FILE="$STATE_DIR/wgcf-account.toml"
LIB_DIR="/usr/local/lib/outline-warp-safe"
WGCF_BIN="$LIB_DIR/wgcf"
INSTALL_PATH="/usr/local/sbin/outline-warp-safe"
RUN_DIR="/run/outline-warp-safe"
DATA_DIR="/var/lib/outline-warp-safe"
BACKUP_ROOT="/var/backups/outline-warp-safe"
NETWORKD_DROPIN="/etc/systemd/networkd.conf.d/90-outline-warp-safe.conf"
SERVICE_FILE="/etc/systemd/system/outline-warp.service"
HEALTH_SERVICE_FILE="/etc/systemd/system/outline-warp-health.service"
HEALTH_TIMER_FILE="/etc/systemd/system/outline-warp-health.timer"
WGCF_VERSION="2.2.32"
WGCF_AMD64_SHA256="2ff97f2201972ce582a424455d50a3719a380eef0cd1f3144f7779348e122a2c"
WGCF_ARM64_SHA256="21fe21d9f61db9b381d71200f6f59c7949e0bb455446edcb33dda6ad6a8fcf8f"
WARP_ENDPOINT="162.159.192.1:2408"
ROUTE_TABLE="51888"
FWMARK="51888"
TRACE_URL="https://www.cloudflare.com/cdn-cgi/trace"
HEALTH_FAILURE_FILE="$DATA_DIR/consecutive-failures"
PENDING_ROLLBACK_FILE="$DATA_DIR/pending-rollback"
ADMIN_LOCK="/run/lock/outline-warp-safe-admin.lock"
RUNTIME_LOCK="/run/lock/outline-warp-safe-runtime.lock"
ORIGINAL_PROFILE_POINTER="$STATE_DIR/original-profile-backup"
MANAGED_MARKER="# Managed by outline-warp-safe"
PROFILE_SOURCE=""
LATEST_BACKUP=""
PROFILE_WORK_DIR=""
SOURCE_PROFILE=""
PREPARED_PROFILE=""
INSTALLER_SOURCE=""
ASSUME_YES=0
PURGE_CREDENTIALS=0

cleanup_sensitive_temps() {
  local path
  for path in "$PROFILE_WORK_DIR" "$PREPARED_PROFILE"; do
    [ -n "$path" ] || continue
    case "$path" in
      /tmp/outline-warp-safe.*) rm -rf -- "$path" ;;
    esac
  done
}

trap cleanup_sensitive_temps EXIT

log() {
  printf '[%s] %s\n' "$1" "$2"
}

info() {
  log INFO "$1" >&2
}

warn() {
  log WARN "$1" >&2
}

die() {
  log ERROR "$1" >&2
  exit 1
}

usage() {
  cat <<'EOF'
outline-warp-safe 1.0.0

Usage:
  outline-warp-safe plan
  outline-warp-safe install --yes
  outline-warp-safe status
  outline-warp-safe check
  outline-warp-safe repair --yes
  outline-warp-safe disable --yes
  outline-warp-safe enable --yes
  outline-warp-safe confirm --yes
  outline-warp-safe uninstall --yes [--purge-project-account]

Safety model:
  - Debian 11/12 only; kernel WireGuard required.
  - Uses a pinned wgcf release with SHA-256 verification.
  - Does not replace /etc/resolv.conf or install openresolv.
  - Preserves replies sourced from native IPv4/IPv6 on table main.
  - Requires recent handshake, WARP IPv4/IPv6 trace, and native return routes.
  - Any start failure removes only owned WARP routes, then verifies teardown.
  - Install/enable/repair keep a 10-minute remote rollback until confirm.
  - Existing wgcf configuration is backed up before migration.
EOF
}

parse_args() {
  ACTION="help"
  if [ "$#" -gt 0 ]; then
    ACTION="$1"
    shift
  fi
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --yes)
        ASSUME_YES=1
        ;;
      --purge-project-account)
        PURGE_CREDENTIALS=1
        ;;
      -h|--help)
        ACTION="help"
        ;;
      *)
        die "Unknown option: $1"
        ;;
    esac
    shift
  done
}

require_root() {
  [ "$(id -u)" -eq 0 ] || die "Run this action as root."
}

require_yes() {
  [ "$ASSUME_YES" -eq 1 ] || die "This action changes the system. Review plan, then add --yes."
}

acquire_admin_lock() {
  command_exists flock || die "flock is required."
  exec 8>"$ADMIN_LOCK"
  flock -w 30 8 || die "Another outline-warp-safe administrative action is running."
}

try_admin_lock() {
  command_exists flock || return 1
  exec 8>"$ADMIN_LOCK"
  flock -n 8
}

acquire_runtime_lock() {
  command_exists flock || die "flock is required."
  exec 9>"$RUNTIME_LOCK"
  flock -w 30 9 || die "Another outline-warp-safe runtime action is running."
}

require_supported_os() {
  local detected_id detected_version
  [ -r /etc/os-release ] || die "/etc/os-release is missing."
  detected_id=$(awk -F= '$1=="ID" {value=substr($0, index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release)
  detected_version=$(awk -F= '$1=="VERSION_ID" {value=substr($0, index($0,"=")+1); gsub(/^"|"$/, "", value); print value; exit}' /etc/os-release)
  [ "$detected_id" = "debian" ] || die "Supported OS: Debian 11 or Debian 12."
  case "$detected_version" in
    11|12) ;;
    *) die "Supported OS: Debian 11 or Debian 12. Found: $detected_version" ;;
  esac
}

command_exists() {
  command -v "$1" >/dev/null 2>&1
}

systemd_unit_active() {
  systemctl is-active --quiet "$1" 2>/dev/null
}

systemd_unit_enabled() {
  systemctl is-enabled --quiet "$1" 2>/dev/null
}

systemd_unit_quiescent() {
  local state
  state=$(systemctl show "$1" --property=ActiveState --value 2>/dev/null) || return 1
  case "$state" in
    ''|inactive|failed) return 0 ;;
    *) return 1 ;;
  esac
}

print_plan() {
  cat <<EOF
Plan only; no changes will be made.

Target:
  Debian 11/12, interface $INTERFACE
  WARP dual-stack global egress
  Native-source replies forced to table main

Will create or manage:
  $WG_CONF
  $STATE_DIR
  $LIB_DIR
  $INSTALL_PATH
  $SERVICE_FILE
  $HEALTH_SERVICE_FILE
  $HEALTH_TIMER_FILE
  $NETWORKD_DROPIN only when systemd-networkd is active/enabled

Will not:
  change /etc/resolv.conf
  install openresolv or wireguard-go
  change Docker, Outline, Access Keys, AWS, DNS, or cloud firewalls
  remove shared apt packages during uninstall

Apply:
  sudo bash ./warp-d12-safe.sh install --yes

The first start is a 10-minute candidate. Verify a new SSH session and
Outline TCP/UDP externally, then run:
  sudo $PROGRAM confirm --yes
EOF
}

check_conflicting_warp() {
  if systemd_unit_active warp-svc.service || systemd_unit_enabled warp-svc.service; then
    die "warp-svc is active or enabled. Disable the official WARP client before using wgcf mode."
  fi
  if systemd_unit_active warp-go.service || systemd_unit_enabled warp-go.service; then
    die "warp-go is active or enabled. Remove that routing owner before continuing."
  fi
  if systemd_unit_active wg-quick@warp.service || systemd_unit_enabled wg-quick@warp.service; then
    die "wg-quick@warp is active or enabled. Keep only one WARP routing owner."
  fi
}

ensure_managed_or_absent() {
  local path
  path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  [ ! -L "$path" ] || die "Refusing to replace symbolic link: $path"
  [ -f "$path" ] || die "Refusing to replace non-regular path: $path"
  head -n 3 "$path" | grep -Fxq "$MANAGED_MARKER" ||
    die "Refusing to replace unowned file: $path"
}

file_has_managed_marker() {
  [ -f "$1" ] && [ ! -L "$1" ] &&
    head -n 3 "$1" | grep -Fxq "$MANAGED_MARKER"
}

ensure_install_paths_owned() {
  ensure_managed_or_absent "$INSTALL_PATH"
  ensure_managed_or_absent "$SERVICE_FILE"
  ensure_managed_or_absent "$HEALTH_SERVICE_FILE"
  ensure_managed_or_absent "$HEALTH_TIMER_FILE"
  ensure_managed_or_absent "$NETWORKD_DROPIN"
}

remove_managed_file() {
  local path
  path="$1"
  [ -e "$path" ] || [ -L "$path" ] || return 0
  ensure_managed_or_absent "$path"
  rm -f -- "$path"
}

make_backup() {
  local stamp
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  LATEST_BACKUP="$BACKUP_ROOT/$stamp"
  install -d -m 0700 "$LATEST_BACKUP" "$STATE_DIR"

  if [ -f "$WG_CONF" ]; then
    cp -a "$WG_CONF" "$LATEST_BACKUP/wgcf.conf"
    PROFILE_SOURCE="$LATEST_BACKUP/wgcf.conf"
    if ! file_has_managed_marker "$WG_CONF" && [ ! -f "$ORIGINAL_PROFILE_POINTER" ]; then
      printf '%s\n' "$LATEST_BACKUP/wgcf.conf" >"$ORIGINAL_PROFILE_POINTER"
      chmod 0600 "$ORIGINAL_PROFILE_POINTER"
    fi
  fi
  if [ -f "$ACCOUNT_FILE" ]; then
    cp -a "$ACCOUNT_FILE" "$LATEST_BACKUP/wgcf-account.toml"
  fi
  if [ -f /etc/warp/wgcf-account.toml ]; then
    cp -a /etc/warp/wgcf-account.toml "$LATEST_BACKUP/legacy-wgcf-account.toml"
  fi
  if [ -f /etc/wireguard/wgcf-account.toml ]; then
    cp -a /etc/wireguard/wgcf-account.toml "$LATEST_BACKUP/wireguard-wgcf-account.toml"
  fi
  if [ -f "$NETWORKD_DROPIN" ]; then
    cp -a "$NETWORKD_DROPIN" "$LATEST_BACKUP/networkd-dropin.conf"
  fi
  if [ -f "$SERVICE_FILE" ]; then
    cp -a "$SERVICE_FILE" "$LATEST_BACKUP/outline-warp.service"
  fi
  if [ -f "$HEALTH_SERVICE_FILE" ]; then
    cp -a "$HEALTH_SERVICE_FILE" "$LATEST_BACKUP/outline-warp-health.service"
  fi
  if [ -f "$HEALTH_TIMER_FILE" ]; then
    cp -a "$HEALTH_TIMER_FILE" "$LATEST_BACKUP/outline-warp-health.timer"
  fi
  if [ -f "$INSTALL_PATH" ]; then
    cp -a "$INSTALL_PATH" "$LATEST_BACKUP/outline-warp-safe"
  fi
  ip -4 rule show >"$LATEST_BACKUP/ip4-rules.txt" 2>/dev/null || true
  ip -6 rule show >"$LATEST_BACKUP/ip6-rules.txt" 2>/dev/null || true
  ip -4 route show table all >"$LATEST_BACKUP/ip4-routes.txt" 2>/dev/null || true
  ip -6 route show table all >"$LATEST_BACKUP/ip6-routes.txt" 2>/dev/null || true
  systemctl is-enabled wg-quick@wgcf.service >"$LATEST_BACKUP/legacy-enabled.txt" 2>&1 || true
  info "Backup created: $LATEST_BACKUP"
}

install_dependencies() {
  info "Installing Debian packages."
  apt-get update
  env DEBIAN_FRONTEND=noninteractive apt-get install -y \
    ca-certificates curl iproute2 nftables util-linux wireguard-tools
  command_exists wg || die "wg is missing after package installation."
  command_exists wg-quick || die "wg-quick is missing after package installation."
  command_exists nft || die "nft is missing after package installation."
  command_exists flock || die "flock is missing after package installation."
  command_exists systemd-analyze || die "systemd-analyze is missing."
  command_exists systemd-run || die "systemd-run is missing."
  modprobe wireguard || die "Kernel WireGuard is unavailable. This script will not install wireguard-go."
}

validate_installer_source() {
  local source_path
  source_path="${BASH_SOURCE[0]}"
  case "$source_path" in
    /dev/fd/*|/proc/self/fd/*) die "Download this script to a regular file before install; process substitution cannot self-install safely." ;;
  esac
  [ -f "$source_path" ] && [ -s "$source_path" ] || die "Installer source is not a non-empty regular file."
  INSTALLER_SOURCE="$source_path"
}

install_self() {
  local source_path temp_path
  validate_installer_source
  source_path="$INSTALLER_SOURCE"
  install -d -m 0755 "$LIB_DIR"
  install -d -m 0700 "$STATE_DIR" "$DATA_DIR" "$BACKUP_ROOT"
  install -d -m 0700 /etc/wireguard
  if [ -e "$INSTALL_PATH" ] && [ "$source_path" -ef "$INSTALL_PATH" ]; then
    return 0
  fi
  temp_path=$(mktemp /usr/local/sbin/.outline-warp-safe.XXXXXX)
  install -m 0755 "$source_path" "$temp_path"
  mv -f -- "$temp_path" "$INSTALL_PATH"
}

install_wgcf() {
  local arch asset sha url temp_file target_file existing_sha
  arch=$(uname -m)
  case "$arch" in
    x86_64|amd64)
      asset="wgcf_$WGCF_VERSION"_linux_amd64
      sha="$WGCF_AMD64_SHA256"
      ;;
    aarch64|arm64)
      asset="wgcf_$WGCF_VERSION"_linux_arm64
      sha="$WGCF_ARM64_SHA256"
      ;;
    *)
      die "Unsupported architecture: $arch. Supported: amd64, arm64."
      ;;
  esac
  install -d -m 0755 "$LIB_DIR"
  if [ -f "$WGCF_BIN" ]; then
    existing_sha=$(sha256sum "$WGCF_BIN" | awk '{print $1}')
    if [ "$existing_sha" = "$sha" ]; then
      return 0
    fi
    die "Refusing to overwrite an unexpected binary at $WGCF_BIN."
  fi
  url="https://github.com/ViRb3/wgcf/releases/download/v$WGCF_VERSION/$asset"
  temp_file=$(mktemp /tmp/outline-warp-safe.wgcf.XXXXXX)
  if ! curl --proto '=https' --tlsv1.2 -fL --retry 3 \
    --connect-timeout 10 --max-time 120 "$url" -o "$temp_file"; then
    rm -f "$temp_file"
    die "Failed to download pinned wgcf release."
  fi
  printf '%s  %s\n' "$sha" "$temp_file" | sha256sum -c - >/dev/null || {
    rm -f "$temp_file"
    die "wgcf SHA-256 verification failed."
  }
  target_file=$(mktemp "$LIB_DIR/.wgcf.XXXXXX")
  install -m 0755 "$temp_file" "$target_file"
  mv -f -- "$target_file" "$WGCF_BIN"
  rm -f "$temp_file"
}

find_account_file() {
  local candidate
  for candidate in \
    "$ACCOUNT_FILE" \
    /etc/warp/wgcf-account.toml \
    /etc/wireguard/wgcf-account.toml; do
    if [ -n "$candidate" ] && [ -f "$candidate" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  if [ -n "$LATEST_BACKUP" ]; then
    for candidate in \
      "$LATEST_BACKUP/legacy-wgcf-account.toml" \
      "$LATEST_BACKUP/wireguard-wgcf-account.toml"; do
      if [ -f "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi
  return 1
}

profile_is_reusable() {
  local file
  file="$1"
  [ -f "$file" ] || return 1
  grep -q '^[[:space:]]*PrivateKey[[:space:]]*=' "$file" || return 1
  grep -q '^[[:space:]]*Address[[:space:]]*=' "$file" || return 1
  grep -q '^[[:space:]]*PublicKey[[:space:]]*=' "$file" || return 1
  grep -q '^[[:space:]]*Endpoint[[:space:]]*=' "$file" || return 1
}

generate_source_profile() {
  local account
  PROFILE_WORK_DIR=$(mktemp -d /tmp/outline-warp-safe.profile.XXXXXX)
  chmod 0700 "$PROFILE_WORK_DIR"
  SOURCE_PROFILE="$PROFILE_WORK_DIR/wgcf-profile.conf"

  if [ -n "$PROFILE_SOURCE" ] && profile_is_reusable "$PROFILE_SOURCE"; then
    cp -- "$PROFILE_SOURCE" "$SOURCE_PROFILE"
    return 0
  fi

  account=""
  if account=$(find_account_file); then
    cp -- "$account" "$PROFILE_WORK_DIR/wgcf-account.toml"
  else
    info "Registering a new WARP account."
    (cd "$PROFILE_WORK_DIR" && "$WGCF_BIN" register --accept-tos) ||
      die "wgcf registration failed. Native networking was left unchanged."
  fi

  (cd "$PROFILE_WORK_DIR" && "$WGCF_BIN" generate) ||
    die "wgcf profile generation failed. Native networking was left unchanged."
  [ -f "$SOURCE_PROFILE" ] || die "wgcf did not create a profile."
  [ -f "$PROFILE_WORK_DIR/wgcf-account.toml" ] || die "wgcf did not create an account file."
  install -m 0600 "$PROFILE_WORK_DIR/wgcf-account.toml" "$ACCOUNT_FILE"
}

section_value() {
  awk -F= -v wanted_section="$2" -v key="$3" '
    /^[[:space:]]*\[/ {
      section=$0
      gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", section)
      next
    }
    section == wanted_section && $1 ~ "^[[:space:]]*" key "[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      print value
      exit
    }
  ' "$1"
}

interface_addresses() {
  awk -F= '
    /^[[:space:]]*\[/ {
      section=$0
      gsub(/^[[:space:]]*\[[[:space:]]*|[[:space:]]*\][[:space:]]*$/, "", section)
      next
    }
    section == "Interface" && $1 ~ "^[[:space:]]*Address[[:space:]]*$" {
      value=$0
      sub(/^[^=]*=[[:space:]]*/, "", value)
      sub(/[[:space:]]*$/, "", value)
      if (value != "") {
        if (result != "") result=result ", "
        result=result value
      }
    }
    END { print result }
  ' "$1"
}

prepare_managed_profile() {
  local private_key addresses peer_key
  generate_source_profile
  private_key=$(section_value "$SOURCE_PROFILE" Interface PrivateKey)
  addresses=$(interface_addresses "$SOURCE_PROFILE")
  peer_key=$(section_value "$SOURCE_PROFILE" Peer PublicKey)

  [ -n "$private_key" ] || die "Generated profile has no Interface PrivateKey."
  [ -n "$addresses" ] || die "Generated profile has no Interface Address."
  [ -n "$peer_key" ] || die "Generated profile has no Peer PublicKey."
  printf '%s\n' "$addresses" | grep -q '\.' || die "Generated profile has no WARP IPv4 address."
  printf '%s\n' "$addresses" | grep -q ':' || die "Generated profile has no WARP IPv6 address."

  PREPARED_PROFILE="$PROFILE_WORK_DIR/wgcf.conf"
  {
    printf '%s\n' "$MANAGED_MARKER"
    printf '# Version %s; secrets must never be logged.\n\n' "$VERSION"
    printf '[Interface]\n'
    printf 'PrivateKey = %s\n' "$private_key"
    printf 'Address = %s\n' "$addresses"
    printf 'MTU = 1280\n'
    printf 'Table = off\n'
    printf 'FwMark = %s\n' "$FWMARK"
    printf 'PostUp = %s _policy_up\n' "$INSTALL_PATH"
    printf 'PostDown = %s _policy_down\n\n' "$INSTALL_PATH"
    printf '[Peer]\n'
    printf 'PublicKey = %s\n' "$peer_key"
    printf 'AllowedIPs = 0.0.0.0/0, ::/0\n'
    printf 'Endpoint = %s\n' "$WARP_ENDPOINT"
    printf 'PersistentKeepalive = 25\n'
  } >"$PREPARED_PROFILE"
  chmod 0600 "$PREPARED_PROFILE"
  wg-quick strip "$PREPARED_PROFILE" >/dev/null || die "Prepared WireGuard profile failed validation."

  SOURCE_PROFILE=""
}

install_prepared_profile() {
  local target_file
  [ -f "$PREPARED_PROFILE" ] && [ -s "$PREPARED_PROFILE" ] || die "Prepared profile is missing."
  target_file=$(mktemp /etc/wireguard/.wgcf.conf.XXXXXX)
  install -m 0600 "$PREPARED_PROFILE" "$target_file"
  mv -f -- "$target_file" "$WG_CONF"
  rm -rf -- "$PROFILE_WORK_DIR"
  PROFILE_WORK_DIR=""
  PREPARED_PROFILE=""
}

networkd_in_use() {
  systemd_unit_active systemd-networkd.service || systemd_unit_enabled systemd-networkd.service
}

networkd_systemd_version() {
  systemd --version 2>/dev/null | awk 'NR==1 {print $2}'
}

preflight_networkd_policy() {
  local systemd_version
  networkd_in_use || return 0
  systemd_version=$(networkd_systemd_version)
  case "$systemd_version" in
    ''|*[!0-9]*) die "Could not determine systemd version while systemd-networkd is in use." ;;
  esac
  [ "$systemd_version" -ge 249 ] ||
    die "systemd-networkd requires systemd 249 or newer for safe foreign-rule preservation; found $systemd_version."
}

install_networkd_policy() {
  local temp_file
  if networkd_in_use; then
    preflight_networkd_policy
    ensure_managed_or_absent "$NETWORKD_DROPIN"
    install -d -m 0755 /etc/systemd/networkd.conf.d
    temp_file=$(mktemp /tmp/outline-warp-safe.networkd.XXXXXX)
    cat >"$temp_file" <<'EOF'
# Managed by outline-warp-safe
# wg-quick owns dynamic policy rules and its WARP routing table.
[Network]
ManageForeignRoutingPolicyRules=no
ManageForeignRoutes=no
EOF
    install -m 0644 "$temp_file" "$NETWORKD_DROPIN"
    rm -f "$temp_file"
    info "Installed systemd-networkd policy. It takes effect on its next start; networkd was not restarted."
  fi
}

write_systemd_units() {
  local temp_file

  ensure_managed_or_absent "$SERVICE_FILE"
  ensure_managed_or_absent "$HEALTH_SERVICE_FILE"
  ensure_managed_or_absent "$HEALTH_TIMER_FILE"

  temp_file=$(mktemp /tmp/outline-warp-safe.unit.XXXXXX)
  cat >"$temp_file" <<'EOF'
# Managed by outline-warp-safe
[Unit]
Description=Safe WARP dual-stack egress for Outline servers
Documentation=https://github.com/mahaonan1005/warp.sh
After=network-online.target cloud-final.service
Wants=network-online.target
StartLimitIntervalSec=300
StartLimitBurst=3

[Service]
Type=oneshot
RemainAfterExit=yes
UMask=0077
ExecStart=/usr/local/sbin/outline-warp-safe _service_up
ExecStop=/usr/local/sbin/outline-warp-safe _service_down
ExecStopPost=/usr/local/sbin/outline-warp-safe _service_down
TimeoutStartSec=150
TimeoutStopSec=60
Restart=on-failure
RestartSec=15

[Install]
WantedBy=multi-user.target
EOF
  install -m 0644 "$temp_file" "$SERVICE_FILE"

  cat >"$temp_file" <<'EOF'
# Managed by outline-warp-safe
[Unit]
Description=Verify WARP handshake, dual-stack egress, and native return routes
After=outline-warp.service
ConditionPathExists=/etc/wireguard/wgcf.conf

[Service]
Type=oneshot
UMask=0077
ExecStart=/usr/local/sbin/outline-warp-safe _health_monitor
TimeoutStartSec=300
EOF
  install -m 0644 "$temp_file" "$HEALTH_SERVICE_FILE"

  cat >"$temp_file" <<'EOF'
# Managed by outline-warp-safe
[Unit]
Description=Periodic WARP safety check

[Timer]
OnBootSec=2min
OnUnitActiveSec=2min
RandomizedDelaySec=15
AccuracySec=15s
Persistent=true

[Install]
WantedBy=timers.target
EOF
  install -m 0644 "$temp_file" "$HEALTH_TIMER_FILE"
  rm -f "$temp_file"
  systemd-analyze verify "$SERVICE_FILE" "$HEALTH_SERVICE_FILE" "$HEALTH_TIMER_FILE" >/dev/null ||
    die "Generated systemd units failed validation."
  systemctl daemon-reload
}

list_global_addresses() {
  local family dev suffix
  family="$1"
  dev="$2"
  case "$family" in
    -4) suffix="/32" ;;
    -6) suffix="/128" ;;
    *) return 1 ;;
  esac
  ip -o "$family" address show dev "$dev" scope global 2>/dev/null |
    awk -v suffix="$suffix" '
      $0 !~ /(^|[[:space:]])tentative([[:space:]]|$)/ &&
      $0 !~ /(^|[[:space:]])dadfailed([[:space:]]|$)/ {
        split($4, address, "/")
        print address[1] suffix
      }
    ' | sort -u
}

route_device() {
  awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

validate_native_device() {
  case "$1" in
    "$INTERFACE"|wg*|tun*|tap*|tailscale*|warp*)
      die "The detected native route uses tunnel-like interface $1; keep only one routing owner."
      ;;
  esac
}

capture_native_state() {
  local attempt route4 dev4 route6 dev6 src
  install -d -m 0700 "$RUN_DIR"
  : >"$RUN_DIR/native4"
  : >"$RUN_DIR/native6"
  : >"$RUN_DIR/rules4"
  : >"$RUN_DIR/rules6"

  route4=""
  dev4=""
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    route4=$(ip -4 route get 1.1.1.1 2>/dev/null | head -n 1 || true)
    dev4=$(printf '%s\n' "$route4" | route_device)
    if [ -n "$dev4" ] && [ "$dev4" != "$INTERFACE" ]; then
      list_global_addresses -4 "$dev4" >"$RUN_DIR/native4"
      [ -s "$RUN_DIR/native4" ] && break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  [ -n "$dev4" ] && [ -s "$RUN_DIR/native4" ] ||
    die "Native IPv4 route and address were not ready after 30 seconds."
  validate_native_device "$dev4"
  printf '%s\n' "$dev4" >"$RUN_DIR/dev4"

  src=$(printf '%s\n' "$route4" | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}')
  [ -n "$src" ] || die "Native IPv4 route has no source address."

  route6=""
  dev6=""
  attempt=0
  while [ "$attempt" -lt 10 ]; do
    route6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | head -n 1 || true)
    dev6=$(printf '%s\n' "$route6" | route_device)
    if [ -n "$dev6" ] && [ "$dev6" != "$INTERFACE" ]; then
      list_global_addresses -6 "$dev6" >"$RUN_DIR/native6"
      [ -s "$RUN_DIR/native6" ] && break
    elif [ "$attempt" -ge 4 ]; then
      break
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  if [ -n "$dev6" ] && [ "$dev6" != "$INTERFACE" ]; then
    [ -s "$RUN_DIR/native6" ] || die "Native IPv6 route exists, but no stable global IPv6 address was ready."
    validate_native_device "$dev6"
    printf '%s\n' "$dev6" >"$RUN_DIR/dev6"
  else
    : >"$RUN_DIR/dev6"
    : >"$RUN_DIR/native6"
  fi

  if [ -r /proc/sys/net/ipv4/conf/all/src_valid_mark ]; then
    cat /proc/sys/net/ipv4/conf/all/src_valid_mark >"$RUN_DIR/src-valid-mark-before"
  else
    printf '0\n' >"$RUN_DIR/src-valid-mark-before"
  fi
  printf '%s %s\n' "$VERSION" "$$" >"$RUN_DIR/owned"
}

priority_line() {
  ip -N "$1" rule show priority "$2" 2>/dev/null
}

reserved_priority_lines() {
  ip -N "$1" rule show 2>/dev/null |
    awk -F: '$1+0 >= 11000 && $1+0 <= 11220 {print}'
}

routing_owner_conflicts() {
  local family output line mark_hex
  family="$1"
  mark_hex=$(printf '0x%x' "$FWMARK")
  output=$(ip -N "$family" rule show 2>/dev/null) || return 2
  while IFS= read -r line; do
    case "$line" in
      *"lookup $ROUTE_TABLE"*|*"fwmark $mark_hex"*) printf '%s\n' "$line" ;;
    esac
  done <<<"$output"
}

route_table_lines() {
  ip "$1" route show table "$ROUTE_TABLE" 2>/dev/null
}

owned_artifacts_present() {
  local output
  ip link show "$INTERFACE" >/dev/null 2>&1 && return 0
  if ! output=$(route_table_lines -4); then warn "Could not inspect IPv4 table $ROUTE_TABLE."; return 0; fi
  [ -n "$output" ] && return 0
  if ! output=$(route_table_lines -6); then warn "Could not inspect IPv6 table $ROUTE_TABLE."; return 0; fi
  [ -n "$output" ] && return 0
  if ! output=$(reserved_priority_lines -4); then warn "Could not inspect IPv4 policy rules."; return 0; fi
  [ -n "$output" ] && return 0
  if ! output=$(reserved_priority_lines -6); then warn "Could not inspect IPv6 policy rules."; return 0; fi
  [ -n "$output" ] && return 0
  return 1
}

assert_reserved_space_clear() {
  local found
  ip link show "$INTERFACE" >/dev/null 2>&1 &&
    die "Interface $INTERFACE already exists without this run's ownership marker."
  found=$(route_table_lines -4) || die "Could not inspect IPv4 table $ROUTE_TABLE."
  [ -z "$found" ] || die "IPv4 table $ROUTE_TABLE is already in use: $found"
  found=$(route_table_lines -6) || die "Could not inspect IPv6 table $ROUTE_TABLE."
  [ -z "$found" ] || die "IPv6 table $ROUTE_TABLE is already in use: $found"
  found=$(reserved_priority_lines -4) || die "Could not inspect IPv4 policy rules."
  [ -z "$found" ] || die "Reserved IPv4 policy priorities are already in use: $found"
  found=$(reserved_priority_lines -6) || die "Could not inspect IPv6 policy rules."
  [ -z "$found" ] || die "Reserved IPv6 policy priorities are already in use: $found"
  found=$(routing_owner_conflicts -4) || die "Could not inspect IPv4 routing-owner conflicts."
  [ -z "$found" ] || die "IPv4 rules already reference table or fwmark $ROUTE_TABLE: $found"
  found=$(routing_owner_conflicts -6) || die "Could not inspect IPv6 routing-owner conflicts."
  [ -z "$found" ] || die "IPv6 rules already reference table or fwmark $ROUTE_TABLE: $found"
}

rule_contains_all() {
  local family priority output fragment line matched
  family="$1"
  priority="$2"
  shift 2
  output=$(priority_line "$family" "$priority") || return 2
  [ -n "$output" ] || return 1
  while IFS= read -r line; do
    matched=1
    for fragment in "$@"; do
      case "$line" in
        *"$fragment"*) ;;
        *) matched=0; break ;;
      esac
    done
    [ "$matched" -eq 1 ] && return 0
  done <<<"$output"
  return 1
}

add_native_rules() {
  local family file rules_file base priority address existing count previous_size
  family="$1"
  file="$2"
  rules_file="$3"
  base="$4"
  priority="$base"
  count=$(awk 'NF {count++} END {print count+0}' "$file")
  [ "$count" -le 100 ] || die "More than 100 native addresses cannot be assigned safely."

  while IFS= read -r address; do
    [ -n "$address" ] || continue
    existing=$(priority_line "$family" "$priority") ||
      die "Could not inspect policy priority $priority."
    [ -z "$existing" ] ||
      die "Policy priority $priority is already used; refusing ownership: $existing"
    previous_size=$(stat -c %s "$rules_file") || die "Could not inspect the rule ownership ledger."
    if ! printf '%s %s\n' "$priority" "$address" >>"$rules_file"; then
      truncate -s "$previous_size" "$rules_file" >/dev/null 2>&1 || true
      die "Could not record rule ownership; no rule was added."
    fi
    if ! ip "$family" rule add priority "$priority" from "$address" table main; then
      truncate -s "$previous_size" "$rules_file" >/dev/null 2>&1 ||
        warn "Could not rewind the unused ownership record."
      die "Could not add native return rule at priority $priority."
    fi
    priority=$((priority + 1))
  done <"$file"
}

policy_up() {
  local existing table_lines
  [ -f "$RUN_DIR/owned" ] || die "Runtime ownership marker is missing."
  table_lines=$(route_table_lines -4) || die "Could not inspect IPv4 table $ROUTE_TABLE."
  [ -z "$table_lines" ] ||
    die "IPv4 table $ROUTE_TABLE is already in use."
  table_lines=$(route_table_lines -6) || die "Could not inspect IPv6 table $ROUTE_TABLE."
  [ -z "$table_lines" ] ||
    die "IPv6 table $ROUTE_TABLE is already in use."

  for existing in 11200 11210 11220; do
    table_lines=$(priority_line -4 "$existing") || die "Could not inspect IPv4 policy priority $existing."
    [ -z "$table_lines" ] ||
      die "IPv4 policy priority $existing is already in use."
  done
  for existing in 11210 11220; do
    table_lines=$(priority_line -6 "$existing") || die "Could not inspect IPv6 policy priority $existing."
    [ -z "$table_lines" ] ||
      die "IPv6 policy priority $existing is already in use."
  done

  add_native_rules -4 "$RUN_DIR/native4" "$RUN_DIR/rules4" 11000
  add_native_rules -6 "$RUN_DIR/native6" "$RUN_DIR/rules6" 11100

  ip -4 rule add priority 11200 to 162.159.192.1/32 table main
  ip -4 rule add priority 11210 table main suppress_prefixlength 0
  ip -6 rule add priority 11210 table main suppress_prefixlength 0
  ip -4 route add default dev "$INTERFACE" table "$ROUTE_TABLE"
  ip -6 route add default dev "$INTERFACE" table "$ROUTE_TABLE"
  ip -4 rule add priority 11220 not fwmark "$FWMARK" table "$ROUTE_TABLE"
  ip -6 rule add priority 11220 not fwmark "$FWMARK" table "$ROUTE_TABLE"
  sysctl -q net.ipv4.conf.all.src_valid_mark=1

  ip -4 route flush cache >/dev/null 2>&1 || true
  ip -6 route flush cache >/dev/null 2>&1 || true
}

native_rule_present() {
  local family priority address source
  family="$1"
  priority="$2"
  address="$3"
  source=${address%/*}
  rule_contains_all "$family" "$priority" "from $source" "lookup 254"
}

valid_native_ledger_entry() {
  local family priority address
  family="$1"
  priority="$2"
  address="$3"
  case "$priority" in ''|*[!0-9]*) return 1 ;; esac
  case "$family" in
    -4)
      [ "$priority" -ge 11000 ] && [ "$priority" -le 11099 ] || return 1
      [[ "$address" =~ ^[0-9.]+/32$ ]]
      ;;
    -6)
      [ "$priority" -ge 11100 ] && [ "$priority" -le 11199 ] || return 1
      [[ "$address" =~ ^[0-9A-Fa-f:]+/128$ ]]
      ;;
    *) return 1 ;;
  esac
}

delete_native_rules() {
  local family rules_file priority address rc present_rc
  family="$1"
  rules_file="$2"
  [ -f "$rules_file" ] || return 0
  rc=0
  while read -r priority address; do
    [ -n "$priority" ] || continue
    if ! valid_native_ledger_entry "$family" "$priority" "$address"; then
      warn "Invalid native-rule ownership record; refusing to execute it."
      rc=1
      continue
    fi
    if native_rule_present "$family" "$priority" "$address"; then
      ip "$family" rule delete priority "$priority" from "$address" table main >/dev/null 2>&1 || true
    else
      present_rc=$?
      if [ "$present_rc" -gt 1 ]; then
        warn "Could not inspect native return rule at priority $priority."
        rc=1
        continue
      fi
    fi
    if native_rule_present "$family" "$priority" "$address"; then
      warn "Owned native return rule remains at priority $priority."
      rc=1
    else
      present_rc=$?
      if [ "$present_rc" -gt 1 ]; then
        warn "Could not verify native return rule deletion at priority $priority."
        rc=1
      fi
    fi
  done <"$rules_file"
  return "$rc"
}

fixed_rule_present() {
  local family priority kind mark_hex
  family="$1"
  priority="$2"
  kind="$3"
  case "$kind" in
    capture)
      mark_hex=$(printf '0x%x' "$FWMARK")
      rule_contains_all "$family" "$priority" "fwmark $mark_hex" "lookup $ROUTE_TABLE"
      ;;
    suppress)
      rule_contains_all "$family" "$priority" "lookup 254" "suppress_prefixlength 0"
      ;;
    endpoint)
      rule_contains_all "$family" "$priority" "to 162.159.192.1" "lookup 254"
      ;;
    *) return 1 ;;
  esac
}

delete_fixed_rule() {
  local family priority kind present_rc
  family="$1"
  priority="$2"
  kind="$3"
  if fixed_rule_present "$family" "$priority" "$kind"; then
    :
  else
    present_rc=$?
    if [ "$present_rc" -eq 1 ]; then
      return 0
    fi
    warn "Could not inspect owned $kind rule at priority $priority."
    return 1
  fi
  case "$kind" in
    capture)
      ip "$family" rule delete priority "$priority" not fwmark "$FWMARK" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
      ;;
    suppress)
      ip "$family" rule delete priority "$priority" table main suppress_prefixlength 0 >/dev/null 2>&1 || true
      ;;
    endpoint)
      ip "$family" rule delete priority "$priority" to 162.159.192.1/32 table main >/dev/null 2>&1 || true
      ;;
  esac
  if fixed_rule_present "$family" "$priority" "$kind"; then
    warn "Owned $kind rule remains at priority $priority."
    return 1
  else
    present_rc=$?
    if [ "$present_rc" -gt 1 ]; then
      warn "Could not verify $kind rule deletion at priority $priority."
      return 1
    fi
  fi
}

owned_default_route_present() {
  local output
  output=$(ip "$1" route show table "$ROUTE_TABLE" default 2>/dev/null) || return 2
  printf '%s\n' "$output" |
    awk -v dev="$INTERFACE" '
      {for (i=1; i<=NF; i++) if ($i=="dev" && $(i+1)==dev) found=1}
      END {exit !found}
    '
}

delete_owned_default_route() {
  local family present_rc
  family="$1"
  if owned_default_route_present "$family"; then
    :
  else
    present_rc=$?
    if [ "$present_rc" -eq 1 ]; then
      return 0
    fi
    warn "Could not inspect $family table $ROUTE_TABLE."
    return 1
  fi
  ip "$family" route delete default dev "$INTERFACE" table "$ROUTE_TABLE" >/dev/null 2>&1 || true
  if owned_default_route_present "$family"; then
    warn "Owned $family default route remains in table $ROUTE_TABLE."
    return 1
  else
    present_rc=$?
    if [ "$present_rc" -gt 1 ]; then
      warn "Could not verify $family default route deletion."
      return 1
    fi
  fi
}

fixed_rule_is_absent() {
  local rc
  if fixed_rule_present "$1" "$2" "$3"; then
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      warn "Could not verify absence of $3 rule at priority $2."
      return 1
    }
  fi
}

owned_default_route_is_absent() {
  local rc
  if owned_default_route_present "$1"; then
    return 1
  else
    rc=$?
    [ "$rc" -eq 1 ] || {
      warn "Could not verify absence of $1 route table $ROUTE_TABLE."
      return 1
    }
  fi
}

restore_src_valid_mark() {
  local previous current
  [ -f "$RUN_DIR/src-valid-mark-before" ] || return 0
  previous=$(cat "$RUN_DIR/src-valid-mark-before")
  case "$previous" in 0|1) ;; *) return 1 ;; esac
  sysctl -q "net.ipv4.conf.all.src_valid_mark=$previous" >/dev/null 2>&1 || true
  current=$(cat /proc/sys/net/ipv4/conf/all/src_valid_mark 2>/dev/null || true)
  [ "$current" = "$previous" ] || {
    warn "Could not restore net.ipv4.conf.all.src_valid_mark=$previous."
    return 1
  }
}

policy_cleanup_complete() {
  local remaining
  fixed_rule_is_absent -4 11220 capture || return 1
  fixed_rule_is_absent -6 11220 capture || return 1
  fixed_rule_is_absent -4 11210 suppress || return 1
  fixed_rule_is_absent -6 11210 suppress || return 1
  fixed_rule_is_absent -4 11200 endpoint || return 1
  owned_default_route_is_absent -4 || return 1
  owned_default_route_is_absent -6 || return 1
  remaining=$(route_table_lines -4) || return 1
  [ -z "$remaining" ] || { warn "IPv4 table $ROUTE_TABLE still contains routes."; return 1; }
  remaining=$(route_table_lines -6) || return 1
  [ -z "$remaining" ] || { warn "IPv6 table $ROUTE_TABLE still contains routes."; return 1; }
  remaining=$(reserved_priority_lines -4) || return 1
  [ -z "$remaining" ] || { warn "Reserved IPv4 policy priorities are not empty."; return 1; }
  remaining=$(reserved_priority_lines -6) || return 1
  [ -z "$remaining" ] || { warn "Reserved IPv6 policy priorities are not empty."; return 1; }
  return 0
}

policy_down() {
  local rc
  if [ ! -f "$RUN_DIR/owned" ]; then
    if owned_artifacts_present; then
      warn "Ownership marker is missing; refusing to clean interface, reserved rules, or table $ROUTE_TABLE."
      return 1
    fi
    return 0
  fi

  rc=0
  delete_fixed_rule -4 11220 capture || rc=1
  delete_fixed_rule -6 11220 capture || rc=1
  delete_owned_default_route -4 || rc=1
  delete_owned_default_route -6 || rc=1
  delete_fixed_rule -4 11210 suppress || rc=1
  delete_fixed_rule -6 11210 suppress || rc=1
  delete_fixed_rule -4 11200 endpoint || rc=1
  delete_native_rules -4 "$RUN_DIR/rules4" || rc=1
  delete_native_rules -6 "$RUN_DIR/rules6" || rc=1
  restore_src_valid_mark || rc=1
  ip -4 route flush cache >/dev/null 2>&1 || true
  ip -6 route flush cache >/dev/null 2>&1 || true

  policy_cleanup_complete || rc=1
  if [ "$rc" -eq 0 ]; then
    rm -f -- "$RUN_DIR/owned" "$RUN_DIR/native4" "$RUN_DIR/native6" \
      "$RUN_DIR/rules4" "$RUN_DIR/rules6" "$RUN_DIR/dev4" "$RUN_DIR/dev6" \
      "$RUN_DIR/src-valid-mark-before"
  fi
  return "$rc"
}

managed_network_is_down() {
  [ -f "$RUN_DIR/owned" ] && return 1
  if owned_artifacts_present; then
    return 1
  fi
  return 0
}

safe_down() {
  if [ ! -f "$RUN_DIR/owned" ]; then
    if owned_artifacts_present; then
      warn "Managed ownership is unknown; no route or interface was deleted."
      return 1
    fi
    return 0
  fi

  if ip link show "$INTERFACE" >/dev/null 2>&1; then
    wg-quick down "$INTERFACE" >/dev/null 2>&1 ||
      warn "wg-quick down failed; attempting exact owned cleanup."
  fi
  if ip link show "$INTERFACE" >/dev/null 2>&1; then
    ip link delete dev "$INTERFACE" >/dev/null 2>&1 || true
  fi
  [ -f "$RUN_DIR/owned" ] && policy_down || true

  if ! managed_network_is_down; then
    warn "Managed WARP teardown is incomplete; ownership state was retained."
    return 1
  fi
  return 0
}

check_native_address_drift() {
  local stored_dev4 stored_dev6 route4 route6 current_dev4 current_dev6 current4 current6 rc
  [ -f "$RUN_DIR/dev4" ] && [ -f "$RUN_DIR/native4" ] && [ -f "$RUN_DIR/dev6" ] || return 2
  stored_dev4=$(cat "$RUN_DIR/dev4")
  stored_dev6=$(cat "$RUN_DIR/dev6")
  current4=$(mktemp "$RUN_DIR/current4.XXXXXX")
  current6=$(mktemp "$RUN_DIR/current6.XXXXXX")
  rc=0

  route4=$(ip -4 route get 1.1.1.1 mark "$FWMARK" 2>/dev/null | head -n 1 || true)
  current_dev4=$(printf '%s\n' "$route4" | route_device)
  list_global_addresses -4 "$stored_dev4" >"$current4"
  if [ "$current_dev4" != "$stored_dev4" ] || ! cmp -s "$current4" "$RUN_DIR/native4"; then
    warn "Native IPv4 device or address set changed after WARP start."
    rc=2
  fi

  route6=$(ip -6 route get 2606:4700:4700::1111 mark "$FWMARK" 2>/dev/null | head -n 1 || true)
  current_dev6=$(printf '%s\n' "$route6" | route_device)
  if [ -n "$stored_dev6" ]; then
    list_global_addresses -6 "$stored_dev6" >"$current6"
    if [ "$current_dev6" != "$stored_dev6" ] || ! cmp -s "$current6" "$RUN_DIR/native6"; then
      warn "Native IPv6 device or address set changed after WARP start."
      rc=2
    fi
  elif [ -n "$current_dev6" ] && [ "$current_dev6" != "$INTERFACE" ]; then
    warn "A native IPv6 route appeared after WARP start."
    rc=2
  fi

  rm -f -- "$current4" "$current6"
  return "$rc"
}

check_native_return_routes() {
  local dev4 dev6 address source route actual_dev
  [ -f "$RUN_DIR/dev4" ] || return 2
  dev4=$(cat "$RUN_DIR/dev4")
  while IFS= read -r address; do
    [ -n "$address" ] || continue
    source=$(printf '%s\n' "$address" | cut -d/ -f1)
    route=$(ip -4 route get 1.1.1.1 from "$source" 2>/dev/null || true)
    actual_dev=$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
    [ "$actual_dev" = "$dev4" ] || {
      warn "Native IPv4 reply route does not use $dev4: $route"
      return 2
    }
  done <"$RUN_DIR/native4"

  if [ -s "$RUN_DIR/native6" ]; then
    dev6=$(cat "$RUN_DIR/dev6")
    while IFS= read -r address; do
      [ -n "$address" ] || continue
      source=$(printf '%s\n' "$address" | cut -d/ -f1)
      route=$(ip -6 route get 2606:4700:4700::1111 from "$source" 2>/dev/null || true)
      actual_dev=$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
      [ "$actual_dev" = "$dev6" ] || {
        warn "Native IPv6 reply route does not use $dev6: $route"
        return 2
      }
    done <"$RUN_DIR/native6"
  fi
  return 0
}

check_endpoint_route() {
  local mark route actual_dev native_dev
  mark=$(wg show "$INTERFACE" fwmark 2>/dev/null || true)
  [ -n "$mark" ] && [ "$mark" != "off" ] || {
    warn "WireGuard fwmark is missing."
    return 2
  }
  route=$(ip -4 route get 162.159.192.1 mark "$mark" 2>/dev/null || true)
  [ -n "$route" ] || {
    warn "WARP endpoint has no route."
    return 2
  }
  actual_dev=$(printf '%s\n' "$route" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  native_dev=$(cat "$RUN_DIR/dev4" 2>/dev/null || true)
  if [ -z "$native_dev" ] || [ "$actual_dev" != "$native_dev" ]; then
    warn "WARP outer endpoint does not use captured native device $native_dev: $route"
    return 2
  fi
  return 0
}

check_warp_default_routes() {
  local route4 route6 dev4 dev6
  route4=$(ip -4 route get 1.1.1.1 2>/dev/null || true)
  route6=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null || true)
  dev4=$(printf '%s\n' "$route4" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  dev6=$(printf '%s\n' "$route6" | awk '{for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}')
  [ "$dev4" = "$INTERFACE" ] || {
    warn "Generic IPv4 egress does not use $INTERFACE: $route4"
    return 2
  }
  [ "$dev6" = "$INTERFACE" ] || {
    warn "Generic IPv6 egress does not use $INTERFACE: $route6"
    return 2
  }
}

trace_family() {
  local family result
  family="$1"
  result=$(env -u http_proxy -u https_proxy -u all_proxy \
    -u HTTP_PROXY -u HTTPS_PROXY -u ALL_PROXY \
    curl "$family" --noproxy '*' --interface "$INTERFACE" -fsS \
    --connect-timeout 3 --max-time 8 "$TRACE_URL" 2>/dev/null |
    awk -F= '$1=="warp"{print $2; exit}' || true)
  case "$result" in
    on|plus) return 0 ;;
    *) return 1 ;;
  esac
}

check_handshake() {
  local latest now age
  latest=$(wg show "$INTERFACE" latest-handshakes 2>/dev/null |
    awk '$2>max{max=$2} END{print max+0}')
  [ "$latest" -gt 0 ] || {
    warn "WireGuard has no handshake."
    return 1
  }
  now=$(date +%s)
  age=$((now - latest))
  [ "$age" -le 90 ] || {
    warn "WireGuard handshake is stale: $age seconds."
    return 1
  }
}

handshake_is_recent() {
  local latest now age
  latest=$(wg show "$INTERFACE" latest-handshakes 2>/dev/null |
    awk '$2>max{max=$2} END{print max+0}')
  [ "$latest" -gt 0 ] || return 1
  now=$(date +%s)
  age=$((now - latest))
  [ "$age" -le 90 ]
}

wait_for_handshake() {
  local attempt
  trace_family -4 || true
  attempt=0
  while [ "$attempt" -lt 30 ]; do
    if handshake_is_recent; then
      return 0
    fi
    attempt=$((attempt + 1))
    sleep 1
  done
  warn "WireGuard did not complete a handshake within 30 seconds."
  return 1
}

check_runtime() {
  [ -f "$RUN_DIR/owned" ] || {
    warn "Runtime ownership marker is missing."
    return 2
  }
  ip link show "$INTERFACE" >/dev/null 2>&1 || {
    warn "$INTERFACE interface is absent."
    return 1
  }
  check_native_address_drift || return 2
  check_native_return_routes || return 2
  check_endpoint_route || return 2
  check_warp_default_routes || return 2

  check_handshake || return 1
  trace_family -4 || {
    warn "WARP IPv4 trace failed."
    return 1
  }
  trace_family -6 || {
    warn "WARP IPv6 trace failed."
    return 1
  }
  return 0
}

service_up_error_cleanup() {
  local exit_code
  exit_code="$1"
  trap - ERR INT TERM HUP
  warn "WARP start aborted; removing owned routes."
  if ! safe_down; then
    warn "Automatic WARP teardown is incomplete; use the cloud console."
    exit 2
  fi
  exit "$exit_code"
}

service_up() {
  local rc rollback_unit
  if [ -f "$PENDING_ROLLBACK_FILE" ]; then
    rollback_unit=$(pending_rollback_unit) || {
      warn "Pending candidate state is invalid; WARP start refused."
      return 2
    }
    systemd_unit_active "$rollback_unit.timer" || {
      warn "Pending candidate has no active rollback timer; WARP start refused."
      return 2
    }
  fi
  if [ -f "$RUN_DIR/owned" ]; then
    safe_down || return 2
  fi
  assert_reserved_space_clear
  capture_native_state
  trap 'service_up_error_cleanup $?' ERR
  trap 'service_up_error_cleanup 130' INT TERM HUP
  if ! wg-quick up "$INTERFACE"; then
    trap - ERR INT TERM HUP
    warn "wg-quick up failed; removing owned routes."
    safe_down || return 2
    return 1
  fi
  if ! wait_for_handshake; then
    trap - ERR INT TERM HUP
    warn "WARP handshake failed; removing owned routes."
    safe_down || return 2
    return 1
  fi
  if check_runtime; then
    rc=0
  else
    rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    trap - ERR INT TERM HUP
    warn "WARP validation failed; restoring native routing."
    safe_down || return 2
    return "$rc"
  fi
  printf '0\n' >"$HEALTH_FAILURE_FILE"
  trap - ERR INT TERM HUP
  info "WARP dual-stack is healthy; native return routes are preserved."
}

service_down() {
  safe_down || return 1
  info "Owned WARP interface and policy routes were removed."
}

stop_service_fail_open() {
  systemctl stop outline-warp.service >/dev/null 2>&1 ||
    warn "systemctl could not stop outline-warp.service; trying owned teardown."
  if ! managed_network_is_down; then
    safe_down || return 1
  fi
  managed_network_is_down
}

stop_health_timer_after_teardown() {
  managed_network_is_down || return 1
  systemctl stop outline-warp-health.timer >/dev/null 2>&1 || true
  if systemd_unit_active outline-warp-health.timer; then
    warn "Health timer could not be stopped."
    return 1
  fi
}

health_monitor() {
  local rc failures
  if ! systemd_unit_active outline-warp.service; then
    warn "outline-warp.service is not active; leaving native routing and pausing checks."
    if ! managed_network_is_down; then
      stop_service_fail_open || return 2
    fi
    stop_health_timer_after_teardown || return 2
    return 1
  fi

  set +e
  check_runtime
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then
    printf '0\n' >"$HEALTH_FAILURE_FILE"
    info "Periodic WARP health check passed."
    return 0
  fi

  if [ "$rc" -eq 2 ]; then
    warn "Critical return-route failure; stopping WARP immediately."
    stop_service_fail_open || return 2
    stop_health_timer_after_teardown || return 2
    return 2
  fi

  failures=0
  if [ -f "$HEALTH_FAILURE_FILE" ]; then
    failures=$(cat "$HEALTH_FAILURE_FILE" 2>/dev/null || printf '0')
  fi
  case "$failures" in
    ''|*[!0-9]*) failures=0 ;;
  esac
  failures=$((failures + 1))
  printf '%s\n' "$failures" >"$HEALTH_FAILURE_FILE"
  warn "WARP health failure $failures of 3."

  if [ "$failures" -lt 3 ]; then
    return 1
  fi

  warn "Restarting WARP after three consecutive failures."
  systemctl reset-failed outline-warp.service >/dev/null 2>&1 || true
  if systemctl restart outline-warp.service && check_runtime; then
    printf '0\n' >"$HEALTH_FAILURE_FILE"
    return 0
  fi

  warn "WARP recovery failed; removing owned routes and pausing checks until manual repair."
  stop_service_fail_open || return 2
  stop_health_timer_after_teardown || return 2
  return 1
}

pending_rollback_unit() {
  local unit
  [ -f "$PENDING_ROLLBACK_FILE" ] || return 1
  unit=$(cat "$PENDING_ROLLBACK_FILE" 2>/dev/null || true)
  if [[ "$unit" =~ ^outline-warp-rollback-[0-9]+-[0-9]+$ ]]; then
    printf '%s\n' "$unit"
  else
    warn "Invalid pending rollback state; refusing to use it."
    return 1
  fi
}

cancel_pending_rollback() {
  local unit
  if ! unit=$(pending_rollback_unit); then
    [ -f "$PENDING_ROLLBACK_FILE" ] && return 1
    return 0
  fi
  systemctl stop "$unit.timer" >/dev/null 2>&1 || true
  if ! systemd_unit_quiescent "$unit.timer"; then
    warn "Rollback timer $unit.timer could not be cancelled."
    return 1
  fi
  systemctl stop "$unit.service" >/dev/null 2>&1 || true
  if ! systemd_unit_quiescent "$unit.service"; then
    warn "Rollback service $unit.service could not be stopped."
    return 1
  fi
  rm -f -- "$PENDING_ROLLBACK_FILE"
}

schedule_rollback() {
  local rollback_unit
  install -d -m 0700 "$DATA_DIR"
  cancel_pending_rollback || die "Existing rollback state could not be cancelled safely."
  rollback_unit="outline-warp-rollback-$(date +%s)-$$"
  systemd-run --quiet --unit="$rollback_unit" --on-active=10m \
    --property=Restart=on-failure --property=RestartSec=30s \
    "$INSTALL_PATH" _rollback ||
    die "Could not schedule the remote safety rollback; WARP was not started."
  printf '%s\n' "$rollback_unit" >"$PENDING_ROLLBACK_FILE"
  chmod 0600 "$PENDING_ROLLBACK_FILE"
  if ! systemd_unit_active "$rollback_unit.timer"; then
    systemctl stop "$rollback_unit.timer" >/dev/null 2>&1 || true
    rm -f -- "$PENDING_ROLLBACK_FILE"
    die "Rollback timer did not become active; WARP was not started."
  fi
}

start_with_rollback() {
  schedule_rollback
  systemctl reset-failed outline-warp.service >/dev/null 2>&1 || true
  if ! systemctl start outline-warp.service || ! check_runtime; then
    stop_service_fail_open ||
      die "WARP start failed and automatic teardown is incomplete; use the cloud console."
    cancel_pending_rollback || true
    die "WARP failed validation and was rolled back to native routing."
  fi
  info "Candidate is healthy locally. Automatic native-route rollback remains armed for 10 minutes."
}

rollback_action() {
  [ -f "$PENDING_ROLLBACK_FILE" ] || return 0
  warn "Candidate confirmation expired; removing WARP and keeping native routing."
  stop_managed_controls || return 1
  managed_network_is_down || return 1
  rm -f -- "$PENDING_ROLLBACK_FILE"
  info "Candidate rollback completed."
}

stop_managed_controls() {
  local health_was_active
  health_was_active=0
  systemd_unit_active outline-warp-health.timer && health_was_active=1
  systemctl stop outline-warp-health.timer >/dev/null 2>&1 || true
  if systemd_unit_active outline-warp-health.timer; then
    warn "outline-warp-health.timer could not be stopped."
    return 1
  fi

  if systemd_unit_active outline-warp.service || [ -f "$RUN_DIR/owned" ]; then
    if ! stop_service_fail_open; then
      [ "$health_was_active" -eq 1 ] && systemctl start outline-warp-health.timer >/dev/null 2>&1 || true
      warn "Existing managed WARP state could not be removed safely."
      return 1
    fi
  fi
  if systemd_unit_active outline-warp.service; then
    [ "$health_was_active" -eq 1 ] && systemctl start outline-warp-health.timer >/dev/null 2>&1 || true
    warn "outline-warp.service is still active."
    return 1
  fi
  systemctl disable outline-warp.service >/dev/null 2>&1 || true
  systemctl disable outline-warp-health.timer >/dev/null 2>&1 || true
  if systemd_unit_enabled outline-warp.service || systemd_unit_enabled outline-warp-health.timer; then
    warn "Managed WARP units could not be disabled."
    return 1
  fi
}

stop_legacy_wgcf() {
  systemctl disable wg-quick@wgcf.service >/dev/null 2>&1 || true
  systemctl stop wg-quick@wgcf.service >/dev/null 2>&1 || true
  if systemd_unit_enabled wg-quick@wgcf.service; then
    die "Legacy wg-quick@wgcf.service could not be disabled."
  fi
  if systemd_unit_active wg-quick@wgcf.service; then
    die "Legacy wg-quick@wgcf.service could not be stopped."
  fi
  if ip link show "$INTERFACE" >/dev/null 2>&1; then
    wg-quick down "$WG_CONF" >/dev/null 2>&1 || true
  fi
  if ip link show "$INTERFACE" >/dev/null 2>&1; then
    die "Existing $INTERFACE interface could not be stopped. Inspect it before continuing."
  fi
}

install_action() {
  require_root
  require_yes
  validate_installer_source
  require_supported_os
  acquire_admin_lock
  ensure_install_paths_owned
  preflight_networkd_policy
  check_conflicting_warp
  make_backup
  install_dependencies
  install_wgcf
  prepare_managed_profile
  stop_managed_controls || die "Existing managed WARP controls could not be stopped."
  cancel_pending_rollback || die "Existing rollback state is invalid or active."
  stop_legacy_wgcf
  assert_reserved_space_clear
  install_self
  install_prepared_profile
  install_networkd_policy
  write_systemd_units
  start_with_rollback
  info "Candidate installation completed; boot enablement is still off."
  info "From a second connection, verify SSH and Outline TCP/UDP, then run:"
  info "  sudo $INSTALL_PATH confirm --yes"
  info "Backup: $LATEST_BACKUP"
}

disable_action() {
  require_root
  require_yes
  acquire_admin_lock
  ensure_install_paths_owned
  stop_managed_controls || die "Managed WARP teardown is incomplete."
  managed_network_is_down || die "Managed WARP teardown could not be verified."
  cancel_pending_rollback || die "Pending rollback could not be cancelled."
  info "WARP disabled. Configuration and credentials were retained."
}

enable_action() {
  require_root
  require_yes
  require_supported_os
  acquire_admin_lock
  ensure_install_paths_owned
  preflight_networkd_policy
  check_conflicting_warp
  if ! file_has_managed_marker "$WG_CONF"; then
    die "Managed $WG_CONF is missing."
  fi
  stop_managed_controls || die "Managed WARP teardown is incomplete."
  managed_network_is_down || die "Managed WARP teardown could not be verified."
  cancel_pending_rollback || die "Pending rollback could not be cancelled."
  systemctl daemon-reload
  start_with_rollback
  info "WARP candidate started. Verify externally, then run confirm --yes within 10 minutes."
}

repair_action() {
  require_root
  require_yes
  require_supported_os
  acquire_admin_lock
  ensure_install_paths_owned
  preflight_networkd_policy
  check_conflicting_warp
  if ! file_has_managed_marker "$WG_CONF"; then
    die "Managed $WG_CONF is missing."
  fi
  stop_managed_controls || die "Managed WARP teardown is incomplete."
  managed_network_is_down || die "Managed WARP teardown could not be verified."
  cancel_pending_rollback || die "Pending rollback could not be cancelled."
  systemctl daemon-reload
  start_with_rollback
  printf '0\n' >"$HEALTH_FAILURE_FILE"
  info "WARP candidate repaired. Verify externally, then run confirm --yes within 10 minutes."
}

confirm_action() {
  local rollback_unit
  require_root
  require_yes
  require_supported_os
  acquire_admin_lock
  ensure_install_paths_owned
  preflight_networkd_policy
  rollback_unit=$(pending_rollback_unit) ||
    die "No valid candidate rollback is pending; run install, enable, or repair first."
  systemd_unit_active "$rollback_unit.timer" ||
    die "Candidate rollback timer is no longer active; do not enable this state."
  systemd_unit_active outline-warp.service || die "WARP candidate is not active."
  check_runtime || die "WARP candidate failed local validation; rollback remains armed."

  if ! systemctl enable outline-warp.service >/dev/null; then
    die "Could not enable outline-warp.service; rollback remains armed."
  fi
  if ! systemctl enable --now outline-warp-health.timer >/dev/null; then
    systemctl disable outline-warp.service >/dev/null 2>&1 || true
    die "Could not enable the health timer; rollback remains armed."
  fi
  if ! systemd_unit_enabled outline-warp.service ||
    ! systemd_unit_enabled outline-warp-health.timer ||
    ! systemd_unit_active outline-warp-health.timer; then
    systemctl disable --now outline-warp-health.timer >/dev/null 2>&1 || true
    systemctl disable outline-warp.service >/dev/null 2>&1 || true
    die "Persistent units did not reach the expected state; rollback remains armed."
  fi
  check_runtime || {
    systemctl disable --now outline-warp-health.timer >/dev/null 2>&1 || true
    systemctl disable outline-warp.service >/dev/null 2>&1 || true
    die "Final runtime check failed; rollback remains armed."
  }
  if ! cancel_pending_rollback; then
    systemctl disable --now outline-warp-health.timer >/dev/null 2>&1 || true
    systemctl disable outline-warp.service >/dev/null 2>&1 || true
    stop_service_fail_open ||
      die "Rollback cancellation and owned WARP teardown both failed; use the cloud console."
    die "Rollback timer could not be cancelled; persistent enablement was removed and WARP was stopped."
  fi
  if ! systemd_unit_active outline-warp.service || ! check_runtime; then
    systemctl disable --now outline-warp-health.timer >/dev/null 2>&1 || true
    systemctl disable outline-warp.service >/dev/null 2>&1 || true
    stop_service_fail_open ||
      die "Post-confirmation validation failed and owned teardown is incomplete."
    die "Post-confirmation validation failed; WARP was returned to native routing."
  fi
  info "WARP confirmed, enabled for boot, and monitored by the health timer."
}

remove_managed_wgcf() {
  local sha
  [ -f "$WGCF_BIN" ] || return 0
  sha=$(sha256sum "$WGCF_BIN" | awk '{print $1}')
  case "$sha" in
    "$WGCF_AMD64_SHA256"|"$WGCF_ARM64_SHA256") rm -f -- "$WGCF_BIN" ;;
    *) warn "Unexpected $WGCF_BIN was retained."; return 1 ;;
  esac
  rmdir "$LIB_DIR" >/dev/null 2>&1 || true
}

uninstall_action() {
  local stamp original
  require_root
  require_yes
  acquire_admin_lock
  ensure_install_paths_owned
  if [ -e "$WG_CONF" ] && ! file_has_managed_marker "$WG_CONF"; then
    die "Refusing to uninstall while $WG_CONF is not managed by this project."
  fi
  original=""
  if [ -f "$ORIGINAL_PROFILE_POINTER" ]; then
    original=$(cat "$ORIGINAL_PROFILE_POINTER" 2>/dev/null || true)
    original=$(readlink -f -- "$original" 2>/dev/null || true)
    case "$original" in
      "$BACKUP_ROOT"/*/wgcf.conf) [ -f "$original" ] || die "Original profile backup is missing: $original" ;;
      *) die "Invalid original profile backup pointer." ;;
    esac
  fi
  stamp="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  install -d -m 0700 "$BACKUP_ROOT/$stamp"
  if [ -f "$WG_CONF" ]; then
    cp -a "$WG_CONF" "$BACKUP_ROOT/$stamp/wgcf.conf"
  fi
  if [ -f "$ACCOUNT_FILE" ]; then
    cp -a "$ACCOUNT_FILE" "$BACKUP_ROOT/$stamp/wgcf-account.toml"
  fi

  stop_managed_controls || die "Managed WARP teardown is incomplete; files were retained."
  managed_network_is_down || die "Managed WARP teardown could not be verified; files were retained."
  cancel_pending_rollback || die "Pending rollback could not be cancelled."

  remove_managed_file "$SERVICE_FILE"
  remove_managed_file "$HEALTH_SERVICE_FILE"
  remove_managed_file "$HEALTH_TIMER_FILE"
  remove_managed_file "$NETWORKD_DROPIN"
  if [ -f "$WG_CONF" ]; then
    rm -f -- "$WG_CONF"
  fi

  if [ -n "$original" ]; then
    install -m 0600 "$original" "$WG_CONF"
    rm -f -- "$ORIGINAL_PROFILE_POINTER"
    info "Original wgcf profile restored but left disabled."
  fi

  rm -rf -- "$RUN_DIR" "$DATA_DIR"
  remove_managed_wgcf || true
  if [ "$PURGE_CREDENTIALS" -eq 1 ]; then
    rm -rf -- "$STATE_DIR"
    info "Project WARP credentials were removed from active paths; root-only backup retained at $BACKUP_ROOT/$stamp."
  else
    info "Credentials retained at $ACCOUNT_FILE."
  fi
  systemctl daemon-reload
  remove_managed_file "$INSTALL_PATH"
  info "Uninstalled. Debian packages were retained because they may be shared."
}

status_action() {
  local rc rollback_unit
  printf 'outline-warp-safe version: %s\n' "$VERSION"
  printf 'service enabled: '
  systemctl is-enabled outline-warp.service 2>/dev/null || true
  printf 'service active: '
  systemctl is-active outline-warp.service 2>/dev/null || true
  printf 'health timer active: '
  systemctl is-active outline-warp-health.timer 2>/dev/null || true
  if rollback_unit=$(pending_rollback_unit 2>/dev/null); then
    if systemd_unit_active "$rollback_unit.timer"; then
      printf 'candidate rollback armed: %s.timer\n' "$rollback_unit"
    else
      printf 'candidate rollback armed: stale state; run disable or enable --yes\n'
    fi
  else
    printf 'candidate rollback armed: no\n'
  fi
  if ip link show "$INTERFACE" >/dev/null 2>&1; then
    wg show "$INTERFACE" latest-handshakes || true
    ip -4 rule show | awk '$1+0>=11000 && $1+0<11100'
    ip -6 rule show | awk '$1+0>=11100 && $1+0<11200'
    set +e
    check_runtime
    rc=$?
    set -e
    if [ "$rc" -eq 0 ]; then
      info "Runtime validation passed."
    else
      warn "Runtime validation failed with code $rc."
      return "$rc"
    fi
  else
    warn "$INTERFACE is not active."
    return 1
  fi
}

check_action() {
  require_root
  check_runtime
  info "WARP handshake, dual-stack trace, endpoint route, and native return routes passed."
}

main() {
  parse_args "$@"
  case "$ACTION" in
    plan) print_plan ;;
    install) install_action ;;
    status) require_root; status_action ;;
    check) check_action ;;
    repair) repair_action ;;
    disable) disable_action ;;
    enable) enable_action ;;
    confirm) confirm_action ;;
    uninstall) uninstall_action ;;
    _service_up) require_root; acquire_runtime_lock; service_up ;;
    _service_down) require_root; acquire_runtime_lock; service_down ;;
    _policy_up) require_root; policy_up ;;
    _policy_down) require_root; policy_down ;;
    _rollback) require_root; acquire_admin_lock; rollback_action ;;
    _health_monitor)
      require_root
      if try_admin_lock; then
        health_monitor
      else
        info "Administrative action is running; health check skipped."
      fi
      ;;
    help|-h|--help) usage ;;
    *) usage; die "Unknown action: $ACTION" ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
