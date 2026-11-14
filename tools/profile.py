#!/usr/bin/env python3
"""One profile file for an agentic IdP deployment: render it, check it, author its config archive (phase 2 of
private/plans/agentic-idp-profiles.md).

  tools/profile.py render <profile> [--out DIR] [--base-url URL] [--set PATH=VALUE]... [--no-terraform]
  tools/profile.py check  <profile>... [--base-url URL] [--set PATH=VALUE]... [--no-terraform]
  tools/profile.py author <profile> [--out DIR] [--base-url URL] [--set PATH=VALUE]... [--image REF]
                          [--material-dir DIR] [--secrets FILE] [--age-recipient R [--age-image REF]] [--keep]

<profile> is a path or a name under profiles/. A profile names the features a deployment runs (profiles/*.yaml,
validated against tools/profile/schema.json after its extends chain is merged). Two halves follow from it, and they
must agree: PingFederate's configuration, from deploy/terraform/agentic-idp, and the modules' OIDF_* settings.

render writes, into .local/<name>/ (git-ignored) unless --out says otherwise:
  terraform.tfvars.json   the root's inputs, without what is kept as material: runtime_tls, trusted_cas, secrets and
                          the conformance clients' JWKS, which author adds from the profile's material block
  vars.env                the deployment's environment: the Terraform env output (planned offline against no
                          PingFederate: empty state, -refresh=false), then the settings the profile
                          implies that have no PingFederate object, then the profile's env block. No secrets
  stage-profile           the build/pingfederate/stage-modules.sh --profile the image needs
check runs the schema, the combination rules, the settings catalogues (every OIDF_* name generated is one a
catalogue declares; production refuses a forbidden value, a risky one accepted_risks does not list or lists without
the expiry a dated risk needs, and a required-in-production setting a switched-on component is left without - each
judged as platform.settings judges it, on the values the entry's governed member names), the PingFederate version
(tools/pf-version-check.py) and the Terraform root's own validations (a bad combination fails its plan). author is what
conformance/up.sh and reference/lib/author.sh call, for any profile: a fresh local PingFederate, the
root applied with fresh state, the archive exported and checked for what the profile's features need, and optionally
age-encrypted.

--no-terraform leaves out the Terraform env output and the root's validations, for a machine without terraform;
everything else is checked. Python standard library plus PyYAML.
"""
import argparse
import base64
import copy
import importlib.util
import json
import os
import re
import secrets as token
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.request
import ssl

try:
    import yaml
except ImportError:  # pragma: no cover - the message is the point
    sys.exit("tools/profile.py needs PyYAML: python3 -m pip install pyyaml")

TOOLS = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(TOOLS)
SCHEMA = os.path.join(TOOLS, "profile", "schema.json")
PROFILES = os.path.join(REPO, "profiles")
TF_ROOT = "deploy/terraform/agentic-idp"
EXTENDED = "docs/extended-properties.json"
# This repository's layout, then the public tree's (tools/public-export/manifest.txt): its image build is image/.
PF_VERSION_ENVS = ("build/pf-version.env", "image/pf-version.env")
MODULES_DIRS = ("build/pingfederate/modules", "image/modules")


def first(repo, candidates):
    for rel in candidates:
        if os.path.exists(os.path.join(repo, rel)):
            return os.path.join(repo, rel)
    return os.path.join(repo, candidates[0])


def _load_tool(name, file):
    path = os.path.join(TOOLS, file)
    if not os.path.isfile(path):
        return None
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


# The settings catalogues and the version check are this repository's: the public tree has neither the reactor the
# catalogues live in nor these two tools, and check says what it leaves out there.
scan = _load_tool("settings_scan", "settings-scan.py") if os.path.isfile(os.path.join(REPO, "pom.xml")) else None
pfversion = _load_tool("pf_version_check", "pf-version-check.py")


class Refused(Exception):
    def __init__(self, problems):
        super().__init__("\n".join(problems))
        self.problems = problems


# --- loading ---------------------------------------------------------------------------------------------------

def resolve(arg):
    """A path, or a name under profiles/."""
    if os.path.sep in arg or arg.endswith((".yaml", ".yml")):
        return os.path.abspath(arg)
    return os.path.join(PROFILES, arg + ".yaml")


def merge(base, over):
    """over laid on base: mappings merge key by key, anything else (lists too) is replaced."""
    if isinstance(base, dict) and isinstance(over, dict):
        out = dict(base)
        for k, v in over.items():
            out[k] = merge(base[k], v) if k in base else copy.deepcopy(v)
        return out
    return copy.deepcopy(over)


def load(path, _seen=(), own=False):
    """The profile at path with its extends chain merged under it (own: the file's own content alone, for --with);
    Refused for a file that cannot be used."""
    name = os.path.splitext(os.path.basename(path))[0]
    if path in _seen:
        raise Refused([f"{name}: extends itself through {' -> '.join(os.path.basename(p) for p in _seen)}"])
    try:
        with open(path, encoding="utf-8") as f:
            doc = yaml.safe_load(f)
    except OSError as e:
        raise Refused([f"{path}: cannot be read: {e.strerror}"])
    except yaml.YAMLError as e:
        raise Refused([f"{path}: not YAML: {e}"])
    if not isinstance(doc, dict):
        raise Refused([f"{path}: not a mapping"])
    if doc.get("profile") != name:
        raise Refused([f"{path}: profile is {doc.get('profile')!r}; a profile is named as its file is ({name})"])
    parent = doc.get("extends")
    if parent is None or own:
        return doc
    if not isinstance(parent, str):
        raise Refused([f"{path}: extends is not a profile name"])
    merged = merge(load(os.path.join(os.path.dirname(path), parent + ".yaml"), _seen + (path,)), doc)
    merged["profile"], merged["extends"] = name, parent
    if "description" not in doc:
        merged.pop("description", None)
    return merged


# --- the schema: the subset of JSON Schema schema.json uses --------------------------------------------------

TYPES = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}


def _is(value, t):
    if t == "integer":
        return isinstance(value, int) and not isinstance(value, bool)
    return isinstance(value, TYPES[t])


