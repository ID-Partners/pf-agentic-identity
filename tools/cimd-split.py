#!/usr/bin/env python3
"""Convert the old single CIMD document (OIDF_ATTESTER_CIMD_URL, removed in 0.8.0) into the 0.8.0 shape.

Before 0.8.0 the attester fetched one JSON document from OIDF_ATTESTER_CIMD_URL whose spiffe_mappings
array named, for every client, its SPIFFE ids, its issuer, its evidence type and its trust roots. From
0.8.0 the operator lists each CIMD client in OIDF_CIMD_CLIENTS, keyed by its Client Identifier URL, with
the trust roots in OIDF_CIMD_TRUST_BUNDLES, and each client publishes one Client ID Metadata Document at
that URL in the CAS §6.1 shape, listing only its instances and their ceilings (X-B02, finding F-0067).

This script reads the old document from a file - it never fetches anything - and writes, into --out-dir:
  - one CAS §6.1 document per client, <name>.json, to be served at the client's new URL;
  - oidf-cimd-clients.json, the value of OIDF_CIMD_CLIENTS;
  - oidf-cimd-trust-bundles.json, the value of OIDF_CIMD_TRUST_BUNDLES.

Read this before trusting its output.
  - The trust roots came from an unsigned document: whoever could change it could hand the attester a
    trust root. They are written only with --accept-bundles, and each key's RFC 7638 thumbprint (and
    each jwks_uri) is printed so you can confirm it with the trust domain's owner by a channel other
    than the document. Without the flag the trust-bundles file holds "jwks": "REVIEW" and the script
    exits 3.
  - Each client's subject_prefixes is its SPIFFE ids, each its own entry: never widened to a shared prefix, which
    would admit workloads the old document never named. The attester matches a prefix on a segment boundary, so an
    id admits itself and the paths below it, never a sibling (.../bot never admits .../bot2). An id that is a trust
    domain's root (no path), or carries '*', stops the script. It is the bound on what the client's document may
    list: review it.
  - The client id becomes the URL (CAS §6.2: under CIMD "client_id is an HTTPS URL"). Every client is
    renamed: register it in PingFederate under its new id and rename its OIDF_BRIDGE_SIGNING_KEYS
    entry. The rename table is printed.
  - An entry that carries signing_jwk (a private key) stops the script: move the key to OpenBao and
    name it with signing_key_ref (B04). No private key is ever written.

Usage:
    tools/cimd-split.py --in old.json --out-dir cimd/ --url-template 'https://agents.example/clients/{client_id}'
    tools/cimd-split.py --in old.json --out-dir cimd/ --map renames.txt --accept-bundles
    tools/cimd-split.py --check --out-dir cimd/

--map names a file of 'old_client_id=https://new/url' lines (blank lines and lines starting with '#'
ignored); a client it does not name takes --url-template. --check re-reads --out-dir and validates every
file against the rules the attester applies, for CI. Exit status: 0 done, 1 refused (nothing is
written), 2 usage, 3 written but the trust roots need review.
"""

import argparse
import ipaddress
import json
import os
import re
import sys
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import federation_keys  # noqa: E402 - the RFC 7638 thumbprint, shared with tools/pin-subordinates.py

CLIENTS_FILE = "oidf-cimd-clients.json"
BUNDLES_FILE = "oidf-cimd-trust-bundles.json"
REVIEW = "REVIEW"
MEMBER = "oauth_client_attestation"
DEFAULT_EVIDENCE = "spiffe-jwt"
DEFAULT_TTL = 300
MAX_TTL = 64800

# What the attester (CimdClients, CimdTrustBundles, CimdDocument) accepts.
CLIENT_MEMBERS = {"issuer", "evidence_type", "trust_root", "subject_prefixes", "max_issued_ttl", "signing_key_ref"}
BUNDLE_MEMBERS = {"trust_domain", "evidence_issuer", "jwks", "jwks_uri"}
OBJECT_MEMBERS = {"attester", "issued_ttl", "entitlement", "instances"}
INSTANCE_MEMBERS = {"subject", "spiffe_id", "wallet_instance", "entitlement", "metadata"}
TRUST_MEMBERS = {"instance_trust", "bundle", "bundle_url", "spiffe_trust_bundle", "wallet_providers", "trust_domain",
                 "evidence_type", "evidence_issuer", "issuer", "signing_jwk", "signing_key_ref"}
