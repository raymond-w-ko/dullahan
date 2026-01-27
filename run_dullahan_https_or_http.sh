#!/usr/bin/env -S bash -exu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXE="$HOME/bin/dullahan"

if [[ ! -x "$EXE" ]]; then
    echo "Error: $EXE not found or not executable" >&2
    exit 1
fi

CERT_DIR="$SCRIPT_DIR/cert"
CERT_FILE=("$CERT_DIR"/*.crt)
KEY_FILE=("$CERT_DIR"/*.key)

if [[ -f "${CERT_FILE[0]}" && -f "${KEY_FILE[0]}" ]]; then
    exec "$EXE" serve --background --tls-cert="${CERT_FILE[0]}" --tls-key="${KEY_FILE[0]}"
else
    echo "No certs found in $CERT_DIR, starting HTTP mode" >&2
    exec "$EXE" serve --background
fi