def validate(value, schema, root=None, path="$"):
    root = root or schema
    if "$ref" in schema:
        schema = root["$defs"][schema["$ref"].rsplit("/", 1)[1]]
    problems = []
    types = schema.get("type")
    if types is not None:
        types = types if isinstance(types, list) else [types]
        if not any(_is(value, t) for t in types):
            return [f"{path}: is {type(value).__name__}, not {' or '.join(types)}"]
    if "enum" in schema and value not in schema["enum"]:
        return [f"{path}: {value!r} is not one of {', '.join(map(str, schema['enum']))}"]
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0):
            problems.append(f"{path}: is empty")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            problems.append(f"{path}: {value!r} does not match {schema['pattern']}")
    if _is(value, "integer") and "minimum" in schema and value < schema["minimum"]:
        problems.append(f"{path}: {value} is below {schema['minimum']}")
    if _is(value, "integer") and "maximum" in schema and value > schema["maximum"]:
        problems.append(f"{path}: {value} is above {schema['maximum']}")
    if isinstance(value, list):
        if schema.get("uniqueItems") and len({json.dumps(v, sort_keys=True) for v in value}) != len(value):
            problems.append(f"{path}: has a repeated item")
        for i, item in enumerate(value):
            problems += validate(item, schema.get("items", {}), root, f"{path}[{i}]")
    if isinstance(value, dict):
        for k in schema.get("required", []):
            if k not in value:
                problems.append(f"{path}: has no {k}")
        props = schema.get("properties", {})
        extra = schema.get("additionalProperties", True)
        for k, v in value.items():
            if k in props:
                problems += validate(v, props[k], root, f"{path}.{k}")
            elif extra is False:
                problems.append(f"{path}: {k} is not a setting a profile has")
            elif isinstance(extra, dict):
                problems += validate(v, extra, root, f"{path}.{k}")
    return problems


def schema_problems(profile):
    with open(SCHEMA, encoding="utf-8") as f:
        return validate(profile, json.load(f))


# --- the Terraform inputs ----------------------------------------------------------------------------------------

DEFAULT_NAMING = {"id": "agenticIdp", "display": "Agentic IdP"}
CIBA_SIM = {"plugin_id": "cibaSim", "descriptor_id": "com.pingidentity.ps.oidf.cibasim.SimOobAuthenticator"}


def features(profile):
    return profile.get("features") or {}


def ssf_objects(profile):
    """Whether modules/ssf is applied: the transmitter on, with its clients and scopes."""
    ssf = features(profile).get("ssf")
    return ssf is not None and ssf.get("transmitter", True) and ssf.get("pf_objects", True)


def tfvars(profile, repo=REPO):
    """The root's inputs from the profile, without the material (runtime_tls, trusted_cas, secrets, conformance.jwks)."""
    pf, f = profile["pf"], features(profile)
    naming = pf.get("naming", DEFAULT_NAMING)
    out = {
        "pf_base_url": pf["base_url"],
        "pf_product_version": read_kv(first(repo, PF_VERSION_ENVS))["PF_TERRAFORM_PRODUCT_VERSION"],
    }
    if "naming" in pf:
        out["naming"] = naming
    for k in ("scopes", "user_token_mapping", "openid_connect", "smoke_client"):
        if k in pf:
            out[k] = pf[k]
    if pf.get("extended_properties"):
        with open(os.path.join(repo, EXTENDED), encoding="utf-8") as fh:
            out["extended_properties"] = json.load(fh)["extended_properties"]
    if "postgres" in pf:
        out["postgres"] = dict(pf["postgres"], client_storage=pf.get("client_storage") == "jdbc")

    tf = {}
    if "fapi2" in f:
        x = f["fapi2"]
        tf["fapi2"] = {"par_status": x.get("par", "required").upper(),
                       "dpop_require_nonce": x.get("dpop_require_nonce", False),
                       "clients": x.get("clients", []), "resource_clients": x.get("resource_clients", [])}
    if "attestation" in f:
        x = f["attestation"]
        tf["attestation"] = {"auth_enabled": x.get("auth", True), "issuer_enabled": x.get("issuer", False)}
    if "federation" in f:
        x = f["federation"]
        tf["federation"] = {"auto_registration": x.get("auto_registration", True), "hosting": x.get("hosting", False)}
        if "operator_api" in x:
            tf["federation"]["operator_api"] = x["operator_api"]
    if "ciba" in f:
        x = f["ciba"]
        if x["authenticator"] == "sim":
            authenticator = dict(CIBA_SIM, name=f"{naming['display']} CIBA simulator")
        else:
            authenticator = x.get("custom")
        tf["ciba"] = {"authenticator": authenticator}
        if "transaction_lifetime" in x:
            tf["ciba"]["transaction_lifetime"] = x["transaction_lifetime"]
    if ssf_objects(profile):
        tf["ssf"] = {"emitter": f["ssf"].get("emitter", False)}
    out["features"] = tf

    c = profile.get("conformance")
    if c is not None:
        conf = {k: c[k] for k in ("suite_base_urls", "suite_alias", "ssf_receiver", "cimd_client_id", "attester", "fapi2_attestation") if k in c}
        if "ciba" in c:
            conf["ciba"] = c["ciba"]
        out["conformance"] = conf
    return out


def material_names(profile):
    m = profile.get("material") or {}
    return m.get("trusted_cas") or {}, m.get("jwks") or {}, m.get("runtime_tls") or {}


# var.secrets' members (deploy/terraform/agentic-idp/variables.tf).
SECRET_KEYS = ("runtime_tls_password", "postgres_runtime_password", "postgres_clients_password", "smoke_client_secret",
               "ssf_introspection_client_secret", "ssf_emitter_client_secret", "federation_operator_client_secret",
               "test_user_password", "attester_client_secret")
STAND_IN_PEM = "-----BEGIN CERTIFICATE-----\nMIIBAAAA\n-----END CERTIFICATE-----\n"


def stand_ins(profile, variables):
    """Values for the material, enough to plan with: Terraform never sees a real secret at render."""
    cas, jwks, tls = material_names(profile)
    out = {
        "pf_admin_host": "https://localhost:1",
        "pf_admin_password": "stand-in",
        "runtime_tls": {"p12_base64": base64.b64encode(b"stand-in").decode(), "key_id": tls.get("key_id", "pf-runtime-tls")},
        "trusted_cas": {ca: STAND_IN_PEM for ca in cas},
        "secrets": {k: "stand-in" for k in SECRET_KEYS},
    }
    if "conformance" in variables:
        keys = {n: json.dumps({"keys": [{"kty": "EC", "crv": "P-256", "x": n, "y": "y"}]}) for n in jwks}
        out["conformance"] = dict(variables["conformance"], jwks=keys)
    return out


# --- planning the root offline -----------------------------------------------------------------------------------

