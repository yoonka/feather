#!/bin/sh
set -eu

# ── Feather Mail installer ─────────────────────────────
# Ships inside the release tarball. Run from the extracted directory:
#   sudo ./install.sh          # install with defaults
#   sudo ./install.sh remove   # uninstall (preserves config & logs)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Defaults — override with env vars
FEATHER_USER="${FEATHER_USER:-feather}"
FEATHER_GROUP="${FEATHER_GROUP:-feather}"
FEATHER_LOG="${FEATHER_LOG:-/var/log/feather}"

UNAME="$(uname -s)"
case "$UNAME" in
  FreeBSD)
    FEATHER_PREFIX="${FEATHER_PREFIX:-/usr/local}"
    FEATHER_CONF="${FEATHER_CONF:-${FEATHER_PREFIX}/etc/feather}"
    ;;
  *)
    FEATHER_PREFIX="${FEATHER_PREFIX:-/opt}"
    FEATHER_CONF="${FEATHER_CONF:-/etc/feather}"
    ;;
esac

INSTALL_DIR="${FEATHER_PREFIX}/feather"

# ── Helpers ─────────────────────────────────────────────

info()  { printf "\033[1;34m=>\033[0m %s\n" "$1"; }
ok()    { printf "\033[1;32m=>\033[0m %s\n" "$1"; }
warn()  { printf "\033[1;33m=>\033[0m %s\n" "$1"; }
err()   { printf "\033[1;31m=>\033[0m %s\n" "$1" >&2; exit 1; }

need_root() {
  [ "$(id -u)" -eq 0 ] || err "This script must be run as root."
}

# ── Create system user ──────────────────────────────────

create_user() {
  case "$UNAME" in
    FreeBSD)
      if ! pw usershow "$FEATHER_USER" >/dev/null 2>&1; then
        info "Creating user $FEATHER_USER"
        pw adduser "$FEATHER_USER" -d /nonexistent -s /usr/sbin/nologin -c "Feather Mail"
      fi
      ;;
    *)
      if ! id -u "$FEATHER_USER" >/dev/null 2>&1; then
        info "Creating user $FEATHER_USER"
        useradd --system --no-create-home --shell /usr/sbin/nologin "$FEATHER_USER"
      fi
      ;;
  esac
}

# ── Install service file ────────────────────────────────

install_service() {
  case "$UNAME" in
    FreeBSD)
      info "Installing rc.d script"
      install -m 0555 "${SCRIPT_DIR}/feather.rc" "${FEATHER_PREFIX}/etc/rc.d/feather"
      ;;
    *)
      info "Installing systemd unit"
      install -m 0644 "${SCRIPT_DIR}/feather.service" /etc/systemd/system/feather.service
      systemctl daemon-reload
      ;;
  esac
}

# ── Remove service file ─────────────────────────────────

remove_service() {
  case "$UNAME" in
    FreeBSD)
      service feather stop 2>/dev/null || true
      rm -f "${FEATHER_PREFIX}/etc/rc.d/feather"
      ;;
    *)
      systemctl stop feather 2>/dev/null || true
      systemctl disable feather 2>/dev/null || true
      rm -f /etc/systemd/system/feather.service
      systemctl daemon-reload
      ;;
  esac
}

# ── Install ─────────────────────────────────────────────

do_install() {
  need_root

  if [ ! -f "${SCRIPT_DIR}/bin/feather" ]; then
    err "bin/feather not found. Run this script from inside the extracted release directory."
  fi

  create_user

  info "Creating directories"
  install -d -o "$FEATHER_USER" -g "$FEATHER_GROUP" -m 0750 "$INSTALL_DIR"
  install -d -o "$FEATHER_USER" -g "$FEATHER_GROUP" -m 0750 "$FEATHER_CONF"
  install -d -o "$FEATHER_USER" -g "$FEATHER_GROUP" -m 0750 "$FEATHER_LOG"

  info "Copying release to $INSTALL_DIR"
  cp -r "${SCRIPT_DIR}/." "$INSTALL_DIR/"
  chown -R "$FEATHER_USER":"$FEATHER_GROUP" "$INSTALL_DIR"

  if [ -d "${SCRIPT_DIR}/examples" ] && [ ! -f "${FEATHER_CONF}/server.exs" ]; then
    info "Installing example config to $FEATHER_CONF"
    cp "${SCRIPT_DIR}/examples/server.exs" "$FEATHER_CONF/server.exs"
    cp "${SCRIPT_DIR}/examples/pipeline.exs" "$FEATHER_CONF/pipeline.exs"
    chown -R "$FEATHER_USER":"$FEATHER_GROUP" "$FEATHER_CONF"
  elif [ -f "${FEATHER_CONF}/server.exs" ]; then
    warn "Config already exists in $FEATHER_CONF, skipping"
  fi

  install_service

  ok "Feather installed to $INSTALL_DIR"
  echo ""
  echo "  Config:  $FEATHER_CONF"
  echo "  Logs:    $FEATHER_LOG"
  echo ""
  echo "Next steps:"
  echo "  1. Edit $FEATHER_CONF/server.exs and pipeline.exs"
  case "$UNAME" in
    FreeBSD)
      echo "  2. sysrc feather_enable=YES"
      echo "  3. service feather start"
      ;;
    *)
      echo "  2. systemctl enable feather"
      echo "  3. systemctl start feather"
      ;;
  esac
}

# ── Uninstall ───────────────────────────────────────────

do_remove() {
  need_root

  remove_service

  info "Removing $INSTALL_DIR"
  rm -rf "$INSTALL_DIR"

  ok "Feather uninstalled"
  warn "Config ($FEATHER_CONF) and logs ($FEATHER_LOG) preserved. Remove manually if needed."
}

# ── Main ────────────────────────────────────────────────

case "${1:-install}" in
  install)  do_install ;;
  remove)   do_remove  ;;
  *)        echo "Usage: $0 [install|remove]"; exit 1 ;;
esac
