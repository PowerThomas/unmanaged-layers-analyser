# Unmanaged Layers Analyser

[![PowerShell](https://img.shields.io/badge/PowerShell-5.1%2B-blue?logo=powershell&logoColor=white)](https://docs.microsoft.com/powershell/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Windows-0078D4?logo=windows&logoColor=white)]()
[![GitHub stars](https://img.shields.io/github/stars/PowerThomas/unmanaged-layers-analyser?style=social)](https://github.com/PowerThomas/unmanaged-layers-analyser/stargazers)
[![GitHub issues](https://img.shields.io/github/issues/PowerThomas/unmanaged-layers-analyser)](https://github.com/PowerThomas/unmanaged-layers-analyser/issues)
[![GitHub last commit](https://img.shields.io/github/last-commit/PowerThomas/unmanaged-layers-analyser)](https://github.com/PowerThomas/unmanaged-layers-analyser/commits/main)

A standalone, interactive PowerShell tool for detecting — and optionally removing — **unmanaged layers** in Power Platform / Dataverse managed solutions.

> Built as a lightweight CLI alternative for environments where XrmToolBox or MSAL-based tools are blocked by Conditional Access policies. Authentication is handled entirely via **Azure CLI**.

---

## Table of Contents

- [Features](#features)
- [Prerequisites](#prerequisites)
- [Installation](#installation)
- [Usage](#usage)
- [How it works](#how-it-works)
- [Contributing](#contributing)
- [License](#license)

---

## Features

- 🔍 **Detect** all unmanaged (`Active`) layers across every component of a managed solution
- 🌈 **Git-style diff** — red `-` lines show the managed baseline value, green `+` lines show the unmanaged override
- 🗑️ **Remove** unmanaged layers with a two-step confirmation (warning + solution name re-entry)
- 📋 **Export** results to CSV including all changed attributes per layer
- 🔐 **Azure CLI authentication** — no MSAL, no app registration, Conditional Access compatible
- 📊 **Summary** per component type with layer counts
- 🔄 **Auto-publish** option after removal

---

## Prerequisites

| Requirement | Notes |
|---|---|
| PowerShell 5.1+ | Built-in on Windows 10/11; PowerShell 7+ also supported |
| [Azure CLI](https://aka.ms/installazurecliwindows) | Must be installed and logged in via `az login` |
| Power Platform access | At least **Environment Maker** or **System Administrator** role |

---

## Installation

```powershell
git clone https://github.com/PowerThomas/unmanaged-layers-analyser.git
cd unmanaged-layers-analyser
```

No module installation or dependencies required — the script is fully self-contained.

---

## Usage

```powershell
.\Get-UnmanagedLayers.ps1
```

The script guides you through the following steps interactively:

1. Verifies Azure CLI is installed and that you are logged in
2. Retrieves all Power Platform environments you have access to
3. Lets you select an environment
4. Retrieves all managed solutions in that environment
5. Lets you select a solution
6. Detects unmanaged layers for every component in the solution
7. Displays a results table and a summary by component type
8. Optionally shows a **git-style diff** per component
9. Optionally exports results to **CSV**
10. Optionally **removes** all unmanaged layers (with double confirmation)
11. Optionally **publishes** the environment after removal

### Example — results table

```
  Type                        Name                   Publisher    LayerOrder  Changes
  ----                        ----                   ---------    ----------  -------
  Entity                      appointment            Contoso              1        3
  EnvironmentVariableDefinition MyVariable           Contoso              1        1
```

### Example — git-style diff

```
  diff  [Entity]  appointment
  ============================================================
  --- BOSPlanningTool
  +++ Unmanaged (Active)  publisher: Default Publisher for contoso
  ------------------------------------------------------------
  - synctoexternalsearchindex              True

  + synctoexternalsearchindex              False
```

---

## How it works

The script uses the **Dataverse Web API v9.2** to query the `msdyn_componentlayers` virtual entity.

### Layer detection

The `msdyn_componentlayers` entity requires at least two filter conditions: `msdyn_solutioncomponentname` (the component type string) and `msdyn_componentid`. By omitting the `msdyn_solutionname` filter, the query returns **all layers** for a component — both managed and unmanaged. The script then splits these client-side:

- `msdyn_solutionname eq 'Active'` → unmanaged layer
- Everything else → managed base layers (highest `msdyn_order` = direct baseline)

The `msdyn_changes` field on the unmanaged layer contains a JSON diff of only the changed attributes. The `msdyn_componentjson` field on the managed base layer contains the full component state, used to look up the old values for the diff view.

### Layer removal

Removal is performed via the `RemoveActiveCustomization` Dataverse action:

```http
POST /api/data/v9.2/RemoveActiveCustomization
Content-Type: application/json

{
  "LogicalName": "appointment",
  "Id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

### Authentication

The script uses `az account get-access-token` to obtain Bearer tokens for both the **Power Platform Admin API** (`https://service.powerapps.com/`) and the **Dataverse Web API** (`{orgUrl}`). This approach works with Conditional Access policies and device-based restrictions where MSAL interactive flows are blocked.

---

## Contributing

Contributions are welcome! Please follow the steps below.

### Getting started

1. **Fork** this repository
2. **Create a branch**: `git checkout -b feature/your-feature-name`
3. **Make your changes** — keep the single-file, no-dependency philosophy in mind
4. **Test** against a real Dataverse environment (at minimum a non-production sandbox)
5. **Commit** your changes: `git commit -m 'Add: description of your change'`
6. **Push** to your fork: `git push origin feature/your-feature-name`
7. **Open a Pull Request** and describe what you changed and why

### Guidelines

- **Single file** — keep the script fully self-contained with no external module dependencies beyond `az` CLI
- **StrictMode safe** — the script runs with `Set-StrictMode -Version Latest`; always use `$obj.PSObject.Properties['key']` for safe property access on dynamic objects
- **English only** — all user-facing messages, comments, and output must be in English
- **Test on PS 5.1** — the minimum supported version is PowerShell 5.1 (Windows built-in)
- **No production testing** — please test only against sandbox or development environments

### Reporting bugs

Please open an [issue](https://github.com/PowerThomas/unmanaged-layers-analyser/issues) and include:

- PowerShell version: `$PSVersionTable.PSVersion`
- Azure CLI version: `az version`
- The full error message or unexpected behaviour description
- Environment type (e.g. sandbox, trial, production)

---

## License

This project is licensed under the **MIT License** — see [LICENSE](LICENSE) for details.