class Planner:
    """One copy of the Terraform root per process, initialised once, planned per profile with -refresh=false on
    empty state: the provider never connects, so no PingFederate is needed."""

    def __init__(self, repo=REPO):
        self.repo = repo
        self.work = None

    def _run(self, args, extra_env=None):
        r = subprocess.run(args, cwd=self.root, capture_output=True, text=True,
                           env={**os.environ, "TF_IN_AUTOMATION": "1", **(extra_env or {})})
        if r.returncode:
            raise Refused([f"terraform {' '.join(args[1:3])} failed:", *(r.stderr or r.stdout).strip().splitlines()[-25:]])
        return r.stdout

    def _init(self):
        if self.work:
            return
        if shutil.which("terraform") is None:
            raise Refused(["terraform is not on PATH (--no-terraform leaves out what only it can tell)"])
        self.work = tempfile.mkdtemp(prefix="profile-tf-")
        shutil.copytree(os.path.join(self.repo, "deploy/terraform"), os.path.join(self.work, "terraform"),
                        ignore=shutil.ignore_patterns(".terraform", "*.tfstate*", "*.tfvars.json"))
        self.root = os.path.join(self.work, "terraform", "agentic-idp")
        self._run(["terraform", "init", "-backend=false", "-input=false", "-lockfile=readonly"])

    def plan(self, variables, stand_in):
        """(env output, [failed rule messages]). The root's combination rules are variable validations, so a bad
        combination fails the plan: its messages come back as the failed rules, with no env output (None)."""
        self._init()
        for name, value in (("profile.tfvars.json", variables), ("stand-ins.tfvars.json", stand_in)):
            with open(os.path.join(self.root, name), "w", encoding="utf-8") as f:
                json.dump(value, f)
        try:
            self._run(["terraform", "plan", "-refresh=false", "-input=false", "-lock=false", "-no-color",
                       "-out=plan.bin", "-var-file=profile.tfvars.json", "-var-file=stand-ins.tfvars.json"])
        except Refused as e:
            failed = validation_messages(e.problems)
            if not failed:
                raise
            return None, failed
        shown = json.loads(self._run(["terraform", "show", "-json", "plan.bin"]))
        env = shown.get("planned_values", {}).get("outputs", {}).get("env", {}).get("value")
        if env is None:
            raise Refused(["the root's env output is not known at plan; a module's env names a value only an apply sets"])
        failed = []
        for check in shown.get("checks", []):
            if check.get("status") == "fail":
                for inst in check.get("instances", []):
                    failed += inst.get("problems", [{"message": check["address"]["to_display"]}])
        return env, [p["message"] if isinstance(p, dict) else str(p) for p in failed]

    def close(self):
        if self.work:
            shutil.rmtree(self.work, ignore_errors=True)


def validation_messages(lines):
    """The error_message of each "Invalid value for variable" in terraform's (-no-color) output: the paragraph before
    "This was checked by the validation rule"; [] when the output holds no such error."""
    text = "\n".join(l.replace("│", "").strip() for l in lines)
    out = []
    for block in re.split(r"Error: Invalid value for variable", text)[1:]:
        paragraphs = [p.strip().replace("\n", " ") for p in re.split(r"\n\s*\n", block)]
        for i, p in enumerate(paragraphs):
            if p.startswith("This was checked by the validation rule") and i > 0:
                out.append(paragraphs[i - 1])
                break
    return out


# --- the environment ---------------------------------------------------------------------------------------------

def words(xs):
    return ",".join(xs)


EVIDENCE = {
    # evidence type: [(the profile's setting, OIDF_* name)], every one required
    "aws-sts": [("aws.sts_issuers", "OIDF_ATTESTER_AWS_STS_WEB_IDENTITY_ISSUERS"), ("aws.accounts", "OIDF_ATTESTER_AWS_ACCOUNTS")],
    "eks": [("aws.eks_issuers", "OIDF_ATTESTER_EKS_SA_TOKEN_ISSUERS")],
    "azure-mi": [("azure.mi_issuers", "OIDF_ATTESTER_AZURE_MI_TOKEN_ISSUERS"), ("azure.tenants", "OIDF_ATTESTER_AZURE_TENANTS")],
    "aks": [("azure.aks_issuers", "OIDF_ATTESTER_AKS_SA_TOKEN_ISSUERS"), ("azure.tenants", "OIDF_ATTESTER_AZURE_TENANTS")],
    "gcp-id-token": [("gcp.id_token_issuers", "OIDF_ATTESTER_GCP_ID_TOKEN_ISSUERS"), ("gcp.projects", "OIDF_ATTESTER_GCP_PROJECTS")],
    "gke": [("gcp.gke_issuers", "OIDF_ATTESTER_GKE_SA_TOKEN_ISSUERS"), ("gcp.projects", "OIDF_ATTESTER_GCP_PROJECTS")],
    "spire": [("spire.reader_url", "OIDF_ATTESTER_SPIRE_READER_URL"), ("spire.trust_domain", "OIDF_ATTESTER_SPIRE_READER_TRUST_DOMAIN"),
              ("spire.ca_file", "OIDF_ATTESTER_SPIRE_READER_CA_FILE"),
              ("spire.client_key_pair", "OIDF_ATTESTER_SPIRE_READER_CLIENT_KEY_PAIR")],
    "cimd": [("cimd.clients", "OIDF_CIMD_CLIENTS"), ("cimd.trust_bundles", "OIDF_CIMD_TRUST_BUNDLES")],
}
# Settings emitted only when given: left out, the attester's default holds.
OPTIONAL_EVIDENCE = [("azure.managed_identities", "OIDF_ATTESTER_AZURE_MANAGED_IDENTITIES"),
                     ("spire.timeout_ms", "OIDF_ATTESTER_SPIRE_READER_TIMEOUT_MS"),
                     ("spire.failure_mode", "OIDF_ATTESTER_SPIRE_FAILURE_MODE")]


def _get(block, dotted):
    for part in dotted.split("."):
        if not isinstance(block, dict) or part not in block:
            return None
        block = block[part]
    return block


def _setting(value):
    if isinstance(value, list):
        return words(value)
    if isinstance(value, dict):
        return json.dumps(value, separators=(",", ":"))
    return str(value)


