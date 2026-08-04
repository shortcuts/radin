# Security Policy

## Reporting a vulnerability

Open private security advisory on repo's GitHub "Security" tab, or contact maintainer directly. No public issue for security reports.

## Scope note: `install.sh`

`install.sh` runs `brew`/`npm`/`cargo` installs for companion tools (rtk, caveman, code-review-graph). Never installs without explicit `y` confirmation — each tool offered individually, skipped by default. Find path where `install.sh` installs without asking? Security bug. Report as above.
