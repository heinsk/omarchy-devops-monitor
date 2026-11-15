# Security Policy

## Reporting a Vulnerability

Report security issues privately via GitHub's security advisory feature:
https://github.com/heinsk/omarchy-devops-monitor/security/advisories/new

Do not open a public issue for security vulnerabilities.

## Where the plugin writes

The plugin writes only two files, both private (mode 0600, in a 0700 folder you own, never through a symlink, atomically):

- `~/.config/io.github.heinsk.devops-monitor/config.json` (and `config.json.bak`): your settings, changed only when you press **Save** in the panel or flip a switch. Only the Azure DevOps targets, GitHub repositories and Kubernetes contexts / namespaces can be edited from the panel; every value is validated before it is written.
- `~/.local/state/io.github.heinsk.devops-monitor/state.json`: notification silences.

No credentials are stored in either file.
