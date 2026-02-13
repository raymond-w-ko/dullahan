#!/usr/bin/env bash
set -euo pipefail

log() {
  printf '[autorun] %s\n' "$*" >&2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DULLAHAN_BIN="${DULLAHAN_BIN:-$SCRIPT_DIR/dullahan}"
PORT="${DULLAHAN_PORT:-7681}"
RUNTIME_BASE="${XDG_RUNTIME_DIR:-/tmp}"
RUNTIME_DIR="${DULLAHAN_RUNTIME_DIR:-$RUNTIME_BASE/dullahan-$(id -u)}"
CERT_DIR="${DULLAHAN_CERT_DIR:-$RUNTIME_DIR/certs}"
HOME_DIR="${HOME:-$(cd ~ 2>/dev/null && pwd || true)}"

mkdir -p "$CERT_DIR"

if [[ ! -x "$DULLAHAN_BIN" ]]; then
  if command -v dullahan >/dev/null 2>&1; then
    DULLAHAN_BIN="$(command -v dullahan)"
  else
    log "dullahan binary not found or not executable: $DULLAHAN_BIN"
    exit 1
  fi
fi

if [[ -z "$HOME_DIR" || ! -d "$HOME_DIR" ]]; then
  log "Could not resolve a valid home directory for server working directory"
  exit 1
fi

resolve_hostname() {
  local resolved=""

  # 1) Tailscale hostname via non-admin status command
  if command -v tailscale >/dev/null 2>&1; then
    resolved="$(tailscale status --self --json 2>/dev/null | awk -F'"' '/"DNSName"/ { print $4; exit }' || true)"
    if [[ -z "$resolved" ]]; then
      resolved="$(tailscale status --json 2>/dev/null | awk -F'"' '/"DNSName"/ { print $4; exit }' || true)"
    fi
    resolved="${resolved%.}"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  # 2) hostnamectl fallback
  if command -v hostnamectl >/dev/null 2>&1; then
    resolved="$(hostnamectl --static 2>/dev/null | head -n 1 | xargs || true)"
    if [[ -n "$resolved" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  # 3) hostname fallback
  resolved="$(hostname 2>/dev/null | head -n 1 | xargs || true)"
  if [[ -n "$resolved" ]]; then
    printf '%s\n' "$resolved"
    return 0
  fi

  printf 'localhost\n'
}

generate_fallback_cert() {
  local host="$1"
  local cert_file="$2"
  local key_file="$3"
  local days="${DULLAHAN_CERT_DAYS:-365}"
  local san="DNS:${host},DNS:localhost,IP:127.0.0.1"

  if ! command -v openssl >/dev/null 2>&1; then
    log "openssl is required to generate fallback certificates"
    return 1
  fi

  # Prefer SAN-enabled cert. Fall back to basic self-signed if -addext is unsupported.
  if openssl req -x509 -newkey rsa:2048 -sha256 -days "$days" -nodes \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${host}" \
    -addext "subjectAltName=${san}" >/dev/null 2>&1; then
    return 0
  fi

  openssl req -x509 -newkey rsa:2048 -sha256 -days "$days" -nodes \
    -keyout "$key_file" \
    -out "$cert_file" \
    -subj "/CN=${host}" >/dev/null
}

HOSTNAME_VALUE="$(resolve_hostname)"
log "Resolved hostname: $HOSTNAME_VALUE"

CERT_HOST_BASENAME="$(printf '%s' "$HOSTNAME_VALUE" | sed 's/[^A-Za-z0-9._-]/-/g')"
if [[ -z "$CERT_HOST_BASENAME" ]]; then
  CERT_HOST_BASENAME="localhost"
fi

SOURCE_CERT="$CERT_DIR/tailscale-cert.pem"
SOURCE_KEY="$CERT_DIR/tailscale-key.pem"
CERT_SOURCE="tailscale"

if command -v tailscale >/dev/null 2>&1 && [[ "$HOSTNAME_VALUE" == *.ts.net ]]; then
  log "Attempting to fetch real Tailscale cert for $HOSTNAME_VALUE"
  if ! tailscale cert --cert-file "$SOURCE_CERT" --key-file "$SOURCE_KEY" "$HOSTNAME_VALUE" >/dev/null 2>&1; then
    CERT_SOURCE="openssl-fallback"
  fi
else
  CERT_SOURCE="openssl-fallback"
fi

if [[ "$CERT_SOURCE" == "openssl-fallback" ]]; then
  SOURCE_CERT="$CERT_DIR/fallback-cert.pem"
  SOURCE_KEY="$CERT_DIR/fallback-key.pem"
  log "Using OpenSSL fallback cert generation"
  generate_fallback_cert "$HOSTNAME_VALUE" "$SOURCE_CERT" "$SOURCE_KEY"
fi

# Always run with a cert filename that includes the resolved hostname so
# server startup URLs use the best guessed host.
TLS_CERT="$CERT_DIR/${CERT_HOST_BASENAME}.pem"
TLS_KEY="$CERT_DIR/${CERT_HOST_BASENAME}.key.pem"
cp -f "$SOURCE_CERT" "$TLS_CERT"
cp -f "$SOURCE_KEY" "$TLS_KEY"

log "Switching working directory to $HOME_DIR"
cd "$HOME_DIR"

log "Starting dullahan HTTPS server in background on port $PORT (${CERT_SOURCE})"
"$DULLAHAN_BIN" serve -d \
  --port="$PORT" \
  --tls-cert="$TLS_CERT" \
  --tls-key="$TLS_KEY"

log "Started. URL: https://${HOSTNAME_VALUE}:${PORT}"
