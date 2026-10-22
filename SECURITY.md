# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately through GitHub's private vulnerability reporting: open the repository's **Security** tab and choose **Report a vulnerability**. Do not open a public issue.

Include what you found, how to reproduce it, the affected version or commit and the impact you expect. We acknowledge reports within 7 days.

## Disclosure

We follow a 90-day coordinated disclosure window: we aim to ship a fix and publish a GitHub security advisory within 90 days of the report, and we credit reporters who wish to be named. If a fix needs longer, we agree a new date with the reporter before the window ends.

## Supported versions

zigguro has not had a release yet. Until 1.0, only the latest commit on `main` receives security fixes. After 1.0, the latest minor release is supported.

## Scope

The threat model is in [docs/security/threat-model.md](docs/security/threat-model.md) and the security invariants in [docs/security/invariants.md](docs/security/invariants.md). Reports that break an invariant (for example an agent command escaping its sandbox, a secret reaching a log, or a tool call that skips the permission engine) are always in scope.
