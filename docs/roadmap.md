# Mimic Sync Roadmap

## 1. Product Direction

Mimic Sync is a configuration-driven folder replication utility for Windows.

Its V1 purpose is to let a user define:

- one Source / Mimic folder;
- one or more Target folders;
- an independent synchronization policy for each Target;

and then safely perform a one-way, preview-first synchronization operation.

The product core is generic folder synchronization.

Synchronizing AI-agent skills is an important reference use case, but the implementation must not assume that synchronized content is specific to AI tools.

---

## 2. V1 Product Contract

V1 is built around the following workflow:

```text
Configure
→ Validate
→ Scan
→ Compare
→ Build Sync Plan
→ Show Changes
→ Y/n Confirmation
→ Execute
→ Report
```

V1 supports three per-target synchronization policies:

- `add-only`
- `update-only`
- `add-update`

V1 does not delete target-only content.

V1 does not perform mirror synchronization, bidirectional synchronization, historical state inference, rename detection, or Junction-based shared-reference distribution.

---

## Current Development Snapshot

The V1 feature set is frozen. Product hardening has passed on the target Windows environment, and the project has entered Release Candidate status.

| Milestone | Current status |
|---|---|
| Milestone 1 — Core Sync Engine | Verified by manual trial + automated integration baseline |
| Milestone 2 — Configuration Model | Verified in real config-driven Windows runs |
| Milestone 3 — Web Configurator | Browser manual QA passed; JSON/CLI workflow confirmed understandable |
| Milestone 4 — Verification | Baseline suite: **42/42 passed**; expanded hardening suite: **63/63 passed** |
| Milestone 5 — V1 Product Polish | Complete; BAT/config UX and exact-path Sync Plan polished |
| Milestone 6 — Hardening / RC | **Hardening PASS**; local V1 Release Candidate prepared |

Feature Freeze remains active. New capabilities belong in V2/Future unless required to fix a V1 release-blocking correctness, safety, robustness, or documentation defect.

The remaining release action is to place the RC in its final Git repository and verify the intended release commit. That repository step is intentionally kept separate from the already-completed product hardening.

---

# Milestone 1 — Core Sync Engine

## Goal

Build the reusable PowerShell synchronization engine and implement the V1 synchronization contract.

The engine must work independently of the Web Configurator.

## Scope

### Source and Target model

Support:

- one Source / Mimic folder;
- multiple Targets;
- independent processing of each Target.

### State classification

For every relevant source-relative path, classify the current target state as:

```text
MISSING
SAME
DIFFERENT
TARGET-ONLY
```

### Synchronization policies

Implement:

#### Add Only

```text
MISSING     → ADD
SAME        → SKIP
DIFFERENT   → SKIP
TARGET-ONLY → IGNORE
```

#### Update Only

```text
MISSING     → SKIP
SAME        → SKIP
DIFFERENT   → UPDATE
TARGET-ONLY → IGNORE
```

#### Add + Update

```text
MISSING     → ADD
SAME        → SKIP
DIFFERENT   → UPDATE
TARGET-ONLY → IGNORE
```

### Comparison behavior

Use deterministic content comparison.

Recommended V1 approach:

```text
file size
→ if equal, SHA-256 hash
→ classify SAME / DIFFERENT
```

Do not use timestamps alone as the authoritative equality rule.

### Sync Plan

Before any write:

- scan all configured Targets;
- generate the actual filesystem-derived Sync Plan;
- display required `ADD` and `UPDATE` actions by Target;
- report when a Target has no applicable changes.

### Confirmation

Default interactive gate:

```text
Proceed with sync? [Y/n]
```

No write occurs before confirmation.

### Execution report

After synchronization, report per Target:

- added items;
- updated items;
- no-change state;
- failures.

## Exit Criteria

Milestone 1 is complete when:

- all three policies follow the authoritative policy matrix;
- multiple Targets can be processed independently;
- nested files retain relative structure;
- target-only content is not modified;
- the Sync Plan is generated before writes;
- cancelling at the confirmation gate leaves Targets unchanged;
- execution results are reported clearly;
- no destructive mirror or purge behavior exists.

