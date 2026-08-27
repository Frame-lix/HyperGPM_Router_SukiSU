# Changelog

All notable changes to HyperOS Google Passkey Router for SukiSU are recorded here.

## 0.2.0-alpha - 2026-08-27

### Added

- Capability snapshots for Android API, HyperOS major version, region, user state, GMS state, Credential Manager feature, provider query path, secure settings and OEM hybrid evidence.
- Exact Credential Provider and Autofill service discovery with action, current-user visibility and binding-permission validation.
- Explainable per-user route plans through `hypergpmctl.sh plan`.
- `observe-only`, `conservative` and explicit `force` modes.
- Public and private diagnostic report modes with section and total timeout budgets.
- Conservative compatibility guards for API37 and OS4 environments.

### Changed

- Credential provider and Autofill routing are decided independently. Conservative mode preserves a third-party Autofill service.
- Settings writes are performed as a per-user transaction with readback and rollback of only the keys touched by the current attempt.
- Action status, apply, report and open steps now run independently with hard timeouts and a final status summary.
- The boot watchdog applies at most once per boot and performs one later read-only verification instead of writing every 30 seconds for six minutes.
- Restore and uninstall only restore keys still owned by the module; later user choices are preserved.

### Fixed

- Bounded retry handling for Binder `Failed transaction`, including commands that return status 0 while printing transaction failure text.
- Report collection no longer depends on an external `timeout` command and does not stop subsequent Action steps on failure.
- Temporary report files include process-specific names and are removed after collection.

### Validation status

- Host routing, transaction, Action isolation, syntax, privacy and package validation pass.
- BusyBox ash execution and the required OS3/API36 device cycle remain release-blocking until completed on a target device.

## 0.1.1-alpha

- Added bounded provider discovery, basic settings retries, transaction rollback and report command timeouts.

## 0.1.0-alpha

- Initial experimental SukiSU/KernelSU script module.
