#!/usr/bin/env bash
# Throwaway TLS material for the rig's SPIRE entry reader (docker-compose.spire.yml): two certificate authorities,
# the reader's server certificate, and two client certificates for smoke.sh. Nothing is written to the repository:
# everything goes under the state directory, which is git-ignored (conformance/.gitignore, .spire/).
#
#   conformance/spire/gen-certs.sh [STATE_DIR]      default conformance/.spire, or SPIRE_RIG_STATE
#
# What it makes, under STATE_DIR (an existing set is kept while its certificates have a day left, and made again
# when they do not; delete STATE_DIR to start again):
#
#   ca/            mode 0700: server-ca.{crt,key}, the reader's server authority; client-ca.{crt,key}, the authority
#                  the reader's clients chain to. B08 issues PingFederate's client certificate from client-ca.
#   reader-tls/    mounted read-only into the reader: server.crt and server.key (EC P-256, PKCS#8, as
#                  OIDF_SPIRE_READER_TLS_KEY_FILE requires) for the names spire-reader and localhost, and
#                  client-ca.crt. The directory and the key are world-readable because the reader runs as 65532,
#                  not as you; the state directory above them is 0700, so on the host only you can reach them.
#   client/        smoke.sh's clients: smoke.{crt,key}, whose key is pinned, and stranger.{crt,key}, issued by the
#                  same authority and not pinned; server-ca.crt to verify the reader with. 0755, keys 0644, for the
#                  same reason (a curl container reads them as another user).
#   reader.env     OIDF_SPIRE_READER_CLIENT_SPKI_SHA256: the smoke client's key, as the reader pins it (the SHA-256 of
#                  its SubjectPublicKeyInfo, hex). B08 adds PingFederate's.
#
# Needs openssl (1.1.1 or 3.x). The certificates last 30 days.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
state="${1:-${SPIRE_RIG_STATE:-$here/../.spire}}"
days=30

# A set that is still good for a day is kept; one that is not, or is incomplete, is made again from nothing.
fresh() { openssl x509 -in "$1" -noout -checkend 86400 > /dev/null 2>&1; }
if [[ -f "$state/reader.env" ]] && fresh "$state/reader-tls/server.crt" && fresh "$state/client/smoke.crt" \
    && fresh "$state/client/stranger.crt"; then
  echo "gen-certs.sh: keeping the TLS material in $state"
  exit 0
fi
if [[ -e "$state/reader.env" || -e "$state/ca" ]]; then
  echo "gen-certs.sh: the TLS material in $state expires within a day or is incomplete; making it again"
  rm -rf "$state/ca" "$state/reader-tls" "$state/client" "$state/reader.env"
fi

umask 077
mkdir -p "$state/ca" "$state/reader-tls" "$state/client"
chmod 0700 "$state" "$state/ca"
chmod 0755 "$state/reader-tls" "$state/client"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

key() { openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$1" 2>/dev/null; }

# ca NAME CN: a self-signed authority, ca/NAME.{crt,key}.
ca() {
  key "$state/ca/$1.key"
  printf '%s\n' '[x]' 'basicConstraints=critical,CA:TRUE,pathlen:0' 'keyUsage=critical,keyCertSign,cRLSign' \
    'subjectKeyIdentifier=hash' > "$tmp/$1.ext"
  openssl req -new -key "$state/ca/$1.key" -subj "/O=pf-agentic-identity rig/CN=$2" -out "$tmp/$1.csr"
  openssl x509 -req -in "$tmp/$1.csr" -signkey "$state/ca/$1.key" -days "$days" -sha256 \
    -extfile "$tmp/$1.ext" -extensions x -set_serial "0x$(openssl rand -hex 16)" -out "$state/ca/$1.crt" 2>/dev/null
}

# leaf CA OUT CN USAGE [SAN]: a certificate from ca/CA for the key OUT.key, written to OUT.crt.
leaf() {
  local ca="$1" out="$2" cn="$3" usage="$4" san="${5:-}"
  key "$out.key"
  { printf '%s\n' '[x]' 'basicConstraints=critical,CA:FALSE' 'keyUsage=critical,digitalSignature' \
      "extendedKeyUsage=$usage" 'authorityKeyIdentifier=keyid'
    if [[ -n "$san" ]]; then printf 'subjectAltName=%s\n' "$san"; fi; } > "$tmp/leaf.ext"
  openssl req -new -key "$out.key" -subj "/O=pf-agentic-identity rig/CN=$cn" -out "$tmp/leaf.csr"
  openssl x509 -req -in "$tmp/leaf.csr" -CA "$state/ca/$ca.crt" -CAkey "$state/ca/$ca.key" -days "$days" -sha256 \
    -extfile "$tmp/leaf.ext" -extensions x -set_serial "0x$(openssl rand -hex 16)" -out "$out.crt" 2>/dev/null
}

ca server-ca "spire-entry-reader rig server CA"
ca client-ca "spire-entry-reader rig client CA"
leaf server-ca "$state/reader-tls/server" spire-reader serverAuth "DNS:spire-reader,DNS:localhost,IP:127.0.0.1"
cp "$state/ca/client-ca.crt" "$state/reader-tls/client-ca.crt"
leaf client-ca "$state/client/smoke" smoke-client clientAuth
leaf client-ca "$state/client/stranger" stranger-client clientAuth
cp "$state/ca/server-ca.crt" "$state/client/server-ca.crt"

spki() { openssl x509 -in "$1" -pubkey -noout | openssl pkey -pubin -outform DER | openssl dgst -sha256 -r | cut -d' ' -f1; }
printf 'OIDF_SPIRE_READER_CLIENT_SPKI_SHA256=%s\n' "$(spki "$state/client/smoke.crt")" > "$state/reader.env"

# Keys 0644 on purpose: the reader (65532) and the smoke curl container read them as other users, and a non-root host
# user cannot chown to them. The protection is the state directory, 0700, which only you can enter (see the header).
chmod 0644 "$state/reader-tls/"* "$state/client/"*
chmod 0600 "$state/ca/"* "$state/reader.env"
echo "gen-certs.sh: wrote the reader's TLS material to $state"