PRIVATE_JWK_MEMBERS = {"d", "p", "q", "dp", "dq", "qi", "oth", "k"}
# The members of an old spiffe_mappings entry (the pre-0.8.0 CimdClientResolver's javadoc and CimdMapping).
OLD_MEMBERS = {"spiffe_id", "client_id", "issuer", "evidence_type", "trust_domain", "evidence_issuer", "bundle",
               "bundle_url", "signing_key_ref", "signing_jwk", "ttl", "entitlement", "metadata"}
# Evidence types that need no trust bundle (InstanceAttestationValidators: a wallet's trust is its provider's).
NO_BUNDLE_EVIDENCE = {"wallet-instance-attestation"}
# Evidence types whose trust root must name a trust_domain (CloudTokenValidator.requiresTrustDomain; CimdClients
# refuses a trust_root without one for these).
TRUST_DOMAIN_EVIDENCE = {"gke-sa-token", "gcp-id-token", "eks-sa-token", "aws-sts-web-identity", "aks-sa-token",
                         "azure-mi-token"}
# RFC 3986's unreserved, reserved and '%' characters: java.net.URI, which CimdClientId parses with, refuses the rest
# (white space, | { } ^ ` < > \ and the like); non-ASCII is refused here too, so the id is the same bytes everywhere.
URL_CHARS = re.compile(r"[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+")
DNS_LABEL = re.compile(r"[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?")


class Refused(Exception):
    """The input, or a file under --check, breaks a rule; nothing is written."""


def check_client_url(url):
    """The CIMD -02 §3 Client Identifier URL rules, as CimdClientId applies them; raises Refused naming the rule."""
    if not isinstance(url, str) or not url.strip():
        raise Refused("a client identifier URL is required")
    if not URL_CHARS.fullmatch(url):
        raise Refused(f"{url!r} is not a URL (it contains a character RFC 3986 does not allow, white space or"
                      " non-ASCII)")
    try:
        parts = urllib.parse.urlsplit(url)
        parts.port  # noqa: B018 - raises ValueError for a port that is not a number
    except ValueError as e:
        raise Refused(f"{url!r} is not a URL ({e})") from e
    # '[' and ']' only around an IPv6 host literal: java.net.URI refuses them anywhere else.
    if "[" in url or "]" in url:
        netloc = parts.netloc.rpartition("@")[2]
        outside = url.replace(netloc, "", 1) if netloc.startswith("[") else url
        if "[" in outside or "]" in outside or netloc.count("[") > 1 or netloc.count("]") > 1:
            raise Refused(f"{url!r} is not a URL ('[' and ']' are allowed only around an IPv6 host)")
    if parts.scheme != "https":
        raise Refused(f"{url!r} must use the https scheme (CIMD §3)")
    if "@" in parts.netloc:
        raise Refused(f"{url!r} must not contain userinfo (CIMD §3)")
    if not parts.hostname or not valid_host(parts.hostname):
        raise Refused(f"{url!r} must name a host (a DNS name or an IP address)")
    if not parts.path:
        raise Refused(f"{url!r} must contain a path component (CIMD §3)")
    for segment in parts.path.split("/"):
        if segment in (".", "..") or decode_once(url, segment) in (".", ".."):
            raise Refused(f"{url!r} must not contain a single-dot or double-dot path segment (CIMD §3)")
    if parts.query or "?" in url:
        raise Refused(f"{url!r} must not contain a query component (CIMD §3 SHOULD NOT; the attester refuses it)")
    if parts.fragment or "#" in url:
        raise Refused(f"{url!r} must not contain a fragment component (CIMD §3)")
    return url


def valid_host(host):
    """A host java.net.URI reports from getHost(): an IP literal, or DNS labels whose last starts with a letter."""
    try:
        ipaddress.ip_address(host)
        return True
    except ValueError:
        pass
    labels = host.split(".")
    return all(DNS_LABEL.fullmatch(label) for label in labels) and labels[-1][0].isalpha()


def decode_once(url, segment):
    """A path segment percent-decoded once; a '%' that does not start a valid escape is refused, as the attester does."""
    if re.search(r"%(?![0-9A-Fa-f]{2})", segment):
        raise Refused(f"{url!r} must not contain a malformed percent-encoding in its path")
    # An escape that is not UTF-8 decodes to U+FFFD, as the attester's decoder does, so it is never a dot segment.
    return urllib.parse.unquote(segment, errors="replace")


