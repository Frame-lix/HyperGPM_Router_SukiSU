# Changelog

All notable changes to HyperOS Google Passkey Router for SukiSU are recorded here.

## 1.0.0 - 2026-09-15

### Changed

- Consolidated settings retries, field parsing and report capture; reused discovered services within status snapshots and removed successful-read event noise.
- Versioned success fingerprints now include policy/profile/module content, unlocked users, GMS identity and readable route values. Stable matches still validate selected services by action and exact binding permission for each user.
- Observation, locked users, partial failures and unreadable settings no longer produce a successful cache entry.
- Conflict scans bound enumeration as well as content, ignore disabled/removal-pending modules, refresh on public CLI apply and explicit modes, and treat incomplete scans as unknown. Automatic mode observes when ownership cannot be established.
- Boot checks prior route ownership independently of cache invalidation; restore persists an automatic-routing pause until an explicit apply resumes it.
- Apply, restore and uninstall share process-identity locks with stale-owner recovery and owner-only release.

### Recovery and resource bounds

- Added pre-write transaction journals and commit identities. Recovery rolls back only values still equal to an interrupted transaction's target, respects locked users, and preserves later external changes.
- Added per-key original-backup flags while retaining legacy backups across upgrade.
- Unified command deadlines and descendant termination without requiring external timeout; bounded no-newline output and nested capture storage.
- Boot routing, deferred-user retry and verification share a 90-second window. Compatibility fallback has a 120-second boot wait and a 210-second outer ceiling, plus cleanup overhead.
- Reports use unique capture files and classify already captured evidence instead of collecting an additional logcat sample. Reports preserve previously verified drift warnings; shared failure-state writes are atomic.

### Validation and release status

- Host regression coverage includes capability profiles, third-party providers, key-level rollback, old-state restore, cache invalidation, Action isolation, report redaction, real concurrent locks, timed-out descendants and SIGKILL recovery before/after writes and ownership commit.
- Full entrypoint comparison uses the same synthetic Android fixtures for the prior tag and this candidate. Stable apply performs three settings reads, two selected-service queries, and zero settings writes, full discovery, package dumps or logcat calls on the one-user fixture.
- Release packaging uses a 15-file module allowlist, fixed ZIP timestamps and checksum verification. Local research, tests, development files, device reports and personal files are excluded.
- Promoted to the 1.0.0 formal release with versionCode 101. Device validation is no longer a release prerequisite; host regression and artifact audits remain required. BusyBox ash and target-device passkey tests have not been performed, compatibility evidence labels remain unchanged, and no device battery-saving percentage is claimed.

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
