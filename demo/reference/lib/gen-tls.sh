#!/usr/bin/env bash
# A reference stack's TLS: one CA per stack instance and a leaf for each server, from openssl with this script's own
# configuration (as tools/ci/start-tls-redis.sh does), so OpenSSL 3 on a runner and on a Mac make the same
# certificates.
#
#   gen-tls.sh DIR NAME=SAN[,SAN...] ...
#
# DIR/ca.crt and DIR/ca.key: kept once made - C7's recording SET receiver is issued from the same CA, and every
#   leaf a later run issues chains to it. The key never leaves DIR.
# DIR/NAME.crt and DIR/NAME.key for each NAME: reissued when its SAN list changes (DIR/NAME.sans records it), kept
#   otherwise. A SAN that is all digits and dots is an IP address, anything else a DNS name.
# DIR/NAME.p12 and DIR/NAME.p12.pass for the leaf named pf: PingFederate imports its server certificate as
#   PKCS#12 (reference/terraform's runtime certificate).
#
# Keys are 0600, certificates 0644, DIR 0700. Nothing is printed but the names of what was made or kept.
set -euo pipefail
dir="${1:?usage: gen-tls.sh DIR NAME=SAN[,SAN...] ...}"
shift
umask 077
mkdir -p "$dir"
chmod 700 "$dir"
dir="$(cd "$dir" && pwd)"
log="$dir/openssl.log"
: > "$log"
ssl() { openssl "$@" 2>>"$log" || { echo "openssl $1 failed:" >&2; cat "$log" >&2; exit 1; }; }

cat > "$dir/req.cnf" <<'CNF'
[req]
distinguished_name = dn
prompt = no
[dn]
CN = pf-agentic-identity reference stack CA
[ca]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, keyCertSign, cRLSign
subjectKeyIdentifier = hash
CNF

if [[ -f "$dir/ca.crt" && -f "$dir/ca.key" ]]; then
  echo "kept      ca.crt"
else
  ssl req -x509 -new -config "$dir/req.cnf" -extensions ca -newkey rsa:3072 -nodes -days 825 \
    -subj "/CN=pf-agentic-identity reference CA $(basename "$dir")" -keyout "$dir/ca.key" -out "$dir/ca.crt"
  chmod 644 "$dir/ca.crt"
  rm -f "$dir"/*.sans
  echo "generated ca.crt"
fi

for spec in "$@"; do
  name="${spec%%=*}"
  sans="${spec#*=}"
  [[ "$name" =~ ^[a-z0-9-]+$ && -n "$sans" && "$spec" == *=* ]] || { echo "ERROR: '$spec' is not NAME=SAN[,SAN...]" >&2; exit 2; }
  ext="$(printf '%s' "$sans" | tr ',' '\n' | awk 'NF { print (/^[0-9.]+$/ ? "IP:" : "DNS:") $0 }' | paste -sd, -)"
  if [[ -f "$dir/$name.crt" && -f "$dir/$name.key" && "$(cat "$dir/$name.sans" 2>/dev/null)" == "$ext" ]] \
     && openssl verify -CAfile "$dir/ca.crt" "$dir/$name.crt" >/dev/null 2>&1; then
    echo "kept      $name.crt ($ext)"
    continue
  fi
  cat > "$dir/$name.ext" <<EXT
subjectAltName = $ext
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
EXT
  cn="${sans%%,*}"
  ssl req -new -newkey rsa:2048 -nodes -subj "/CN=$cn" -keyout "$dir/$name.key" -out "$dir/$name.csr"
  ssl x509 -req -in "$dir/$name.csr" -CA "$dir/ca.crt" -CAkey "$dir/ca.key" -set_serial "0x$(openssl rand -hex 12)" \
    -days 397 -extfile "$dir/$name.ext" -out "$dir/$name.crt"
  rm -f "$dir/$name.csr" "$dir/$name.ext"
  chmod 644 "$dir/$name.crt"
  printf '%s' "$ext" > "$dir/$name.sans"
  if [[ "$name" == pf ]]; then
    openssl rand -hex 16 > "$dir/pf.p12.pass"
    ssl pkcs12 -export -inkey "$dir/pf.key" -in "$dir/pf.crt" -certfile "$dir/ca.crt" -name pf-reference-tls \
      -passout "file:$dir/pf.p12.pass" -out "$dir/pf.p12"
  fi
  echo "generated $name.crt ($ext)"
done
rm -f "$dir/req.cnf"
