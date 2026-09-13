# Changelog

All notable changes to HyperOS Google Passkey Router for SukiSU are recorded here.

## 0.4.0-beta - 2026-09-06

### Added

- Minimal success fingerprints for platform build, user set, GMS identity, module inventory state, compatibility mode and current route values.
- Stable-state quick checks that bypass provider discovery and all settings writes when the fingerprint still matches.
- Bounded, read-only conflict detection for settings writers, GMS managers, deep Credential Manager hooks and framework overlays.
- Public conflict category counts and private bounded module IDs in diagnostic reports.
- Lock owner type and bounded Action wait diagnostics.
- Explicit `restore force` for users who intentionally want to overwrite a post-apply selection.
- Two-generation router log rotation at 128 KiB.

### Changed

- KernelSU/SukiSU uses `boot-completed.sh` as the primary boot path. `service.sh` exits immediately there and only starts a 120-second compatibility fallback on other managers.
- Normal boot discovery forbids package dumps and logcat. One five-second retry is reserved for a missing provider or transient Binder failure.
- Automatic routing downgrades to observe-only when cached conflict evidence makes route ownership unclear.
- Automatic boot routing stops after settings drift instead of competing with a user or another module.
- Ownership state now records time and reason; safe restore behavior remains the default.

### Performance

- Host fixture full apply: 12 settings reads, 3 writes, 6 provider queries, 2 package dumps and 1 logcat query.
- Host fixture stable apply: 3 settings reads, no writes, no provider queries, no dumpsys, no logcat and no package mutation.
- These counts compare deterministic script paths; they are not a claim of device-specific battery savings.

### Security

- Conflict scanning never sources or executes other modules, skips symlinks and oversized files, and enforces module/file/time limits.
- Public reports expose conflict categories and counts, not full module IDs or filesystem paths.
- Runtime data directories use mode `0700`; fingerprints, ownership records and installation backups are tightened to `0600`.

### Known limitations

- BusyBox ash and exact-ZIP target-device gates remain pending on this host.
- OS4/API36 and all API37 paths remain unverified without a real passkey creation cycle.
- Existing-module file edits that do not change the modules directory may be discovered on the next Action/report rather than by the stable boot fingerprint.

## 0.3.0-alpha - 2026-08-27

### Added

- Independent OS3/API36, OS3/API37, OS4/API36 and OS4/API37 compatibility profiles.
- Build stability and profile evidence status in capability snapshots.
- Safe, non-evaluating `compat-profiles.conf` parser with deterministic duplicate rejection.
- Read-only framework overlay probes for OEM dialog, hybrid, credential autofill and default provider resources.
- API37-style `ResolveInfo` and colon-form `ServiceInfo.permission` parser coverage.
- Per-setting support and ownership states for key-scoped fallback and restore.

### Changed

- Unverified OS4/API36 and all API37 paths default to `observe-only`; explicit conservative/force commands remain available for deliberate testing.
- Autofill write failures no longer roll back successful Credential routing. Conservative Credential keys remain atomic; force can record a partial route.
- Deep OEM hybrid evidence blocks further apply attempts instead of repeating ineffective writes.
- Activity launch failures are logged and produce a manual-settings hint without changing apply/report outcomes.

### Research and validation

- Compared Android 16 release sources with AOSP `android-17.0.0_r1`; Credential setting names, colon delimiter, binding permission, ProviderSession restrictions and core overlay resources remain compatible with the current model.
- Four-quadrant, unknown-build, profile parser, overlay, API37 output and per-key transaction host tests pass.
- OS4/API36 and API37 exact-ZIP device cycles remain pending; none are claimed as verified.

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
