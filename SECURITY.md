# Security Policy

## Reporting a vulnerability

Open a private security advisory on the repo's GitHub "Security" tab, or contact the maintainer directly. Do not open a public issue for a security report.

## Scope note: `install.sh`

`install.sh` runs `brew`/`npm`/`cargo` installs for companion tools (rtk, caveman, codebase-memory-mcp). It never installs without an explicit yes. It offers each tool individually and skips it by default. Found a path where `install.sh` installs without asking? That is a security bug. Report it as above.