---

# Milestone 2 — Configuration Model

## Goal

Move all user-specific paths and Target policies out of the program source and into a reusable JSON Sync Profile.

## Scope

### JSON profile

Support a configuration shape conceptually equivalent to:

```json
{
  "source": "D:\\Shared\\Mimic",
  "targets": [
    {
      "name": "Target A",
      "path": "D:\\Workspace\\A",
      "mode": "add-update"
    },
    {
      "name": "Target B",
      "path": "D:\\Workspace\\B",
      "mode": "add-only"
    },
    {
      "name": "Target C",
      "path": "D:\\Workspace\\C",
      "mode": "update-only"
    }
  ]
}
```

### Validation

Validate at minimum:

- JSON syntax;
- required fields;
- Source existence;
- Target existence where required by V1;
- supported modes;
- duplicate or invalid Target definitions;
- unsafe Source/Target relationships;
- paths containing spaces;
- Unicode paths.

### CLI entry

Support a configuration-driven invocation such as:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\mimic-sync.ps1" -Config ".\mimic-sync.config.json"
```

The exact CLI surface may be refined during implementation, but configuration must remain separate from synchronization logic.

### Local configuration safety

Provide:

```text
config.example.json
```

for the repository.

User-specific:

```text
mimic-sync.config.json
```

should be ignored by Git by default.

## Exit Criteria

Milestone 2 is complete when:

- no user-specific path must be hard-coded in `mimic-sync.ps1`;
- the same engine can run different Sync Profiles without code changes;
- per-target policies load correctly;
- invalid configurations fail before filesystem mutation;
- the example configuration is sufficient for a new user to understand the format.

---

# Milestone 3 — Web Configurator

## Goal

Provide a lightweight browser-based configuration interface that generates valid Mimic Sync profiles without becoming the synchronization execution layer.

## Scope

### Source configuration

Allow the user to define:

- Source / Mimic path.

V1 may use manual entry or pasted Windows paths.

Native absolute-path folder picking is not required for V1.

### Dynamic Targets

Allow:

- one initial Target;
- `+` to add more Targets;
- `−` to remove a Target;
- Target name;
- Target path;
- independent Target policy.

### Policy selection

Each Target can choose:

- Add Only;
- Update Only;
- Add + Update.

The UI should explain each mode in simple language.

### Progressive disclosure

Keep common controls visible.

Advanced controls should remain collapsed by default and must only expose functionality actually supported by V1.

Do not expose fake controls for:

- stale management;
- exclusive-content management;
- rename detection;
- deletion;
- Junction mode.

These belong to later versions.

### Configuration Summary

Before export, show a readable summary such as:

```text
Source:
D:\Shared\Mimic

Target A:
D:\Workspace\A
Mode: Add + Update

Target B:
D:\Workspace\B
Mode: Update Only
```

This is a configuration summary, not an actual filesystem-derived Sync Plan.

### Export

Generate:

- downloadable JSON Sync Profile;
- ready-to-copy PowerShell CLI command.

### Parameter Guide

Explain common concepts:

- Source;
- Target;
- Add Only;
- Update Only;
- Add + Update;
- Config file;
- Sync Plan;
- confirmation behavior.

## Exit Criteria

Milestone 3 is complete when:

- users can add and remove Targets dynamically;
- each Target can use its own mode;
- exported JSON matches the CLI configuration contract;
- the generated command is directly usable after the user saves the config;
- the UI clearly distinguishes configuration from actual filesystem scanning;
- no direct filesystem mutation occurs from the browser UI.

---

# Milestone 4 — Verification and Test Fixtures

## Goal

Prove that the V1 synchronization contract works against controlled sample folders before release preparation.

## Scope

Create repeatable fixtures representing:

```text
tests/
└── fixtures/
    ├── mimic/
    ├── target-a/
    ├── target-b/
    └── target-c/