def implied_env(profile):
    """The settings the profile implies that no Terraform module outputs: they have no PingFederate object."""
    pf, d, f = profile["pf"], profile["deployment"], features(profile)
    base = pf["base_url"]
    env = {"OIDF_DEPLOYMENT_PROFILE": d["mode"]}
    if d.get("accepted_risks"):
        env["OIDF_ACCEPTED_RISKS"] = words(d["accepted_risks"])
    a = f.get("attestation")
    if a:
        for kind in a.get("evidence", []):
            for path, name in EVIDENCE[kind]:
                value = _get(a, path)
                if value not in (None, [], {}):
                    env[name] = _setting(value)
        for path, name in OPTIONAL_EVIDENCE:
            if _get(a, path) not in (None, [], {}):
                env[name] = _setting(_get(a, path))
        if a.get("signing_key_ref"):
            env["OIDF_ATTESTER_SIGNING_KEY_REF"] = a["signing_key_ref"]
    fed = f.get("federation")
    if fed:
        anchors = [base] if fed.get("self_anchor") else []
        anchors += [t["entity_id"] for t in fed.get("trust_anchors", [])]
        if anchors:
            env["OIDF_FEDERATION_TRUST_ANCHORS"] = words(anchors)
        if fed.get("self_anchor"):
            env["OIDF_FEDERATION_TRUST_CONTROLLER_HOST"] = base
            env["OIDF_FEDERATION_SELF_ANCHOR"] = base
        pinned = {t["entity_id"]: t["jwks"] for t in fed.get("trust_anchors", []) if "jwks" in t}
        if pinned:
            env["OIDF_FEDERATION_TRUST_ANCHOR_JWKS"] = _setting(pinned)
        if fed.get("organization_name"):
            env["OIDF_FEDERATION_ORGANIZATION_NAME"] = fed["organization_name"]
        if fed.get("operator_api") is not None:
            # Both required in production. The origin operators address the operator APIs at is PingFederate's own.
            # modules/federation outputs the audience too, from the same field (the root's default when unset), so a
            # check without Terraform judges the same environment a render with it does.
            env["OIDF_OPERATOR_BASE_URL"] = base
            env["OIDF_OPERATOR_AUDIENCE"] = fed["operator_api"].get("audience", "pf-agentic-identity-operator")
    ssf = f.get("ssf")
    if ssf is not None:
        if not ssf.get("transmitter", True):
            env["OIDF_SSF_ENABLED"] = "false"
        elif not ssf.get("pf_objects", True):
            # The transmitter on without modules/ssf, as the reference stacks run it (phase 1's as-built note).
            env["OIDF_SSF_ENABLED"] = "true"
            env["OIDF_SSF_ISSUER"] = base
        if "receiver" in ssf:
            env["OIDF_SSF_RECEIVER_ENABLED"] = str(ssf["receiver"]).lower()
        # The attestation event families (#338), each on unless the profile switches it off; one left out stays unset.
        for family, on in (ssf.get("attestation_events") or {}).items():
            env["OIDF_SSF_%s_EVENT_ENABLED" % family.upper()] = str(on).lower()
    return env


def assemble(profile, tf_env):
    """Terraform's env, then the profile's implied settings, then its env block (null unsets)."""
    env = dict(tf_env or {})
    env.update(implied_env(profile))
    base = profile["pf"]["base_url"]
    for k, v in (profile.get("env") or {}).items():
        if v is None:
            env.pop(k, None)
        else:
            env[k] = v.replace("{{PF_BASE_URL}}", base)
    return dict(sorted(env.items()))


def stage_profile(profile):
    ciba = features(profile).get("ciba")
    return "conformance" if ciba and ciba["authenticator"] == "sim" else "production"


# --- the rules ---------------------------------------------------------------------------------------------------

def combination_problems(profile):
    """What the schema cannot say: features that need each other, and what production refuses."""
    problems = []
    pf, f, mode = profile["pf"], features(profile), profile["deployment"]["mode"]
    production = mode == "production"
    for name in ("rar", "grant_management"):
        if (f.get(name) or {}).get("enabled"):
            problems.append(f"features.{name}: has no Terraform module yet (deferred in phase 1); leave it disabled")
    if ("federation" in f or "attestation" in f) and not pf.get("extended_properties"):
        problems.append("federation and attestation clients carry extended properties PingFederate drops unless declared"
                        " (F-0041): set pf.extended_properties: true")
    if pf.get("client_storage") == "jdbc" and "postgres" not in pf:
        problems.append("pf.client_storage: jdbc keeps PingFederate's clients in the postgres block's database: add pf.postgres")
    ciba = f.get("ciba")
    if ciba:
        if ciba["authenticator"] == "custom" and "custom" not in ciba:
            problems.append("features.ciba: authenticator custom needs the custom block (plugin_id, name, descriptor_id)")
        if ciba["authenticator"] == "sim" and production:
            problems.append("features.ciba: production refuses authenticator sim, an approval oracle anyone holding an"
                            " auth_req_id can answer; name the real OOB authenticator (custom)")
    ssf = f.get("ssf") or {}
    if ssf.get("emitter") and not ssf_objects(profile):
        problems.append("features.ssf: emitter is one of modules/ssf's clients; it needs the transmitter with pf_objects")
    a = f.get("attestation") or {}
    for kind in a.get("evidence", []):
        missing = [path for path, _name in EVIDENCE[kind] if _get(a, path) in (None, [], {})]
        if missing:
            problems.append(f"features.attestation: evidence {kind} needs {', '.join('attestation.' + m for m in missing)}")
    if a.get("evidence") and not a.get("issuer"):
        problems.append("features.attestation: evidence is what the attester checks; it needs issuer: true")
    if (f.get("fapi2") or {}).get("dpop_require_nonce") and "attestation" in f and a.get("auth", True):
        problems.append("features.fapi2.dpop_require_nonce: PingFederate's DPoP nonce requirement and the attestation"
                        " token-endpoint filter (features.attestation.auth) each issue a DPoP nonce the other refuses,"
                        " so an RFC 9449 client loops and never gets a token (F-0732): the filter issues the nonce,"
                        " so turn PingFederate's off (remove fapi2.dpop_require_nonce)")
    fed = f.get("federation") or {}
    if production and fed and not fed.get("self_anchor") and not fed.get("trust_anchors"):
        problems.append("features.federation: production needs a trust anchor (self_anchor or trust_anchors)")

    c = profile.get("conformance")
    if c is not None:
        if production:
            problems.append("conformance: the suites' clients, test user and login form are for a test rig, never production")
        if "fapi2" not in f or pf.get("openid_connect") is False or pf.get("user_token_mapping") is False:
            problems.append("conformance: the suite clients need fapi2, openid_connect and user_token_mapping")
        if c.get("ssf_receiver", True) and not ssf_objects(profile):
            problems.append("conformance: the SSF receiver client needs features.ssf with its PingFederate objects")
        plan = c["plan"]
        if plan.startswith("ciba-"):
            mode_wanted = plan.split("-", 1)[1].upper()
            if not ciba or (c.get("ciba") or {}).get("delivery_mode", "POLL") != mode_wanted or "ciba" not in c:
                problems.append(f"conformance: plan {plan} needs features.ciba and conformance.ciba.delivery_mode {mode_wanted}")
        if "ciba" in c and not ciba:
            problems.append("conformance: the CIBA suite clients need features.ciba")
        if plan == "federation-op" and (f.get("fapi2") or {}).get("par", "required") != "enabled":
            problems.append("conformance: the federation OP plan's RP sends its request object by value at the"
                            " authorization endpoint, which PAR required refuses: set features.fapi2.par: enabled")
        if plan.startswith("federation") and not fed:
            problems.append(f"conformance: plan {plan} needs features.federation")
        if plan == "attester-cimd" and not c.get("cimd_client_id"):
            problems.append("conformance: plan attester-cimd needs conformance.cimd_client_id")
        if plan == "fapi2-attestation" and not c.get("fapi2_attestation"):
            problems.append("conformance: plan fapi2-attestation needs conformance.fapi2_attestation")
        if c.get("fapi2_attestation") and not (f.get("attestation") or {}).get("auth", "attestation" in f):
            problems.append("conformance: the fapi2-attestation clients authenticate by attestation: they need"
                            " features.attestation with auth on")
    return problems


