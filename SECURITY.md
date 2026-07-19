# Security Policy

## Reporting a Vulnerability

Open a private security advisory on this repo's GitHub "Security" tab, or
contact the maintainer directly. Do not open a public issue for security
reports.

## Scope note: `install.sh`

`install.sh` runs `brew`/`npm`/`cargo` installs for companion tools (rtk,
caveman, code-review-graph). It never runs an install without an explicit `y`
confirmation from the person running it — each companion tool is offered
individually and skipped by default. If you find a path where `install.sh`
installs something without prompting, that is a security bug: report it as
above.