```

The fixtures must include deliberate differences.

### Required scenarios

#### Add Only

Verify:

- missing source content is added;
- old target content is not updated;
- identical content is not rewritten;
- target-only content survives untouched.

#### Update Only

Verify:

- missing source content is not added;
- old target content is updated;
- identical content is not rewritten;
- target-only content survives untouched.

#### Add + Update

Verify:

- missing source content is added;
- old target content is updated;
- identical content is not rewritten;
- target-only content survives untouched.

### Structural scenarios

Also test:

- nested folders;
- root-level files;
- spaces in paths;
- Unicode path names;
- multiple Targets using different policies in one run;
- empty change plan;
- malformed config;
- missing Source;
- unsafe path relationships;
- execution failure reporting;
- cancellation before write.

### Verification method

V1 may use a PowerShell test harness rather than introducing a heavy test framework immediately.

The test harness should:

```text
reset fixtures
→ run controlled sync
→ inspect resulting files
→ compare expected content
→ confirm protected content remains
→ report PASS / FAIL
```

## Exit Criteria

Milestone 4 is complete when:

- all required policy scenarios pass;
- the tests demonstrate that target-only content is preserved;
- mixed-policy multi-target execution works;
- error cases fail safely;
- sample paths can be used to demonstrate the tool without touching personal directories.

---

# Milestone 5 — V1 Product Polish

## Goal

Make the tool understandable and reliable enough for public repository use.

## Scope

### CLI usability

Polish:

- headings;
- scan status;
- Sync Plan readability;
- confirmation prompt;
- execution status;
- final report;
- actionable error messages.

### BAT launcher

Provide a minimal one-click launcher:

```text
Mimic Sync.bat
```

Its responsibility is only to start the PowerShell entry point.

Business logic must remain in the PowerShell engine.

### Documentation

Ensure consistency across:

- `architecture.md`;
- `sync-model.md`;
- `roadmap.md`;
- `config.example.json`;
- examples;
- README.

### Examples

Include at least:

- generic folder synchronization;
- AI-agent skills synchronization.

The generic example remains the primary product-facing example.

### Repository hygiene

Verify:

- no user-specific paths are committed;
- local `mimic-sync.config.json` is ignored;
- test artifacts and temporary files are ignored;
- no personal skill content is accidentally included;
- example paths are clearly synthetic.

## Exit Criteria

Milestone 5 is complete when:

- a new user can understand the product without reading the implementation;
- a user can create or export a config and run the CLI;
- the one-click BAT launcher works;
- all tests still pass;
- documentation matches actual behavior;
- repository content is safe to publish.

---

# Feature Complete Gate

V1 becomes feature-complete when all of the following are true:

- the PowerShell engine supports all three synchronization policies;
- configuration is JSON-driven;
- multiple Targets and per-target policies work;
- the Web Configurator generates valid profiles;
- actual Sync Plans come from the CLI filesystem scan;
- explicit confirmation occurs before writes;
- target-only content remains protected;
- controlled fixture tests pass;
- generic and AI-agent examples are included.

After this gate, new capabilities should not be added casually to V1.

---

# Feature Freeze Policy

During V1 Feature Freeze:

Allowed:

- defect fixes;
- path handling fixes;
- data-loss or overwrite-risk fixes;
- reporting corrections;
- documentation corrections;
- test coverage for discovered defects;
- necessary usability fixes.

Deferred by default:

- new sync modes;
- deletion;
- state tracking;
- rename detection;
- filesystem watching;
- Junctions;
- GUI application packaging;
- cloud features.

Any scope expansion should require an explicit roadmap decision.

---

# Milestone 6 — V1 Hardening and Release Candidate

## Goal

Move from feature-complete to release-ready.

## Hardening Areas

### Correctness

Audit:

- policy matrix implementation;
- nested path handling;
- comparison logic;
- add/update boundaries;
- skipped content;
- failure behavior.

### Safety

Verify:

- no target-only deletion;
- no accidental purge behavior;
- no writes before confirmation;
- unsafe path relationships are rejected;
- configured paths cannot traverse Junction / reparse-point ancestors in V1;
- execution revalidates source and target state before each planned write;
- a planned ADD refuses to overwrite an item that appeared after the scan;
- a planned UPDATE refuses to overwrite a target file that changed after the scan;
- staged/backup temporary files are cleaned after normal success or handled failure;
- local-only config remains untracked.

### Robustness

Test:

- unusual but valid Windows paths;
- spaces;
- Unicode;
- empty source;
- empty target;
- read-only files or permission failures where practical;
- interrupted or partially failed operations;
- repeated runs after successful synchronization.

### UX consistency

Check:

- Configurator terminology matches CLI terminology;
- mode descriptions match actual behavior;
- Configurator Summary is not confused with Sync Plan;
- no unsupported future option appears executable.

### Documentation consistency

Verify:

- README;
- architecture;
- sync model;
- roadmap;
- examples;
- config template;

all describe the same V1 behavior.

## Release Candidate Exit Criteria

V1 is release-ready when:

- no known release-blocking synchronization defect remains;
- no known target-data deletion or destructive-overwrite defect remains;
- all defined fixture tests pass;
- all three modes behave according to the policy matrix;
- cancellation and no-change runs are safe;
- README and docs match implementation;
- repository contains no personal paths or secrets;
- the intended release commit is verified.

### RC Audit Result

Local product/repository audit status:

- synchronization manual acceptance: **PASS**;
- baseline automated suite: **42/42 PASS**;
- expanded hardening suite: **63/63 PASS**;
- browser Configurator manual QA: **PASS**;
- configuration/CLI/BAT terminology consistency: **PASS**;
- JSON example/config syntax audit: **PASS**;
- repository hygiene audit: **PASS**;
- personal-path / trial-artifact scan: **PASS**;
- destructive mirror/purge command audit: **PASS**;
- Configurator JavaScript syntax audit: **PASS**.

The local RC satisfies the product-level exit criteria. The final criterion — verification of the intended release commit — is completed after the RC is committed to its final Git repository.

---

# V2 — Managed State and Historical Awareness

V2 may introduce:

```text
.mimic-state.json
```

to record historically managed content.

Potential classifications:

```text
MANAGED
STALE
EXCLUSIVE
POSSIBLE RENAME
```

## Planned V2 Questions

V2 should address:

- which target content was previously distributed by Mimic Sync;
- which target-only content is truly exclusive;
- which content may be stale;
- whether previously managed folders were renamed rather than removed;
- how to present stale or rename candidates without unsafe automatic deletion.

## Rename Detection

A key V2 requirement is:

> Do not automatically interpret an old managed folder disappearing from the Source and a new folder appearing as unrelated `STALE + NEW` if evidence suggests a rename.

Potential evidence may include:

- historical state;
- file hashes;
- relative structure;
- content similarity;
- previous managed identity.

V2 should prefer:

```text
POSSIBLE RENAME
```

over unsafe automatic inference when confidence is insufficient.

---

# Future Exploration — Shared Reference / Junction Mode

A future architecture may explore Directory Junctions or equivalent link-based distribution.

V1:

```text
Source
  ↓
replicate
  ↓
Targets
```

Future possibility:

```text
             Source
          ↙    ↓    ↘
       Target Target Target
        reference same content
```

This changes the product from replication to shared-reference management.

It must therefore be evaluated as a separate architecture with its own concerns:

- path portability;
- NTFS requirements;
- permissions;
- broken links;
- source availability;
- deletion semantics;
- tooling compatibility;
- backup behavior.

It is intentionally not part of V1.

---

# Portfolio Packaging Phase

After V1 is verified and ready for publication, run the repository through the `portfolio-packaging` workflow.

Packaging priorities:

1. lead with the generic folder-management problem;
2. make the Source → multiple Targets model visually obvious;
3. explain the three synchronization policies simply;
4. demonstrate safety through preview-before-write and target-only preservation;
5. present AI-agent skills synchronization as a strong real-world case study;
6. avoid framing the project as useful only for AI coding;
7. show the configuration-driven architecture and Web Configurator without overclaiming complexity;
8. include real test evidence before making reliability claims.

The portfolio-facing story should emphasize:

> Mimic Sync solves the recurring problem of centrally maintaining shared folder content across multiple independent destinations without forcing those destinations to become identical mirrors.