def _norm(value):
    if value is None:
        return None
    if isinstance(value, bool):
        return str(value).lower()
    return str(value).strip().lower()


def catalogue_index(repo=REPO):
    """({env name: (catalogue, entry)}, {removed env name: catalogue}, risk ids or None); None outside this repository."""
    if scan is None:
        return None
    catalogues, problems = scan.load_catalogues(repo, scan.modules_of(repo))
    if problems:
        raise Refused(["the settings catalogues cannot be used:", *problems])
    names, removed = {}, {}
    for c in catalogues:
        for entry in c.entries:
            for kind, name in c.entry_names(entry):
                if kind == "env":
                    names[name] = (c, entry)
            if entry.get("file"):
                for s in entry["sources"]:
                    if s["from"] == "env":
                        names[s["name"] + "_FILE"] = (c, entry)
        for gone in c.removed:
            if gone["from"] == "env":
                removed[gone["name"]] = c
    return names, removed, scan.accepted_risk_ids(repo)


def dated_risks(repo=REPO):
    """The ids of platform's AcceptedRisk registry that are accepted only with an expiry (its dated flag), or None
    when the file is not there."""
    path = os.path.join(repo, scan.ACCEPTED_RISKS)
    if not os.path.isfile(path):
        return None
    with open(path, encoding="utf-8") as f:
        text = f.read()
    return {m.group(1) for m in re.finditer(r'\b[A-Z][A-Z0-9_]*\s*\(\s*"([a-z0-9-]+)"\s*,\s*true\s*,', text)}


# The component switches (platform's ComponentSwitches.SWITCHES): a component with no switch is inferred present. The
# second member says whether the profile's features switch the component on, for a check that has no Terraform env.
SWITCHED_BY = {
    "FEDERATION": lambda f: f.get("federation") is not None,
    "AUTO_REGISTRATION": lambda f: bool((f.get("federation") or {}).get("auto_registration", True)) and f.get("federation") is not None,
    "ATTESTATION_AUTH": lambda f: bool((f.get("attestation") or {}).get("auth", True)) and f.get("attestation") is not None,
    "ATTESTATION_ISSUER": lambda f: bool((f.get("attestation") or {}).get("issuer", False)),
    "HOSTING": lambda f: bool((f.get("federation") or {}).get("hosting", False)),
    "SSF": lambda f: f.get("ssf") is not None and f["ssf"].get("transmitter", True),
    "SSF_RECEIVER": lambda f: bool((f.get("ssf") or {}).get("receiver", False)),
    "OPERATOR_API": lambda f: (f.get("federation") or {}).get("operator_api") is not None,
    "FAPI": lambda f: f.get("fapi2") is not None,
}


def switched_on(component, profile, env):
    """Whether `component` runs: its OIDF_<COMPONENT>_ENABLED in env when the env has it (a render with Terraform
    sets every switch), else what the profile's features imply; a component with no switch is inferred present, as
    ComponentSwitches infers it."""
    if component not in SWITCHED_BY:
        return True
    value = env.get(f"OIDF_{component}_ENABLED")
    if value is not None:
        return _norm(value) == "true"
    return bool(SWITCHED_BY[component](features(profile)))


def components_of(catalogue, entry, table):
    """The components a violation of `entry` refuses: its own, else its catalogue's row in the components table;
    [] for a catalogue that is not a PingFederate component (a service's)."""
    return list(entry.get("components") or (table or {}).get(catalogue.component) or [])


def acts_on(entry, value, env):
    """Whether production's rule for `entry` acts on `value`, as platform.settings' Governed decides it: on the
    governed values or schemes, or any value other than the default; never when an unless_set entry is set."""
    if any(env.get(other) not in (None, "") for other in scan.unless_set_of(entry)):
        return False
    try:
        governed = scan.governed_of(entry)
    except ValueError:
        governed = ("any", [])
    if governed is None:
        return False
    kind, items = governed
    if kind == "values":
        return _norm(value) in {_norm(v) for v in items}
    if kind == "schemes":
        return str(value).partition("://")[0].strip().lower() in {s.lower() for s in items}
    return _norm(value) != _norm(entry["default"])


def catalogue_problems(profile, env, index):
    if index is None:
        return []
    names, removed, risk_ids = index
    production = profile["deployment"]["mode"] == "production"
    acceptances = profile["deployment"].get("accepted_risks", [])
    accepted = {r.split("@", 1)[0] for r in acceptances}
    problems = []
    if risk_ids is not None:
        for r in sorted(accepted - set(risk_ids)):
            problems.append(f"deployment.accepted_risks: {r} is not a risk this release knows ({scan.ACCEPTED_RISKS})")
        dated = dated_risks() or set()
        for r in acceptances:
            if "@" not in r and r in dated:
                problems.append(f"deployment.accepted_risks: {r} is accepted only with an expiry, as {r}@YYYY-MM-DD")
    for key, value in env.items():
        if not key.startswith("OIDF_"):
            continue
        if key in removed:
            problems.append(f"{key}: removed ({removed[key].path} says what replaces it)")
            continue
        if key not in names:
            problems.append(f"{key}: no settings catalogue declares it")
            continue
        catalogue, entry = names[key]
        if not production or "{{" in value:
            continue
        rule = entry["profile"]
        if rule == "forbidden-in-production" and acts_on(entry, value, env):
            problems.append(f"{key}={value}: production refuses it ({catalogue.component})")
        elif rule.startswith("accepted-risk:") and acts_on(entry, value, env):
            risk = rule.split(":", 1)[1]
            if risk not in accepted:
                problems.append(f"{key}={value}: production needs deployment.accepted_risks to list {risk}")
    if production:
        table = scan.components_table(REPO)
        seen = set()
        for catalogue, entry in names.values():
            if entry["profile"] != "required-in-production" or id(entry) in seen:
                continue
            seen.add(id(entry))
            running = [c for c in components_of(catalogue, entry, table) if switched_on(c, profile, env)]
            env_names = [n for k, n in catalogue.entry_names(entry) if k == "env"]
            if running and not any(env.get(n) not in (None, "") or env.get(n + "_FILE") not in (None, "") for n in env_names):
                problems.append(f"{env_names[0]}: production needs it set while {words(running)} runs ({catalogue.component})")
    return problems


def version_problems(repo=REPO):
    if pfversion is None:
        return []
    problems = []
    env = pfversion.read_env(os.path.join(repo, PF_VERSION_ENVS[0]))
    pfversion.check_env(env, problems)
    pfversion.check_terraform_root(repo, env, TF_ROOT, "provider.tf", problems)
    return problems


# --- render and check --------------------------------------------------------------------------------------------