def has_private_key(value):
    """Whether a JWK - an object with kty - anywhere under value carries a private member."""
    if isinstance(value, dict):
        if "kty" in value and PRIVATE_JWK_MEMBERS & set(value):
            return True
        return any(has_private_key(v) for v in value.values())
    if isinstance(value, list):
        return any(has_private_key(v) for v in value)
    return False


def jwks_has_private(jwks):
    """Whether any key of a JWK Set carries a private member, with or without kty (CimdTrustBundles.hasPrivateMember)."""
    keys = jwks.get("keys") if isinstance(jwks, dict) else None
    return isinstance(keys, list) and any(isinstance(k, dict) and PRIVATE_JWK_MEMBERS & set(k) for k in keys)


def check_trust_root(name, root):
    """The problems the attester (CimdTrustBundles) would find in one trust root; REVIEW is the caller's to handle."""
    problems = []
    if set(root) - BUNDLE_MEMBERS:
        problems.append(f"trust root {name!r}: members not allowed: {', '.join(sorted(set(root) - BUNDLE_MEMBERS))}")
    if ("jwks" in root) == ("jwks_uri" in root):
        problems.append(f"trust root {name!r}: must have exactly one of jwks and jwks_uri")
    elif "jwks" in root:
        keys = root["jwks"].get("keys") if isinstance(root["jwks"], dict) else None
        if not isinstance(keys, list) or not keys or not all(isinstance(k, dict) for k in keys):
            problems.append(f"trust root {name!r}: jwks must be a JWK Set with at least one key")
        elif jwks_has_private(root["jwks"]):
            problems.append(f"trust root {name!r}: jwks holds a private key member")
    else:
        uri = root["jwks_uri"]
        try:
            parts = urllib.parse.urlsplit(uri) if isinstance(uri, str) else None
            host = parts.hostname if parts else None
        except ValueError:
            parts, host = None, None
        if not parts or parts.scheme != "https" or not host:
            problems.append(f"trust root {name!r}: jwks_uri must be an https URL with a host")
    return problems


def authority_root(subject):
    """Whether a subject names a whole trust domain (spiffe://td or spiffe://td/), which as a prefix admits all of it."""
    rest = subject.split("://", 1)[1] if "://" in subject else subject
    return not rest.partition("/")[2].strip("/")


def exact_prefixes(subjects):
    """The client's SPIFFE ids as its subject_prefixes, each exact, sorted; None when one is a trust domain's root or
    carries '*', or when they span trust domains (a client has one trust root)."""
    domains = set()
    for subject in subjects:
        if not subject.startswith("spiffe://") or "*" in subject or authority_root(subject):
            return None
        domains.add(subject[len("spiffe://"):].split("/", 1)[0])
    if len(domains) != 1:
        return None
    return sorted(set(subjects))


def file_name(old_id, used):
    """A file name for a client's document from its old id: safe characters only, unique in the directory."""
    base = re.sub(r"[^A-Za-z0-9._-]", "_", old_id).strip("._") or "client"
    name, n = base, 2
    # Case-insensitive: on macOS and Windows 'OIDF-CIMD-CLIENTS.json' is the clients setting's file.
    while name.lower() in used or name.lower() in (CLIENTS_FILE[:-5].lower(), BUNDLES_FILE[:-5].lower()):
        name, n = f"{base}-{n}", n + 1
    used.add(name.lower())
    return name + ".json"


def read_map(path):
    mapping = {}
    with open(path, encoding="utf-8") as f:
        for number, line in enumerate(f, 1):
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            old, sep, url = line.partition("=")
            if not sep or not old.strip() or not url.strip():
                raise Refused(f"{path}:{number}: expected old_client_id=https://new/url")
            if old.strip() in mapping:
                raise Refused(f"{path}:{number}: {old.strip()} is mapped twice")
            mapping[old.strip()] = url.strip()
    return mapping


def new_url(old_id, mapping, template):
    if old_id in mapping:
        url = mapping[old_id]
    elif template:
        url = template.replace("{client_id}", urllib.parse.quote(old_id, safe=""))
    else:
        raise Refused(f"client {old_id!r} is not in --map and there is no --url-template")
    try:
        return check_client_url(url)
    except Refused as e:
        raise Refused(f"client {old_id!r}: its new URL {e}") from e


