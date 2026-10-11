#!/usr/bin/env bash
# An EC P-256 private JWK (ES256, kid its RFC 7638 thumbprint) from openssl, for the mdm profile's
# ENROLMENT_SIGNING_JWK. Kept once made; 0600; never printed.
#
#   gen-ec-jwk.sh OUT
set -euo pipefail
out="${1:?usage: gen-ec-jwk.sh OUT}"
[[ -s "$out" ]] && { echo "kept      $(basename "$out")"; exit 0; }
umask 077
openssl ecparam -name prime256v1 -genkey -noout 2>/dev/null | openssl ec -text -noout 2>/dev/null | python3 -c '
import base64, hashlib, json, re, sys
text = sys.stdin.read()
def block(name):
    m = re.search(name + r":\s*\n((?:\s+[0-9a-f:]+\n)+)", text)
    return bytes.fromhex(re.sub(r"[\s:]", "", m.group(1)))
b64 = lambda b: base64.urlsafe_b64encode(b).rstrip(b"=").decode()
priv, pub = block("priv"), block("pub")
priv = priv[-32:].rjust(32, b"\0")
assert pub[0] == 4 and len(pub) == 65, "not an uncompressed P-256 point"
jwk = {"kty": "EC", "crv": "P-256", "x": b64(pub[1:33]), "y": b64(pub[33:])}
kid = b64(hashlib.sha256(json.dumps(jwk, separators=(",", ":"), sort_keys=True).encode()).digest())
jwk.update({"d": b64(priv), "use": "sig", "alg": "ES256", "kid": kid})
print(json.dumps(jwk, separators=(",", ":")))' > "$out"
echo "generated $(basename "$out")"