class Rendered:
    def __init__(self, profile, variables, env, tf_checks):
        self.profile, self.tfvars, self.env, self.tf_checks = profile, variables, env, tf_checks

    @property
    def name(self):
        return self.profile["profile"]


def apply_sets(profile, sets):
    """--set dotted.path=value, the value read as YAML, laid over the merged profile before it is validated. Under
    env the value is the setting's text as written (env.OIDF_X=true sets the string "true"); env.OIDF_X= unsets it."""
    for item in sets or ():
        path, sep, raw = item.partition("=")
        if not sep or not path:
            raise Refused([f"--set {item}: not dotted.path=value"])
        *parents, leaf = path.split(".")
        block = profile
        for part in parents:
            block = block.setdefault(part, {})
            if not isinstance(block, dict):
                raise Refused([f"--set {item}: {part} is not a mapping"])
        if parents[:1] == ["env"]:
            block[leaf] = raw if raw != "" else None
            continue
        try:
            block[leaf] = yaml.safe_load(raw)
        except yaml.YAMLError as e:
            raise Refused([f"--set {item}: the value is not YAML ({str(e).splitlines()[0]})"])


def build(path, base_url=None, planner=None, sets=None, overlays=()):
    """The profile at path, each overlay profile's own content laid over it, then the --set values; validated and
    rendered in memory. Refused when it cannot be rendered at all."""
    profile = load(path)
    for overlay in overlays:
        own = load(overlay, own=True)
        own.pop("extends", None)
        own.pop("profile", None)
        own.pop("description", None)
        profile = merge(profile, own)
    apply_sets(profile, sets)
    if base_url:
        profile["pf"] = dict(profile.get("pf") or {}, base_url=base_url)
    problems = schema_problems(profile)
    if problems:
        raise Refused(problems)
    variables = tfvars(profile)
    tf_env, tf_checks = (None, [])
    if planner is not None:
        tf_env, tf_checks = planner.plan(variables, stand_ins(profile, variables))
    return Rendered(profile, variables, assemble(profile, tf_env), tf_checks)


def check(rendered, index=False):
    problems = combination_problems(rendered.profile)
    problems += catalogue_problems(rendered.profile, rendered.env, catalogue_index() if index is False else index)
    problems += [f"terraform check: {m}" for m in rendered.tf_checks]
    return problems


def env_text(rendered):
    lines = [f"# Rendered by tools/profile.py from profiles/{rendered.name}.yaml - do not edit; change the profile.",
             "# No secrets: those reach the deployment by other means."]
    lines += [f"{k}={v}" for k, v in rendered.env.items()]
    return "\n".join(lines) + "\n"


def write(rendered, out):
    os.makedirs(out, mode=0o700, exist_ok=True)
    files = {
        "terraform.tfvars.json": json.dumps(rendered.tfvars, indent=2) + "\n",
        "vars.env": env_text(rendered),
        "stage-profile": stage_profile(rendered.profile) + "\n",
    }
    for name, text in files.items():
        with open(os.path.join(out, name), "w", encoding="utf-8") as f:
            f.write(text)
    return [os.path.join(out, n) for n in files]


def default_out(name):
    return os.path.join(REPO, ".local", name)


# --- author ------------------------------------------------------------------------------------------------------

def read_kv(path):
    values = {}
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                values[k.strip()] = v.strip()
    return values


SECRET_ALIASES = {"pf_runtime_tls_password": "runtime_tls_password"}


def material(profile, repo=REPO, material_dir=None, secrets_file=None):
    """The runtime var file's contents, from the profile's material block: runtime_tls, trusted_cas, secrets and the
    conformance clients' JWKS. Refused when a file it names is missing."""
    m = profile.get("material") or {}
    d = os.path.abspath(material_dir) if material_dir else os.path.join(repo, m.get("dir", "."))
    problems, out = [], {}

    def read(name, binary=False):
        p = os.path.join(d, name)
        if not os.path.isfile(p):
            problems.append(f"material: no {p}")
            return b"" if binary else ""
        with open(p, "rb" if binary else "r") as fh:
            return fh.read()

    tls = m.get("runtime_tls")
    if not tls:
        problems.append("material: no runtime_tls (the p12 PingFederate's runtime listener presents)")
    else:
        out["runtime_tls"] = {"p12_base64": base64.b64encode(read(tls["p12"], True)).decode(),
                              "key_id": tls.get("key_id", "pf-runtime-tls")}
    out["trusted_cas"] = {}
    for ca, name in (m.get("trusted_cas") or {}).items():
        data = read(name, True)
        out["trusted_cas"][ca] = data.decode() if data.lstrip().startswith(b"-----BEGIN") else base64.b64encode(data).decode()
    if secrets_file:
        secrets_file = os.path.abspath(secrets_file)
    elif m.get("secrets"):
        secrets_file = os.path.join(repo, m["secrets"])
    if not secrets_file or not os.path.isfile(secrets_file):
        problems.append(f"material: no secrets file ({secrets_file or 'material.secrets is not set'})")
    else:
        raw = read_kv(secrets_file)
        sec = {}
        for k, v in raw.items():
            k = k[len("TF_VAR_"):] if k.startswith("TF_VAR_") else k
            k = SECRET_ALIASES.get(k, k)
            if k in SECRET_KEYS:  # the file may hold more than the root takes (the rig's holds its own extras)
                sec[k] = v
        out["secrets"] = sec
    if profile.get("conformance") is not None:
        out["jwks"] = {n: read(name) for n, name in (m.get("jwks") or {}).items()}
    if problems:
        raise Refused(problems)
    return out


def _admin(host, password, path, method="GET", out=None, timeout=10):
    req = urllib.request.Request(host + path, method=method, headers={"X-XSRF-Header": "PingFederate"})
    req.add_header("Authorization", "Basic " + base64.b64encode(f"administrator:{password}".encode()).decode())
    ctx = ssl.create_default_context()
    ctx.check_hostname, ctx.verify_mode = False, ssl.CERT_NONE  # the local authoring server's self-signed certificate
    with urllib.request.urlopen(req, context=ctx, timeout=timeout) as r:
        if out:
            with open(out, "wb") as f:
                shutil.copyfileobj(r, f)
        return r.status