def same(entries, key, old_id):
    """The one value every entry of a client gives for key (None when none gives it); refused when they differ."""
    values = [json.dumps(e.get(key), sort_keys=True) for e in entries]
    if len(set(values)) > 1:
        raise Refused(f"client {old_id!r}: its entries give different values for {key!r}; one CIMD client has one"
                      f" {key} - split it into two clients in the input first")
    return entries[0].get(key)


def ttl_of(entries, old_id):
    ttls = [e["ttl"] for e in entries if e.get("ttl") is not None]
    for ttl in ttls:
        if isinstance(ttl, bool) or not isinstance(ttl, (int, float)) or ttl != int(ttl) or not 1 <= ttl <= MAX_TTL:
            raise Refused(f"client {old_id!r}: ttl must be a whole number of seconds from 1 to {MAX_TTL}")
    if not ttls:
        return None
    # The shortest, when the entries differ: one document has one issued_ttl, and shorter never widens anything. An
    # entry with no ttl had the old resolver's default, so it counts as that default and is never lengthened.
    if len(ttls) < len(entries):
        ttls.append(DEFAULT_TTL)
    return int(min(ttls))


def root_key(entry):
    return entry.get("trust_domain") or entry.get("evidence_issuer")


def convert(old, mapping, template, default_issuer=None):
    """The documents, the clients setting, the trust bundles and the rename table for an old document."""
    if not isinstance(old, dict) or not isinstance(old.get("spiffe_mappings"), list):
        raise Refused("the input has no 'spiffe_mappings' array: it is not an OIDF_ATTESTER_CIMD_URL document")
    grouped = {}
    for i, entry in enumerate(old["spiffe_mappings"]):
        where = f"spiffe_mappings[{i}]"
        if not isinstance(entry, dict):
            raise Refused(f"{where} is not a JSON object")
        if "signing_jwk" in entry:
            raise Refused(f"{where} (client {entry.get('client_id')!r}) carries signing_jwk, a private key: move this"
                          " key to OpenBao; see B04 - and name it with signing_key_ref. Nothing was written")
        unknown = sorted(set(entry) - OLD_MEMBERS)
        if unknown:
            raise Refused(f"{where} has members the old resolver never read: {', '.join(unknown)}")
        for key in ("client_id", "spiffe_id"):
            if not isinstance(entry.get(key), str) or not entry[key].strip():
                raise Refused(f"{where} has no {key}")
        if "bundle" in entry and "bundle_url" in entry:
            raise Refused(f"{where} has both bundle and bundle_url")
        if has_private_key(entry.get("bundle")) or jwks_has_private(entry.get("bundle")):
            raise Refused(f"{where}'s bundle holds a private key member: a trust root holds public keys only")
        if has_private_key(entry):
            raise Refused(f"{where} (client {entry.get('client_id')!r}) holds a private key member in its metadata or"
                          " entitlement: its document is published at the client's URL, so it holds no private key."
                          " Nothing was written")
        grouped.setdefault(entry["client_id"], []).append(entry)
    if not grouped:
        raise Refused("spiffe_mappings is empty: nothing to convert")

    documents, clients, bundles, renames, used, review = [], {}, {}, [], set(), []
    for old_id, entries in grouped.items():
        url = new_url(old_id, mapping, template)
        if url in clients:
            raise Refused(f"client {old_id!r}: its new URL {url} is already another client's")
        subjects = [e["spiffe_id"] for e in entries]
        if len(set(subjects)) != len(subjects):
            raise Refused(f"client {old_id!r} lists a spiffe_id twice")
        issuer = same(entries, "issuer", old_id) or default_issuer
        if not issuer:
            raise Refused(f"client {old_id!r} names no issuer: pass --issuer with the attester's issuer")
        evidence = same(entries, "evidence_type", old_id) or DEFAULT_EVIDENCE
        signing_key_ref = same(entries, "signing_key_ref", old_id)
        for key in ("trust_domain", "evidence_issuer", "bundle", "bundle_url"):
            same(entries, key, old_id)
        prefixes = exact_prefixes(subjects)
        if prefixes is None:
            raise Refused(f"client {old_id!r}: its SPIFFE ids ({', '.join(subjects)}) must each name a workload (not a"
                          " trust domain's root, no '*') in one trust domain; split it into one client per trust domain"
                          " first")
        ttl = ttl_of(entries, old_id)

        policy = {"issuer": issuer}
        if evidence != DEFAULT_EVIDENCE:
            policy["evidence_type"] = evidence
        name = root_key(entries[0])
        if evidence in TRUST_DOMAIN_EVIDENCE and not entries[0].get("trust_domain"):
            raise Refused(f"client {old_id!r}: its evidence type {evidence} needs a trust_domain, and its entries name"
                          " none")
        if name:
            root = {k: entries[0][k] for k in ("trust_domain", "evidence_issuer") if entries[0].get(k)}
            if "bundle" in entries[0]:
                root["jwks"] = entries[0]["bundle"]
            elif "bundle_url" in entries[0]:
                root["jwks_uri"] = entries[0]["bundle_url"]
            if name in bundles and bundles[name] != root:
                raise Refused(f"trust root {name!r}: two clients give it different bundles")
            bundles[name] = root
            policy["trust_root"] = name
        elif evidence not in NO_BUNDLE_EVIDENCE:
            raise Refused(f"client {old_id!r} names no trust_domain or evidence_issuer, and its evidence type needs a"
                          " trust root")
        policy["subject_prefixes"] = prefixes
        if ttl is not None and ttl > DEFAULT_TTL:
            policy["max_issued_ttl"] = ttl
        if signing_key_ref:
            policy["signing_key_ref"] = signing_key_ref
        clients[url] = policy

        entitlements = [json.dumps(e.get("entitlement"), sort_keys=True) for e in entries]
        shared = entries[0].get("entitlement") if len(set(entitlements)) == 1 else None
        cas = {"attester": issuer}
        if ttl is not None:
            cas["issued_ttl"] = ttl
        if shared is not None:
            cas["entitlement"] = shared
        instances = []
        for e in entries:
            instance = {"subject": e["spiffe_id"]}
            # With the client-level ceiling the same, an instance without one inherits it (AttestationIssuanceConfig).
            if e.get("entitlement") is not None and shared is None:
                instance["entitlement"] = e["entitlement"]
            if e.get("metadata") is not None:
                instance["metadata"] = e["metadata"]
            instances.append(instance)
        cas["instances"] = instances
        document = {"client_id": url, MEMBER: cas}
        # What --check would refuse is never written: the same rules, on the document before it exists.
        problems = check_document(document, policy, prefixes, policy.get("max_issued_ttl", DEFAULT_TTL))
        if problems:
            raise Refused(f"client {old_id!r}: its document would break the attester's rules: {'; '.join(problems)}")
        documents.append((file_name(old_id, used), document))
        renames.append((old_id, url))

    for name, root in bundles.items():
        if "jwks" not in root and "jwks_uri" not in root:
            review.append(f"trust root {name!r}: the old document gave no bundle or bundle_url; supply one")
            continue
        # A trust root the attester would refuse is never written, accepted or not.
        problems = check_trust_root(name, root)
        if problems:
            raise Refused(f"{'; '.join(problems)}. Nothing was written")
    return documents, clients, bundles, renames, review


