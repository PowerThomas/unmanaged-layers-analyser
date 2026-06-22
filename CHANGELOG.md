# Changelog

All notable changes to this project will be documented in this file.

This project follows semantic versioning where practical.

## [1.0.1] - 2026-06-22

### Changed

- Documented PowerShell 7+ as the supported baseline.
- Made PowerShell Gallery the primary installation method in the README.
- Added public repository hygiene files and automated validation.
- Aligned script copyright metadata with the MIT license.

### Fixed

- Refreshed Azure CLI account details after first-time `az login`.

## [1.0.0] - 2026-06-22

### Added

- Initial public release.
- Interactive environment and solution selection.
- Unmanaged active layer detection through Dataverse Web API.
- Git-style diff output.
- CSV export.
- Optional unmanaged layer removal.
- Optional publish after removal.
- Azure CLI based authentication.