# Mimic Sync

Mimic Sync is a lightweight, configuration-driven folder replication utility for Windows.

It lets you maintain one baseline folder and selectively distribute its content into multiple target folders, while preserving target-specific content that does not exist in the source.

```text
                 Source / Mimic
                      M
                      │
          ┌───────────┼───────────┐
          ▼           ▼           ▼
       Target A    Target B    Target C
       add-update  add-only    update-only
```

Mimic Sync is designed for repeated-content management across folders.

Common examples include:

- shared project templates;
- reusable scripts;
- common configuration files;
- reference assets;
- repeated workspace resources;
- AI-agent skills shared across Codex, Claude, or other agent environments.

AI-agent skills are an important reference use case, but Mimic Sync itself is not limited to AI tooling.

---

## Why Mimic Sync?

A common workflow looks like this:

```text
Shared content
├── template A
├── script B
└── config C
```

needs to exist across several independent folders:

```text
Project A
Project B
Project C
```

Manual copying works at first, but becomes tedious when shared content changes over time.

Full mirror synchronization is often too aggressive because each target may also contain its own local files.

Mimic Sync uses a safer model:

> Keep shared content manageable without forcing every target folder to become an identical mirror.

Target-only content is preserved in V1.

---

## Core Workflow

Mimic Sync separates configuration from execution.

```text
Web Configurator
      │
      ▼
JSON Sync Profile
      │
      ▼
PowerShell CLI
      │
      ▼
Read-only Scan
      │
      ▼
Actual Sync Plan
      │
      ▼
Proceed with sync? [Y/n]
      │
      ▼
Execute
      │
      ▼
Per-target Report
```

The browser-based Configurator defines what you want.

The PowerShell CLI inspects the real filesystem, determines what actually needs to change, shows the Sync Plan, and performs writes only after confirmation.

---

## Synchronization Modes

Each target can use its own synchronization policy.

### Add Only

Adds missing source content but does not overwrite content already present in the target.

```text
Missing in Target  → ADD
Already exists     → SKIP
Target-only        → IGNORE
```

### Update Only

Updates existing target content when the corresponding source content differs, but does not add source items that are missing from the target.

```text
Missing in Target  → SKIP
Different          → UPDATE
Same               → SKIP
Target-only        → IGNORE
```

### Add + Update

Adds missing source content and updates existing differing content.

```text
Missing in Target  → ADD
Different          → UPDATE
Same               → SKIP
Target-only        → IGNORE
```

---

## V1 Policy Matrix

| State | Add Only | Update Only | Add + Update |
|---|---|---|---|
| Missing in Target | Add | Skip | Add |
| Same | Skip | Skip | Skip |
| Different | Skip | Update | Update |
| Target-only | Ignore | Ignore | Ignore |

Mimic Sync V1 never automatically deletes target-only content.

---

## Repository Structure

```text
mimic-sync/
│
├── README.md
├── LICENSE
├── .gitignore
│
├── mimic-sync.ps1
├── Mimic Sync.bat
├── config.example.json
│
├── configurator/
│   └── index.html
│
├── docs/
│   ├── architecture.md
│   ├── sync-model.md
│   └── roadmap.md
│
├── examples/
│   ├── generic-folder-sync.json
│   └── agent-skills-sync.json
│
└── tests/
    ├── run-tests.ps1
    └── fixtures/
        ├── mimic/
        ├── target-a/
        ├── target-b/
        └── target-c/
```

---

## Quick Start

### 1. Create a config

Copy:

```text
config.example.json
```

to:

```text
mimic-sync.config.json
```

Then edit the paths and modes.

In V1, the Source and Target root folders must already exist. Relative paths are resolved from the config file directory, and Windows environment variables in paths are expanded by the CLI.

Example:

```json
{
  "source": "D:\\Shared\\Mimic",
  "targets": [
    {
      "name": "Project Alpha",
      "path": "D:\\Projects\\Alpha",
      "mode": "add-update"
    },
    {
      "name": "Project Beta",
      "path": "D:\\Projects\\Beta",
      "mode": "add-only"
    },
    {
      "name": "Project Gamma",
      "path": "D:\\Projects\\Gamma",
      "mode": "update-only"
    }
  ]
}
```

### 2. Run Mimic Sync

From PowerShell:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\mimic-sync.ps1" -Config ".\mimic-sync.config.json"
```

Or double-click:

```text
Mimic Sync.bat
```

The BAT launcher uses `mimic-sync.config.json` from the repository directory by default. You can also drag another JSON profile onto `Mimic Sync.bat` to run that profile.

### 3. Review the Sync Plan

Before any write, Mimic Sync performs a read-only scan.

Example:

```text
SYNC PLAN

Target: Project Alpha
Mode: add-update

  [ADD]    templates
  [UPDATE] shared-config

Target: Project Beta
Mode: add-only

  [ADD]    scripts

