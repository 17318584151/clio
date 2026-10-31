# Multi-account Quota Implementation Plan

> **For agentic workers:** Use superpowers:executing-plans to implement task-by-task.

**Goal:** Identify accounts and display used quotas and source timestamps for each.
**Architecture:** Discover login directories, read identities, deduplicate accounts and query each CLI in its own configuration directory. Keep account quotas separate from historical tool usage.
**Tech Stack:** Swift, SwiftUI, Foundation, existing CLI probes.
**Spec:** docs/superpowers/specs/2026-10-31-multi-account-design.md

## Global Constraints

No worktree. No account switching or switching tests. Preserve local history. Never display unknown quotas as zero. Do not copy credentials.

## Review Focus

- Duplicate identities across directories must appear once.
- Missing metadata and expired readings must remain unknown.
- Queries must use the discovered account's directory.
- Accounts without session logs must still appear.
- Many accounts must not grow the panel beyond the screen.

### Task 1: Discovery and probes

Files: Data/QuotaAccount.swift, Data/ClaudeConfigReader.swift, Data/UsageProbe.swift, Data/CodexUsageProbe.swift; Tests/AccountQuotaTests.swift.
- [x] Write fixture tests for discovery, duplicate identities and cached quota ownership; run them and confirm failure.
- [x] Implement QuotaAccount.discover(home:extraDirectories:) and per-directory CLI arguments.
- [x] Verify fixtures and probe regressions.

### Task 2: Account quota state and display

Files: Data/UsageStore.swift, View/AccountQuotaCard.swift, View/PanelView.swift, View/SettingsView.swift.
- [x] Add account state with bounded sequential refresh and explicit failure/updated-at display.
- [x] Display each account's used percentage, data update time and reset time; make the account section scrollable.
- [x] Add custom directories in settings and preserve the default-account menu bar semantics.
- [x] Verify no-log accounts and unknown/zero display through fixtures and build.

### Task 3: Verification and documentation

- [x] Run account, usage, refresh and Codex probe regressions, then build.
- [x] Review final diff and UI; fix material findings.
- [x] Update README and development test instructions to final scope.

## Implementation notes

Implemented on codex/multi-account-quotas in the existing checkout. Discovery tests cover directory normalization, identity deduplication, quota ownership, no-log accounts and zero versus unknown. Codex fake-server tests verify CODEX_HOME propagation. Usage, account, refresh and Codex regressions pass; build succeeds. Existing SwiftUI Text concatenation deprecation warnings remain. Fresh review found failed-query cached values and fallback scheduling; both corrected, with regression suites rerun. No account switching performed.
