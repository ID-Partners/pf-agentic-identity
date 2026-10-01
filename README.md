# pf-agentic-identity

Agentic and workload identity for PingFederate: OpenID Federation 1.0, OAuth 2.0 Attestation-Based Client
Authentication, Rich Authorization Requests with an external policy decision point, Shared Signals (SSF, CAEP
and RISC), a device enrolment service and the Grant Management API, delivered as PingFederate modules, a war
and plugin jars. This repository carries the released artefacts, the documentation an operator needs to
configure, deploy and upgrade them, and the specifications they implement.

Generated from a private source repository at each release; raise issues here, pull requests are not accepted.
The source code is not published here.

## Download and verify a release

Each release's assets are on its release page: the module jars, `oidf.war`, `gm-api.war`, the plugin jars,
`MANIFEST`, `SHA256SUMS` and `PROVENANCE.txt`. With the GitHub CLI:

```sh
gh release download v0.6.0 -R ID-Partners/pf-agentic-identity -D vendor/
```

or anonymously, one asset at a time:

```sh
curl -fsSLO https://github.com/ID-Partners/pf-agentic-identity/releases/download/v0.6.0/SHA256SUMS
curl -fsSLO https://github.com/ID-Partners/pf-agentic-identity/releases/download/v0.6.0/<asset>
```

Then check every file against `SHA256SUMS` before you use it, and record what you took:

```sh
( cd vendor && sha256sum -c SHA256SUMS )          # Linux
( cd vendor && shasum -a 256 -c SHA256SUMS )      # macOS
grep -E '^(commit|tag):' vendor/PROVENANCE.txt >> VENDORED.txt
```

`PROVENANCE.txt` names the source commit and the tag the release was built from. Every release here, from
v0.3.0, carries the assets it was first published with in the source repository, so its checksums are unchanged.

This release runs on PingFederate 13.1.3. Every release here is a `jakarta.servlet` build for
PingFederate 13.1.x; the v0.1.x releases, built for 13.0.x, are not published here.

## The image and the demo

`image/` (the PingFederate image build) and `demo/` (a conformance rig, `demo/up.sh`) are this release's files
as they were tagged. They build from the private source repository, not from the release assets, so they do
not run from this repository alone; v0.7.0 is the first release whose image and demo do.

## Documentation

- [docs/operator/](docs/operator/README.md) - deploying, health, preflight and upgrading.
- [docs/configuration/](docs/configuration/README.md) - every setting, by component.
- [docs/federation/](docs/federation/README.md) - OpenID Federation: how it works, configuration, limits.
- [docs/releases/](docs/releases/README.md) - each release's notes, and [CHANGELOG.md](CHANGELOG.md).

Report a vulnerability as [SECURITY.md](SECURITY.md) says, never in an issue.

## Licence

Apache License 2.0: [LICENSE](LICENSE) and [NOTICE](NOTICE). PingFederate and the Ping Identity images are
Ping Identity's, under their own licence.