def bundle_report(bundles, out):
    for name, root in bundles.items():
        if "jwks_uri" in root:
            print(f"  {name}: jwks_uri {root['jwks_uri']} - fetched at issuance; confirm with its owner that it is"
                  " theirs", file=out)
        keys = root.get("jwks", {}).get("keys", []) if isinstance(root.get("jwks"), dict) else []
        for key in keys:
            print(f"  {name}: kid={key.get('kid')} kty={key.get('kty')} RFC 7638 thumbprint="
                  f"{federation_keys.thumbprint(key) or '(unsupported kty)'}", file=out)


def write_json(path, value):
    with open(path, "w", encoding="utf-8") as f:
        json.dump(value, f, indent=2, ensure_ascii=False)
        f.write("\n")


def split(args, out, err):
    try:
        with open(args.input, encoding="utf-8") as f:
            old = json.load(f)
    except (OSError, ValueError) as e:
        raise Refused(f"cannot read {args.input}: {e}") from e
    mapping = read_map(args.map) if args.map else {}
    documents, clients, bundles, renames, review = convert(old, mapping, args.url_template, args.issuer)
    unused = sorted(set(mapping) - {old_id for old_id, _ in renames})
    if unused:
        raise Refused(f"--map names clients the input does not: {', '.join(unused)}")

    os.makedirs(args.out_dir, exist_ok=True)
    for name, document in documents:
        write_json(os.path.join(args.out_dir, name), document)
    write_json(os.path.join(args.out_dir, CLIENTS_FILE), clients)
    accepted = args.accept_bundles and not review
    written = bundles if accepted else {name: {**{k: v for k, v in root.items() if k not in ("jwks", "jwks_uri")},
                                               "jwks": REVIEW} for name, root in bundles.items()}
    write_json(os.path.join(args.out_dir, BUNDLES_FILE), written)

    print("Rename table - register each client in PingFederate under its new id, rename its OIDF_BRIDGE_SIGNING_KEYS"
          " entry, and serve its document at that URL:", file=out)
    for (old_id, url), (name, _) in zip(renames, documents):
        print(f"  {old_id} -> {url}    ({name})", file=out)
    print("Subject prefixes - each is the bound on what that client's document may list; review them:", file=out)
    for url, policy in clients.items():
        print(f"  {url}: {', '.join(policy['subject_prefixes'])}", file=out)
    if bundles:
        print("Trust roots - confirm each with its owner by a channel other than the old document:", file=err)
        bundle_report(bundles, err)
    for line in review:
        print(line, file=err)
    if bundles and not accepted:
        print(f"{BUNDLES_FILE} holds \"jwks\": \"{REVIEW}\" - confirm the trust roots above, then run again with"
              " --accept-bundles (or fill them in by hand)", file=err)
        return 3
    return 0


