# Contributing

Thanks for considering a contribution.

## Development principles

- Keep the script lightweight.
- Do not introduce external PowerShell module dependencies unless there is a strong reason.
- Keep user-facing output in English.
- Use PowerShell 7+.
- Keep destructive actions protected by confirmation and/or `ShouldProcess`.
- Test against a sandbox or development Dataverse environment. Do not test destructive behavior in production.

## Local validation

Run:

```powershell
Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\.github\linters\PSScriptAnalyzerSettings.psd1 -Severity Error,Warning
```

If PSScriptAnalyzer is not installed:

```powershell
Install-Module PSScriptAnalyzer -Scope CurrentUser
```

## Pull request checklist

Before opening a PR:

- [ ] The script parses in PowerShell 7+.
- [ ] PSScriptAnalyzer passes.
- [ ] README is updated if behavior changed.
- [ ] CHANGELOG is updated if user-facing behavior changed.
- [ ] Destructive behavior has been tested only in a sandbox or development environment.