Proceed with sync? [Y/n]
```

Press `Y` or just Enter to continue.

Press `n` to cancel without changing target files.

---

## Web Configurator

Open:

```text
configurator/index.html
```

in a browser.

The Configurator lets you:

- enter the Source path;
- add or remove Targets;
- give each Target a name;
- choose an independent synchronization mode;
- review a configuration summary;
- download the generated JSON profile;
- copy a ready-to-run PowerShell command;
- read simple parameter explanations.

The Configurator does not directly synchronize files.

It generates configuration. After downloading `mimic-sync.config.json`, place it next to `mimic-sync.ps1` or adjust the CLI `-Config` path. The CLI performs the real filesystem scan and execution.

---

## Generic Example

Suppose you maintain:

```text
D:\Shared-Resources
```

containing:

```text
templates
scripts
shared-config
```

and want to distribute those resources across:

```text
Project Alpha
Project Beta
Project Gamma
```

while allowing each project to retain its own local content.

Mimic Sync can assign a different mode to each destination:

```text
Shared-Resources
│
├── Project Alpha → Add + Update
├── Project Beta  → Add Only
└── Project Gamma → Update Only
```

No project is forced to become a full mirror of the source.

---

## AI-Agent Skills Example

One practical use case is maintaining a shared set of AI-agent skills.

```text
Mimic Skills
│
├── shared-skill-a
├── shared-skill-b
└── shared-skill-c
```

distributed into:

```text
Codex Skills
Claude Skills
Other Agent Skills
```

Each agent may still retain its own exclusive skills.

Because target-only content is outside the V1 managed scope, agent-specific skills remain untouched.

See:

```text
examples/agent-skills-sync.json
```

---

## Safety Model

Mimic Sync V1 follows these rules:

```text
No automatic deletion.
No purge behavior.
No mirror semantics.
No bidirectional synchronization.
No modification of target-only content.
No write before explicit confirmation.
No Junction / reparse-point traversal in managed V1 paths.
No blind overwrite when the filesystem changed after preview.
```

It also rejects unsafe Source/Target relationships such as identical, recursively nested, overlapping, or reparse-point-routed paths. Before each planned write, the engine revalidates the scanned Source/Target state; UPDATE actions refuse to overwrite a Target file that changed after the Sync Plan was shown.

---

## File Comparison

V1 compares actual file content instead of relying only on modification timestamps.

```text
File size
→ if equal, SHA-256
→ SAME or DIFFERENT
```

---

## Reparse Points and Junctions

Mimic Sync V1 does not traverse reparse-point content during recursive scanning.

Directory Junctions and other shared-reference approaches are reserved for future architectural exploration.

V1 uses replication:

```text
Source
  ↓
copy / update
  ↓
Targets
```

A future version may explore shared references instead.

---

## Testing

The repository includes controlled test fixtures.

Run:

```powershell
.\tests\run-tests.ps1
```

The test harness copies fixture data into:

```text
tests\tmp\
```

and performs test operations only inside that temporary area.

Verification coverage includes:

- Add Only;
- Update Only;
- Add + Update;
- missing content;
- outdated content;
- identical content;
- target-only preservation;
- nested folders;
- spaces in paths;
- Unicode paths;
- mixed per-target policies;
- cancellation before write;
- repeated runs;
- invalid Source paths;
- unsafe Source/Target nesting;
- duplicate and overlapping Targets;
- empty Source behavior;
- locked-file execution failure;
- Junction / reparse-point protection where the filesystem supports the fixture.

The pre-hardening Windows baseline completed **42 assertions with 0 failures**, together with a separate manual acceptance trial covering all three synchronization policies, repeat-run idempotency, Source removal behavior, and the `Y/n` confirmation gate.

The expanded hardening suite subsequently completed **63 assertions with 0 failures** on the target Windows environment. It adds coverage for stronger path/reparse-point safety, duplicate and overlapping Targets, empty Source behavior, locked-file failure handling, exact Sync Plan paths, temporary-file cleanup, and other release-boundary cases.

---

## Current Status

Mimic Sync V1 is **Released / Release Verified**.

The V1 feature set is frozen. The core synchronization contract has passed a real Windows manual acceptance trial; the original automated fixture baseline passed **42/42**; and the expanded V1 hardening suite passed **63/63**. The Configurator has also completed browser-side manual QA for its V1 configuration workflow.

The released V1 includes execution-time drift protection, stronger reparse-point path validation, staged ADD writes, best-effort UPDATE rollback, exact relative-path Sync Plan output, improved BAT/config UX, and expanded negative/boundary verification.

The V1 RC was committed to the public `main` branch and the intended release commit was verified remotely. V1 is now closed for feature development; future capabilities belong in V2/Future unless required to fix a release-blocking defect.

See:

```text
docs/roadmap.md
```

for the development lifecycle.

---

## V1 Non-Goals

V1 intentionally does not include:

- automatic deletion;
- full mirror synchronization;
- bidirectional sync;
- conflict merging;
- `.mimic-state.json`;
- stale/exclusive historical classification;
- rename detection;
- filesystem watching;
- background sync;
- Directory Junction distribution;
- symbolic-link distribution;
- cloud synchronization;
- EXE packaging;
- Electron or Tauri packaging;
- direct filesystem mutation from the Web Configurator.

---

## V2 Direction

V2 may introduce historical state through:

```text
.mimic-state.json
```

This could support distinctions such as:

```text
MANAGED
STALE
EXCLUSIVE
POSSIBLE RENAME
```

A specific V2 concern is rename detection: a previously managed folder disappearing from the Source and a new folder appearing should not automatically be treated as unrelated `STALE + NEW` when evidence may indicate a rename.

---

## Future Direction

A later version may explore shared-reference distribution through Windows Directory Junctions or related linking strategies.

That model could reduce duplicated physical storage, but it introduces different requirements around NTFS behavior, path availability, permissions, broken references, backup behavior, portability, and ownership semantics.

It remains outside the V1 scope.

---

## Documentation

For deeper details:

- `docs/architecture.md` — product architecture and component responsibilities;
- `docs/sync-model.md` — authoritative V1 synchronization behavior;
- `docs/roadmap.md` — milestone plan, V2 direction, and release lifecycle.

---

## License

This repository is provided under the MIT License. See `LICENSE`.