def check(out_dir, out):
    """Every file in out_dir against the attester's rules; the problems found, empty when none."""
    problems = []

    def load(name):
        try:
            with open(os.path.join(out_dir, name), encoding="utf-8") as f:
                return json.load(f)
        except (OSError, ValueError) as e:
            problems.append(f"{name}: cannot read it ({e})")
            return None

    clients = load(CLIENTS_FILE)
    bundles = load(BUNDLES_FILE)
    if not isinstance(clients, dict) or not isinstance(bundles, dict):
        if clients is not None and bundles is not None:
            problems.append(f"{CLIENTS_FILE} and {BUNDLES_FILE} must each be a JSON object")
        return problems
    for name, root in bundles.items():
        if not isinstance(root, dict):
            problems.append(f"trust root {name!r}: must be a JSON object")
            continue
        if root.get("jwks") == REVIEW:
            problems.append(f"trust root {name!r}: still \"{REVIEW}\" - confirm it and run with --accept-bundles")
            if set(root) - BUNDLE_MEMBERS:
                problems.append(f"trust root {name!r}: members not allowed:"
                                f" {', '.join(sorted(set(root) - BUNDLE_MEMBERS))}")
        else:
            problems.extend(check_trust_root(name, root))

    documents = {}
    for name in sorted(os.listdir(out_dir)):
        if name.endswith(".json") and name not in (CLIENTS_FILE, BUNDLES_FILE):
            document = load(name)
            if isinstance(document, dict):
                documents.setdefault(document.get("client_id"), []).append((name, document))
            elif document is not None:
                problems.append(f"{name}: not a JSON object")

    for url, policy in clients.items():
        where = f"client {url}"
        try:
            check_client_url(url)
        except Refused as e:
            problems.append(f"{where}: {e}")
        if not isinstance(policy, dict):
            problems.append(f"{where}: must be a JSON object")
            continue
        if set(policy) - CLIENT_MEMBERS:
            problems.append(f"{where}: members not allowed: {', '.join(sorted(set(policy) - CLIENT_MEMBERS))}")
        if not policy.get("issuer"):
            problems.append(f"{where}: issuer is required")
        root = policy.get("trust_root")
        if root is None and policy.get("evidence_type") not in NO_BUNDLE_EVIDENCE:
            problems.append(f"{where}: trust_root is required for its evidence type")
        elif root is not None and root not in bundles:
            problems.append(f"{where}: trust_root {root!r} names no member of {BUNDLES_FILE}")
        elif (root is not None and policy.get("evidence_type") in TRUST_DOMAIN_EVIDENCE
              and not (isinstance(bundles[root], dict) and bundles[root].get("trust_domain"))):
            problems.append(f"{where}: trust_root {root!r} names no trust_domain, which its evidence type requires")
        prefixes = policy.get("subject_prefixes")
        if not isinstance(prefixes, list) or not prefixes or not all(isinstance(p, str) and p.strip() for p in prefixes):
            problems.append(f"{where}: subject_prefixes must be a non-empty array of strings")
            prefixes = []
        elif any("*" in p for p in prefixes):
            problems.append(f"{where}: subject_prefixes may not contain '*'")
        elif any(p.startswith("spiffe://") and authority_root(p) for p in prefixes):
            problems.append(f"{where}: subject_prefixes may not name a whole trust domain (spiffe://<td>/)")
        max_ttl = policy.get("max_issued_ttl", DEFAULT_TTL)
        if isinstance(max_ttl, bool) or not isinstance(max_ttl, int) or not 1 <= max_ttl <= MAX_TTL:
            problems.append(f"{where}: max_issued_ttl must be a whole number of seconds from 1 to {MAX_TTL}")
            max_ttl = DEFAULT_TTL
        found = documents.pop(url, [])
        if len(found) != 1:
            problems.append(f"{where}: {len(found)} documents in {out_dir} have this client_id; it needs exactly one")
            continue
        problems.extend(f"{found[0][0]}: {p}" for p in check_document(found[0][1], policy, prefixes, max_ttl))
    for url, found in documents.items():
        for name, _ in found:
            problems.append(f"{name}: client_id {url!r} is not a key of {CLIENTS_FILE}")
    for problem in problems:
        print(problem, file=out)
    return problems