def archive_problems(profile, data_zip):
    """What the exported archive must hold for the profile's features (the rig's export checks, by feature)."""
    import zipfile
    problems = []
    with zipfile.ZipFile(data_zip) as z:
        members = set(z.namelist())

        def text(member):
            return z.read(member).decode("utf-8", "replace") if member in members else None

        for member in ("pf.jwk", "pingfederate-system-keys.xml"):
            if member not in members:
                problems.append(f"the archive has no {member}")
        if (profile.get("material") or {}).get("config_store"):
            jce = text("config-store/com.pingidentity.crypto.SunJCEManager.xml")
            if jce is None or "_CBC_" in jce:
                problems.append("the archive still enables CBC cipher suites: config-store/ was not staged before first start")
            if profile.get("conformance") is not None:
                authz = text("config-store/org.sourceid.oauth20.domain.AuthzServerManagerImpl.xml") or ""
                if not re.search(r'Rfc7523bisCompliantAudienceVerification"[^>]*>false<', authz):
                    problems.append("the archive accepts only the issuer as a client assertion's audience (the SSF plan's"
                                    " client fails): config-store/ was not staged before first start")
        ciba = features(profile).get("ciba")
        if ciba and (profile.get("material") or {}).get("config_store"):
            helper = text("config-store/org.sourceid.openid.ciba.handlers.CibaHelper.xml") or ""
            if 'nbfMaxPastInMinutes">60<' not in helper:
                problems.append("the archive's CIBA request-object window is not 60 minutes")
        if ciba and ciba["authenticator"] == "sim":
            if not any(b"SimOobAuthenticator" in z.read(n) for n in members if not n.endswith("/")):
                problems.append("the archive has no CIBA simulator instance (was plugins/ciba-sim in the authoring PF's deploy?)")
    return problems


AUTHOR_LABEL = "info.idpartners.pf-profile.author"
STATE_MARKER = ".pf-profile-author"


def replace_container(container, sh):
    """Remove `container` if it is one `author` created (its label); refuse to touch any other container of that name."""
    r = subprocess.run(["docker", "inspect", "-f", "{{index .Config.Labels \"" + AUTHOR_LABEL + "\"}}", container],
                       capture_output=True, text=True)
    if r.returncode:
        return  # no such container
    if r.stdout.strip() != "1":
        raise Refused([f"a container named {container} exists and this tool did not create it; pass --name"])
    sh(["docker", "rm", "-f", container])


def replace_state(state):
    """Delete the state file of the previous `author` run in this directory; refuse one some other tool wrote."""
    marker = os.path.join(os.path.dirname(state), STATE_MARKER)
    for p in (state, state + ".backup"):
        if os.path.exists(p):
            if not os.path.isfile(marker):
                raise Refused([f"{p} exists and this tool did not write it; pass --out a directory of its own"])
            os.remove(p)
    with open(marker, "w") as f:
        f.write("terraform.tfstate here is tools/profile.py author's, deleted and rewritten on every run\n")


def author(rendered, args):
    profile, name = rendered.profile, rendered.name
    out = os.path.abspath(args.out or default_out(name))
    write(rendered, out)
    mat = material(profile, material_dir=args.material_dir, secrets_file=args.secrets)
    version = read_kv(first(REPO, PF_VERSION_ENVS))
    image = args.image or f"{version['PF_IMAGE']}@{version['PF_IMAGE_DIGEST']}"
    if "postgres" in profile["pf"] and not args.image:
        raise Refused(["pf.postgres: the stock image has no PostgreSQL driver and PingFederate refuses a data store it"
                       " cannot load; pass --image (reference/lib/build-image.sh builds one)"])
    licence = os.environ.get("PING_DEVOPS_CONFIG", os.path.expanduser("~/.pingidentity/config"))
    if not os.path.isfile(licence):
        raise Refused([f"no licence details at {licence} (conformance/README.md says how to make one)"])
    for tool in ("docker", "terraform"):
        if shutil.which(tool) is None:
            raise Refused([f"{tool} is required"])

    os.umask(0o077)
    author_env = os.path.abspath(args.author_env) if args.author_env else os.path.join(out, "author.env")
    if not os.path.isfile(author_env):
        with open(author_env, "w") as f:
            f.write(f"PING_IDENTITY_PASSWORD={token.token_urlsafe(24)}Aa1\n")
    password = read_kv(author_env)["PING_IDENTITY_PASSWORD"]
    container = args.name or f"pf-profile-{name}-author"
    host = f"https://localhost:{args.admin_port}"
    state = os.path.join(out, "terraform.tfstate")
    runtime_vars = os.path.join(out, "material.tfvars.json")
    stage = tempfile.mkdtemp(prefix="profile-stage-")

    def log(msg):
        print(f"[{name}] {msg}", flush=True)

    def sh(cmd, **kw):
        r = subprocess.run(cmd, capture_output=True, text=True, **kw)
        if r.returncode:
            raise Refused([f"{' '.join(cmd[:3])} failed:", *(r.stderr or r.stdout).strip().splitlines()[-30:]])
        return r.stdout

    try:
        # Only a container and a state this command made are replaced: --name or --out pointing at the rig's or a
        # reference stack's must not take them down.
        replace_container(container, sh)
        replace_state(state)
        labels = [x for label in args.label for x in ("--label", label)]
        sh(["docker", "create", "--name", container, "--label", f"{AUTHOR_LABEL}=1", *labels, "--env-file", licence,
            "--env-file", author_env,
            "-e", "PING_IDENTITY_ACCEPT_EULA=YES", "-e", "CREATE_INITIAL_ADMIN_USER=true",
            "-p", f"127.0.0.1:{args.runtime_port}:9031", "-p", f"127.0.0.1:{args.admin_port}:9999", image])
        # Staged before first start, so the server comes up with it and the archive carries it.
        server = os.path.join(stage, "instance/server/default")
        os.makedirs(os.path.join(server, "data/config-store"))
        os.makedirs(os.path.join(server, "deploy"))
        cs = (profile.get("material") or {}).get("config_store")
        if cs:
            cs = os.path.join(REPO, cs)
            for f in sorted(os.listdir(cs)):
                if f.endswith(".xml"):
                    shutil.copy(os.path.join(cs, f), os.path.join(server, "data/config-store"))
        if stage_profile(profile) == "conformance":
            plugin = os.path.join(args.modules_dir or first(REPO, MODULES_DIRS), "pf.plugins.ciba-sim.jar")
            if not os.path.isfile(plugin):
                raise Refused([f"no {plugin}: stage the conformance profile first (stage-modules.sh --profile conformance)"])
            shutil.copy(plugin, os.path.join(server, "deploy"))
        # Readable by PingFederate's own user: docker cp hands the tree in as root's, with the modes it has here, and
        # this process's umask (077, for the secrets it writes) would leave the plugin and config-store unreadable to
        # uid 9031 - PingFederate then lists no descriptor for the plugin. None of it is secret.
        for d, dirs, files in os.walk(os.path.join(stage, "instance")):
            os.chmod(d, 0o755)
            for f in files:
                os.chmod(os.path.join(d, f), 0o644)
        sh(["docker", "cp", os.path.join(stage, "instance"), f"{container}:/opt/in/"])
        sh(["docker", "start", container])
        log(f"authoring PingFederate {container} starting (admin {host})")
        for _ in range(72):
            try:
                if _admin(host, password, "/pf-admin-api/v1/version", timeout=8) == 200:
                    break
            except Exception:
                pass
            time.sleep(5)
        else:
            raise Refused([f"the authoring admin API never answered 200 (docker logs {container})"])

        runtime = {"pf_admin_host": host, "pf_admin_password": password, "runtime_tls": mat["runtime_tls"],
                   "trusted_cas": mat["trusted_cas"], "secrets": mat["secrets"]}
        if "conformance" in rendered.tfvars:
            runtime["conformance"] = dict(rendered.tfvars["conformance"], jwks=mat["jwks"])
        with open(runtime_vars, "w") as f:
            json.dump(runtime, f)
        tf_dir = os.path.join(REPO, TF_ROOT)
        if not os.path.isdir(os.path.join(tf_dir, ".terraform")):
            sh(["terraform", f"-chdir={tf_dir}", "init", "-input=false", "-lockfile=readonly"])
        # One resource at a time: in parallel PingFederate has read back settings as their defaults.
        log_path = os.path.join(out, "terraform.log")
        with open(log_path, "w") as logf:
            r = subprocess.run(["terraform", f"-chdir={tf_dir}", "apply", "-input=false", "-auto-approve",
                                "-parallelism=1", f"-state={state}",
                                f"-var-file={os.path.join(out, 'terraform.tfvars.json')}", f"-var-file={runtime_vars}"],
                               stdout=logf, stderr=subprocess.STDOUT)
        if r.returncode:
            # The log's tail, colour codes stripped: in CI the out directory is not kept, so this is all there is.
            with open(log_path, encoding="utf-8", errors="replace") as logf:
                tail = [re.sub(r"\x1b\[[0-9;]*m", "", line.rstrip()) for line in logf if line.strip()][-40:]
            raise Refused([f"terraform apply failed ({log_path}); its last lines:", *tail])
        log(f"applied {TF_ROOT}")

        data_zip = os.path.join(out, "data.zip")
        status = _admin(host, password, "/pf-admin-api/v1/configArchive/export", out=data_zip + ".tmp", timeout=180)
        if status != 200:
            raise Refused([f"the archive export answered {status}"])
        problems = archive_problems(profile, data_zip + ".tmp")
        if problems:
            os.remove(data_zip + ".tmp")
            raise Refused(problems)
        os.replace(data_zip + ".tmp", data_zip)
        if args.age_recipient:
            age = [shutil.which("age")] if shutil.which("age") else (
                ["docker", "run", "--rm", "-i", "--entrypoint", "/usr/local/bin/age", args.age_image] if args.age_image else None)
            if age is None:
                raise Refused(["--age-recipient needs age on PATH or --age-image (an image carrying /usr/local/bin/age)"])
            with open(data_zip, "rb") as src, open(data_zip + ".age.tmp", "wb") as dst:
                subprocess.run(age + ["-r", args.age_recipient], stdin=src, stdout=dst, check=True)
            with open(data_zip + ".age.tmp", "rb") as f:
                if not f.read(21).startswith(b"age-encryption.org/v1"):
                    raise Refused(["age produced no ciphertext"])
            os.chmod(data_zip + ".age.tmp", 0o644)
            os.replace(data_zip + ".age.tmp", data_zip + ".age")
            os.remove(data_zip)
            log(f"exported and encrypted {data_zip}.age; the plaintext is gone")
        else:
            log(f"exported {data_zip} - plaintext, with pf.jwk inside: never for git")
    finally:
        shutil.rmtree(stage, ignore_errors=True)
        if os.path.exists(runtime_vars):
            os.remove(runtime_vars)
        if not args.keep:
            subprocess.run(["docker", "rm", "-f", container], capture_output=True)


