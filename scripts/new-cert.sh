#!/bin/sh
# Mint a leaf certificate for a new hostname, signed by the local CA.
#
#   sudo sh new-cert.sh photos.casa
#
# Writes into the proxy's certs directory and leaves the CA key where it is.
# Devices that already trust casa-ca.crt trust the result with no further work —
# that is the whole point of having a CA rather than per-host self-signed certs.
set -eu

[ $# -eq 1 ] || { echo "usage: $0 <hostname>" >&2; exit 1; }
HOST=$1

CA_DIR=${CA_DIR:-/home/umbrel/certs}
OUT_DIR=${OUT_DIR:-/home/umbrel/lan-proxy/certs}
DAYS=${DAYS:-825}

[ -f "$CA_DIR/casa-ca.crt" ] || { echo "error: no CA at $CA_DIR/casa-ca.crt" >&2; exit 1; }
[ -f "$CA_DIR/casa-ca.key" ] || { echo "error: no CA key at $CA_DIR/casa-ca.key" >&2; exit 1; }

mkdir -p "$OUT_DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

openssl req -nodes -newkey rsa:2048 -sha256 \
  -keyout "$TMP/$HOST.key" -out "$TMP/$HOST.csr" \
  -subj "/CN=$HOST" 2>/dev/null

# subjectAltName is not optional: browsers have ignored Common Name for years
# and reject a certificate without a matching SAN.
printf 'subjectAltName = DNS:%s\nextendedKeyUsage = serverAuth\n' "$HOST" > "$TMP/$HOST.ext"

openssl x509 -req -in "$TMP/$HOST.csr" \
  -CA "$CA_DIR/casa-ca.crt" -CAkey "$CA_DIR/casa-ca.key" -CAcreateserial \
  -out "$TMP/$HOST.crt" -days "$DAYS" -sha256 -extfile "$TMP/$HOST.ext" 2>/dev/null

install -m 644 "$TMP/$HOST.crt" "$OUT_DIR/$HOST.crt"
install -m 640 "$TMP/$HOST.key" "$OUT_DIR/$HOST.key"

echo "wrote $OUT_DIR/$HOST.crt and $OUT_DIR/$HOST.key"
echo
echo "next:"
echo "  1. add a block for $HOST to /home/umbrel/lan-proxy/Caddyfile"
echo "  2. add a UniFi local DNS record: $HOST -> the proxy's IP"
echo "  3. sudo systemctl restart lan-proxy"
