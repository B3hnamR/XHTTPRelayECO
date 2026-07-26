# Changelog

All notable changes to XHTTP Relay Deployer are documented here.

## [2.0.0] - 2026-07-27

> [!NOTE]
> **From-scratch release:** Compared with [v1.3.8](https://github.com/B3hnamR/XHTTPRelayECO/tree/1.3.8),
> v2.0.0 replaces the previous Windows-first installer and template-based architecture after that
> implementation became detectable. Selected legacy features were intentionally not carried forward.

### Added

- A self-contained PowerShell manager that generates relay files in memory and uploads them inline
  through the Vercel REST API.
- The same manager workflow on Windows, Linux, and macOS, including a user-local PowerShell 7
  bootstrap on Linux/macOS when `pwsh` is unavailable.
- Named encrypted profiles for multiple Vercel accounts, with a remembered and revalidated
  Personal/team deployment scope for each profile.
- Separate identity, Personal workspace, selected deployment scope, plan, and status reporting.
- Complete team/project pagination with stale-scope rejection and guarded bulk deletion.
- Post-deployment comparison of requested and applied Function regions.
- Ready-to-import client share links and JSON, plus custom-domain list/add/verify/remove tools and
  verified-domain host selection.
- Persistent deployment logs with build-event errors and an exact local snapshot of uploaded files.

### Changed

- Replaced the v1.3.8 Vercel CLI and checked-in project/template pipeline with direct API-native
  deployment; Node.js, npm, Git, the Vercel CLI, and local `.vercel` linking are no longer required.
- Simplified deployment to two transparent builds: a streaming Node Function and a zero-compute,
  cache-disabled external-origin Rewrite.
- Node deployments can connect to a self-signed backend certificate through `ALLOW_INSECURE`.
- Region selection now also writes the top-level inline-deployment field and must pass applied-region
  verification before a ready-to-use client configuration is generated.
- Usage and health reporting now validate the selected scope and distinguish Edge ingress, Function
  compute, backend responses, and Vercel platform failures.
- Verified the rebuilt workflow on Hobby, Pro Trial, and Pro scopes using Vercel-provided domains;
  a custom domain remains optional.

### Removed

- The four legacy Fast Pipe variants, optional `x-relay-key` lock, and the Balanced, Max Connection,
  and Custom Node preset matrix.
- Throttle, bandwidth, concurrency, upstream-timeout, and sampled runtime-log controls.
- Random landing templates and the checked-in static frontend/template bundle.
- Legacy live-log, load-test, environment-drift, benchmark, build-profile export, local-link, and
  metadata-randomization workflows.

### Fixed

- Inline REST deployments no longer silently inherit the project's `iad1` default when another region was selected.
- Single-region `x-vercel-id` values are no longer misreported as proof of Function compute location.