# --- the command line --------------------------------------------------------------------------------------------

def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    sub = ap.add_subparsers(dest="command", required=True)
    for cmd in ("render", "check", "author"):
        p = sub.add_parser(cmd)
        p.add_argument("profiles", nargs="+" if cmd == "check" else 1, metavar="profile")
        p.add_argument("--base-url", help="the origin PF advertises, over the profile's pf.base_url")
        p.add_argument("--with", dest="overlays", action="append", default=[], metavar="PROFILE",
                       help="lay another profile's own content (not its extends chain) over this one; repeatable")
        p.add_argument("--set", action="append", default=[], metavar="PATH=VALUE",
                       help="lay a value (YAML) over the profile, e.g. pf.client_storage=jdbc; repeatable")
        if cmd != "author":
            p.add_argument("--no-terraform", action="store_true", help="leave out the Terraform env output and checks")
        if cmd != "check":
            p.add_argument("--out", help="where to write (default .local/<profile>/)")
        if cmd == "author":
            p.add_argument("--image", help="the authoring image (default build/pf-version.env's)")
            p.add_argument("--name", help="the authoring container's name")
            p.add_argument("--admin-port", type=int, default=29999)
            p.add_argument("--runtime-port", type=int, default=29031)
            p.add_argument("--modules-dir", help="where the staged pf.plugins.ciba-sim.jar is (default the image build's modules/)")
            p.add_argument("--author-env", help="a KEY=VALUE file holding PING_IDENTITY_PASSWORD, the authoring PF's admin"
                                                " password and so the archive's (default <out>/author.env, generated)")
            p.add_argument("--label", action="append", default=[], help="a docker label for the authoring container")
            p.add_argument("--material-dir", help="over the profile's material.dir")
            p.add_argument("--secrets", help="over the profile's material.secrets: a KEY=VALUE file of var.secrets members")
            p.add_argument("--age-recipient", help="encrypt the archive to this age recipient and keep only the ciphertext")
            p.add_argument("--age-image", help="an image carrying /usr/local/bin/age, when age is not on PATH")
            p.add_argument("--keep", action="store_true", help="leave the authoring container running")
    args = ap.parse_args(argv)

    planner = None if getattr(args, "no_terraform", False) else Planner()
    failed = False
    try:
        index = catalogue_index()
        version = version_problems()
        for arg in args.profiles:
            path = resolve(arg)
            try:
                rendered = build(path, args.base_url, planner, args.set, [resolve(o) for o in args.overlays])
                problems = check(rendered, index) + version
                if problems:
                    raise Refused(problems)
                if args.command == "render":
                    for p in write(rendered, os.path.abspath(args.out or default_out(rendered.name))):
                        print(f"wrote {os.path.relpath(p)}")
                elif args.command == "check":
                    print(f"ok    {os.path.relpath(path, REPO)}")
                else:
                    author(rendered, args)
            except Refused as e:
                failed = True
                print(f"FAIL  {os.path.relpath(path, REPO)}", file=sys.stderr)
                for p in e.problems:
                    print(f"      {p}", file=sys.stderr)
    except Refused as e:
        print("\n".join(e.problems), file=sys.stderr)
        return 1
    finally:
        if planner:
            planner.close()
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
