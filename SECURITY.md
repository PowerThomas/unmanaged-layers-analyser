# Security Policy

## Supported versions

Only the latest published version of `Get-UnmanagedLayers` is actively supported.

## Reporting a vulnerability

If you find a security issue, please do not open a public issue with sensitive details.

Report the issue by contacting the repository owner through GitHub or the PowerShell Gallery owner contact mechanism.

Please include:

- A description of the issue.
- Steps to reproduce, if safe to share.
- Impacted version.
- Whether the issue could cause data loss, privilege escalation, token exposure, or unintended Dataverse changes.

## Security model

This script does not store credentials. Authentication is delegated to Azure CLI.

The script can remove unmanaged active layers from Dataverse components. Treat removal as a destructive operation and test in a sandbox environment first.