def check_document(document, policy, prefixes, max_ttl):
    problems = []
    if "client_secret" in document or "client_secret_expires_at" in document:
        problems.append("client_secret and client_secret_expires_at must not be used (CIMD §4.1)")
    if has_private_key(document):
        problems.append("private key material must not be included (CIMD §4.1)")
    cas = document.get(MEMBER)
    if not isinstance(cas, dict):
        return problems + [f"{MEMBER} is required and must be a JSON object (CAS §6.1)"]
    for where, obj, allowed in [(MEMBER, cas, OBJECT_MEMBERS)] + [
            ("an instance", i, INSTANCE_MEMBERS) for i in cas.get("instances", []) if isinstance(i, dict)]:
        if TRUST_MEMBERS & set(obj):
            problems.append(f"CAS §6.2 rule 3: {where} has {', '.join(sorted(TRUST_MEMBERS & set(obj)))}")
        elif set(obj) - allowed:
            problems.append(f"{where} has members CAS §6.1 does not allow: {', '.join(sorted(set(obj) - allowed))}")
    if cas.get("attester") is not None and cas["attester"] != policy.get("issuer"):
        problems.append("attester does not name this client's issuer")
    ttl = cas.get("issued_ttl")
    if ttl is not None and (isinstance(ttl, bool) or not isinstance(ttl, int) or not 1 <= ttl <= max_ttl):
        problems.append(f"issued_ttl must be a whole number of seconds from 1 to the client's max_issued_ttl ({max_ttl})")
    instances = cas.get("instances")
    if not isinstance(instances, list) or not instances:
        return problems + ["instances must be a non-empty array (CAS §6.1)"]
    for instance in instances:
        if not isinstance(instance, dict):
            problems.append("each instance must be a JSON object")
            continue
        subjects = [instance[a] for a in ("subject", "spiffe_id", "wallet_instance") if a in instance]
        if len(subjects) != 1 or not isinstance(subjects[0], str) or not subjects[0].strip():
            problems.append("each instance names its subject once, as a non-empty string")
        elif not any(subjects[0].startswith(p) for p in prefixes):
            problems.append(f"instance {subjects[0]} is outside the client's subject prefixes")
    return problems


def main(argv=None, out=sys.stdout, err=sys.stderr):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("--in", dest="input", help="the old OIDF_ATTESTER_CIMD_URL document, as a file")
    parser.add_argument("--out-dir", required=True, help="where the documents and the two settings are written")
    parser.add_argument("--url-template", help="each client's new URL, with {client_id} for its old id")
    parser.add_argument("--map", help="a file of old_client_id=https://new/url lines; wins over --url-template")
    parser.add_argument("--issuer", help="the attester's issuer, for entries that name none")
    parser.add_argument("--accept-bundles", action="store_true",
                        help="write the trust roots the old document gave, once you have confirmed them")
    parser.add_argument("--check", action="store_true", help="validate --out-dir and write nothing")
    args = parser.parse_args(argv)
    if args.check:
        problems = check(args.out_dir, err)
        if problems:
            return 1
        print(f"{args.out_dir}: every document and both settings pass", file=out)
        return 0
    if not args.input or not (args.url_template or args.map):
        parser.error("--in and one of --url-template and --map are required, unless --check")
    try:
        return split(args, out, err)
    except Refused as e:
        print(f"refused: {e}", file=err)
        return 1


if __name__ == "__main__":
    sys.exit(main())
