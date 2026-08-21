# Mimic Sync Architecture

## 1. Purpose

Mimic Sync is a configuration-driven folder replication utility for Windows.

Its core job is to distribute content from one authoritative source folder to one or more target folders while allowing each target to retain content that does not exist in the source.

The product is intentionally generic. Synchronizing AI-agent skills is an important reference use case, but the underlying model applies to any workflow that needs to maintain repeated shared content across multiple folders.

Examples include:

- shared project templates;
- common configuration files;
- reusable scripts;
- reference assets;
- AI-agent skills;
- repeated workspace resources.

Mimic Sync V1 is designed around controlled, explicit, one-way replication rather than bidirectional synchronization or full mirroring.

---

## 2. Core Model

Mimic Sync uses the following conceptual model:

```text
               Source / Mimic Folder
                        M
                        │
          ┌─────────────┼─────────────┐
          ▼             ▼             ▼
       Target A1     Target A2     Target A3
```

The source folder is the baseline.

Each target is configured independently and may use a different synchronization policy.

A target may also contain files or folders that are not present in the source. Mimic Sync V1 treats such target-only content as outside its managed scope and does not delete or modify it.

---

## 3. Configuration-Driven Architecture

Mimic Sync does not hard-code paths such as `M`, `A1`, `A2`, or `A3`.

Instead, every operation is defined by a Sync Profile.

Conceptually:

```text
Sync Profile
│
├── Source
│   └── Path
│
└── Targets
    ├── Target A1
    │   ├── Name
    │   ├── Path
    │   └── Policy
    │
    ├── Target A2
    │   ├── Name
    │   ├── Path
    │   └── Policy
    │
    └── Target A3
        ├── Name
        ├── Path
        └── Policy
```

The Sync Profile is represented as JSON and is the primary contract between the configuration layer and the execution layer. In V1, relative Source/Target paths are resolved from the config file directory, and Windows environment variables in configured paths are expanded by the CLI. Source and Target root directories must already exist before execution.

A simplified example:

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

Each target owns its own policy. A single Sync Profile may therefore combine different synchronization behaviors.

---

## 4. V1 Synchronization Policies

Mimic Sync V1 supports three synchronization policies.

### 4.1 Add Only

`add-only` fills missing content but does not modify content that already exists in the target.

```text
Source has item / Target does not
→ ADD

Source has item / Target already has item
→ SKIP

Target-only content
→ IGNORE
```

Typical use cases:

- initial resource distribution;
- adding missing templates;
- environments where local modifications must never be overwritten.

---

### 4.2 Update Only

`update-only` updates existing target content when the corresponding source content differs, but does not add source items that are missing from the target.

```text
Source has item / Target does not
→ SKIP

Source and Target both have item, but differ
→ UPDATE

Source and Target are identical
→ SKIP

Target-only content
→ IGNORE
```

Typical use cases:

- maintaining only an already-approved subset;
- updating previously distributed resources without expanding target scope;
- environments where new shared items require separate approval before being introduced.

---

### 4.3 Add + Update

`add-update` treats the source as the authoritative version for shared content.

```text
Source has item / Target does not
→ ADD

Source and Target both have item, but differ
→ UPDATE

Source and Target are identical
→ SKIP

Target-only content
→ IGNORE
```

Typical use cases:

- centrally managed shared resources;
- AI-agent skills distributed from one baseline folder;
- common templates or scripts that should remain current across multiple targets.

---

## 5. Three-Layer Product Architecture

Mimic Sync V1 is separated into three main layers.

```text
                 Mimic Sync
                     │
        ┌────────────┴────────────┐
        │                         │
 Web Configurator          PowerShell CLI
 Configuration UX            Sync Engine
        │                         │
        └──────── JSON Config ────┘
                     │
                     ▼
                  Scan
                     │
                     ▼
                Sync Plan
                     │
                     ▼
               User Confirm
                     │
                     ▼
                  Execute
                     │
                     ▼
                  Report
```

### 5.1 Web Configurator

The Web Configurator is a configuration interface.

Its responsibilities are:

- define the source folder path;
- dynamically add or remove target entries;
- assign a name and path to each target;
- select one synchronization policy per target;
- expose basic settings first and advanced settings only when relevant;
- summarize the requested operation;
- export a JSON Sync Profile;
- generate a ready-to-copy CLI command;
- explain common parameters in simple language.

The Web Configurator does **not** perform filesystem synchronization.

It also does not claim that a source or target contains specific changes unless those paths have been scanned by the CLI execution layer.

In V1, folder paths may be entered or pasted manually. Native browser access to reliable Windows absolute folder paths is not a V1 requirement.

---

### 5.2 JSON Sync Profile

The JSON Sync Profile is the stable interface between configuration and execution.

It should be possible to create or modify a Sync Profile through:

- the Web Configurator;
- a text editor;
- an IDE;
- another script or automation tool.

The PowerShell engine must not depend on the Web Configurator being used.

This separation keeps the product extensible and prevents UI decisions from controlling synchronization logic.

---

### 5.3 PowerShell CLI Engine

The PowerShell CLI is the execution authority.

Its responsibilities are:

1. load the Sync Profile;
2. validate the configuration;
3. validate source and target paths;
4. scan the real filesystem;
5. compare source and target content;
6. classify required actions;
7. build the actual Sync Plan;
8. show the proposed changes;
9. request explicit `Y/n` confirmation;
10. execute approved changes;
11. report results per target;
12. stop safely on actionable errors.

The CLI is the only V1 component allowed to modify target folders.

---

## 6. Scan and Comparison Model

For source-managed paths, the execution engine classifies current state using a small set of states:

```text
MISSING
SAME
DIFFERENT
TARGET-ONLY
```

Their meaning is:

- `MISSING`: the item exists in the source but not in the target;
- `SAME`: corresponding source and target content are equivalent;
- `DIFFERENT`: corresponding source and target content exist but differ;
- `TARGET-ONLY`: the item exists in the target but not in the source.

The synchronization policy converts these states into actions.

| State | Add Only | Update Only | Add + Update |
|---|---|---|---|
| MISSING | ADD | SKIP | ADD |
| SAME | SKIP | SKIP | SKIP |
| DIFFERENT | SKIP | UPDATE | UPDATE |
| TARGET-ONLY | IGNORE | IGNORE | IGNORE |

This table is the core V1 behavior contract.

---

## 7. Operation Lifecycle

A normal V1 run follows this lifecycle:

```text
Load Config
    ↓
Validate
    ↓
Read-only Scan
    ↓
Compare
    ↓
Build Actual Sync Plan
    ↓
Show Changes Per Target
    ↓
Proceed with sync? [Y/n]
    ↓
Execute Approved Actions
    ↓
Final Report
```

No write operation should occur before the Sync Plan has been displayed and the user has explicitly confirmed execution.

If there are no required changes, the CLI should report that all applicable targets are already synchronized under their configured policies and exit without writing.

---

## 8. Safety Contract

Mimic Sync V1 follows these safety rules:

```text
No automatic deletion.
No purge behavior.
No mirror semantics.
No bidirectional synchronization.
No modification of target-only content.
No write before explicit confirmation.
No traversal or write-through of Junction / reparse-point paths in V1.
No blind overwrite when Source or Target state changed after the preview scan.
```

Therefore, Mimic Sync V1 must not use deletion behavior equivalent to destructive mirroring such as `robocopy /MIR` or `/PURGE`.

The product is deliberately asymmetric:

```text
Source → Target
```

not:

```text
Source ↔ Target
```

Target-specific content remains outside the V1 synchronization scope.

---

## 9. Generic Product Boundary

The implementation must avoid assumptions that the synchronized folders contain AI skills.

The following concepts belong to the product core:

- source folder;
- target folder;
- shared content;
- target-only content;
- add policy;
- update policy;
- scan;
- comparison;
- preview;
- confirmation;
- execution;
- report.

The following is a reference use case:

```text
Mimic Skills
     │
     ├──→ Codex Skills
     ├──→ Claude Skills
     └──→ Other Agent Skills
```

Each agent may retain agent-specific skills because target-only content is ignored.

The same engine should work without code changes for generic folder replication scenarios.

---

## 10. V1 Scope

V1 includes:

- one source folder;
- multiple target folders;
- configuration-driven operation;
- per-target synchronization policy;
- `add-only`;
- `update-only`;
- `add-update`;
- read-only preflight scan;
- actual Sync Plan generation;
- explicit confirmation before writes;
- per-target execution reporting;
- JSON configuration;
- Web Configurator for creating configuration;
- ready-to-copy CLI command generation;
- Windows PowerShell execution;
- verification with controlled test fixtures.

---

## 11. Explicit V1 Non-Goals

V1 does not implement:

- deletion of target-only files or folders;
- mirror synchronization;
- bidirectional synchronization;
- automatic conflict merging;
- `.mimic-state.json`;
- managed/stale/exclusive historical classification;
- rename detection;
- automatic filesystem watching;
- background synchronization;
- symbolic-link distribution;
- Directory Junction distribution;
- cloud synchronization;
- EXE packaging;
- Electron or Tauri application packaging;
- Web Configurator direct filesystem mutation.

These are excluded intentionally to keep V1 understandable, testable, and safe.

---

## 12. V2 State-Aware Direction

V2 may introduce `.mimic-state.json` to preserve historical management information.

This can support richer classifications such as:

```text
MANAGED
STALE
EXCLUSIVE
POSSIBLE RENAME
```

A critical V2 requirement is to avoid assuming that a previously managed folder that disappears from the source was necessarily deleted.

For example:

```text
Previous source:
portfolio-packaging

Current source:
portfolio-presentation
```

If the target still contains `portfolio-packaging`, V2 should consider whether the source folder was renamed rather than immediately classifying the old folder as stale and the new folder as unrelated new content.

Reliable rename detection may require historical state plus evidence such as:

- content similarity;
- file hashes;
- relative structure;
- prior managed identity.

V1 does not attempt this inference.

---

## 13. Future Shared-Reference Exploration

A later version may explore Directory Junctions or other link-based models.

Current V1:

```text
M
│
├── copy/update → A1
├── copy/update → A2
└── copy/update → A3
```

This is a replication model.

A future link-based design could resemble:

```text
          M
       ↙  ↓  ↘
      A1  A2  A3
       references
```

This is a shared-reference model.

Because the semantics, failure modes, portability, permissions, and ownership model differ substantially, link-based distribution is treated as a separate future architecture rather than a V1 synchronization option.

---

## 14. Architectural Principles

Mimic Sync should remain guided by the following principles:

### Configuration over hard-coded paths

Folders and policies belong in profiles, not in program source.

### Execution separate from configuration

The UI describes intent; the CLI verifies reality and performs filesystem operations.

### Preview before mutation

Users should see the actual planned changes before any write occurs.

### Per-target control

Different targets may safely use different synchronization policies.

### Preserve target ownership

Content outside the source baseline is not automatically treated as disposable.

### Generic core, concrete examples

The engine remains domain-neutral while documentation demonstrates real use cases such as AI-agent skills.

### Minimal V1, explicit future boundaries

Advanced state tracking and link-based distribution should be added only when their semantics can be implemented and verified reliably.
