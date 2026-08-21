# Mimic Sync — Sync Model

## 1. Purpose

This document defines the synchronization behavior contract for Mimic Sync V1.

It describes:

- what Mimic Sync compares;
- how source and target states are classified;
- how each synchronization policy turns states into actions;
- what content is explicitly protected from modification;
- how a sync plan is generated before execution;
- what V1 does and does not infer.

This document is intentionally narrower than `architecture.md`.

`architecture.md` defines the product architecture.

`sync-model.md` defines the file and folder synchronization semantics that the CLI engine, Web Configurator, tests, and documentation must all follow.

---

## 2. Core Direction

Mimic Sync V1 is one-way.

```text
Source / Mimic Folder
        M
        │
        ▼
Target Folder
        A
```

The source is the reference side for content that exists in the source.

The target may also contain independent content that does not exist in the source.

Mimic Sync V1 does not treat target-only content as an error and does not delete it.

The direction is therefore:

```text
Source → Target
```

not:

```text
Source ↔ Target
```

and not:

```text
Source = Target mirror
```

---

## 3. Unit of Comparison

Mimic Sync compares source content against each target using relative paths.

Example:

```text
Source:
M\
└── templates\
    └── report.md
```

and:

```text
Target:
A1\
└── templates\
    └── report.md
```

The corresponding logical item is:

```text
templates\report.md
```

The absolute source and target paths are different, but the relative path is the same.

This relative-path model allows the same source tree to be evaluated independently against multiple targets.

---

## 4. File and Folder Scope

For V1, synchronization operates recursively.

A source folder may contain:

```text
M\
├── folder-a\
│   ├── file-1.txt
│   └── nested\
│       └── file-2.txt
│
├── folder-b\
│   └── file-3.json
│
└── root-file.md
```

The comparison engine must preserve relative structure when adding or updating content in a target.

For example:

```text
M\nested\config.json
```

maps to:

```text
A1\nested\config.json
A2\nested\config.json
A3\nested\config.json
```

depending on the policy configured for each target.

---

## 5. Comparison States

For each source-relative path, Mimic Sync V1 uses four primary states.

### 5.1 MISSING

The item exists in the source but does not exist in the target.

```text
Source: YES
Target: NO
```

Example:

```text
M\
└── skill-a\
    └── SKILL.md

A1\
└── (skill-a missing)
```

Classification:

```text
MISSING
```

---

### 5.2 SAME

The corresponding source and target files exist and are equivalent under the V1 comparison rule.

```text
Source: YES
Target: YES
Content: SAME
```

Classification:

```text
SAME
```

No synchronization policy should rewrite content already classified as `SAME`.

---

### 5.3 DIFFERENT

The corresponding source and target files both exist, but their contents differ.

```text
Source: YES
Target: YES
Content: DIFFERENT
```

Classification:

```text
DIFFERENT
```

Whether this becomes an `UPDATE` depends on the configured target policy.

---

### 5.4 TARGET-ONLY

The item exists in the target but not in the source.

```text
Source: NO
Target: YES
```

Example:

```text
M\
├── shared-a\
└── shared-b\

A1\
├── shared-a\
├── shared-b\
└── agent-exclusive\
```

Classification:

```text
TARGET-ONLY
```

In V1:

```text
TARGET-ONLY → IGNORE
```

under every synchronization policy.

Mimic Sync V1 does not infer whether this content is:

- intentionally exclusive;
- an old shared item;
- stale;
- renamed;
- manually created.

That distinction belongs to future state-aware versions.

---

## 6. V1 Action Types

A Sync Plan may contain the following actions.

### ADD

Create missing source content in the target while preserving its relative structure.

```text
MISSING → ADD
```

only when the configured policy permits adding.

---

### UPDATE

Replace or synchronize a target file with the current source version when both exist but differ.

```text
DIFFERENT → UPDATE
```

only when the configured policy permits updating.

---

### SKIP

Take no write action.

Typical reasons:

```text
SAME
```

or:

```text
MISSING under Update Only
```

or:

```text
DIFFERENT under Add Only
```

`SKIP` is intentional policy behavior, not an error.

---

### IGNORE

Do not manage the item because it is outside the source-defined V1 scope.

Typical case:

```text
TARGET-ONLY
```

`IGNORE` means:

> Mimic Sync recognizes the item exists in the target but deliberately leaves it untouched.

---

## 7. Synchronization Policies

Each target independently selects one of three V1 policies.

---

## 7.1 Add Only

Configuration value:

```text
add-only
```

Purpose:

> Add source content that is missing from the target, but never modify content already present in the target.

Behavior:

| State | Action |
|---|---|
| MISSING | ADD |
| SAME | SKIP |
| DIFFERENT | SKIP |
| TARGET-ONLY | IGNORE |

Example:

```text
Source M
├── A.txt      version 2
├── B.txt
└── C.txt

Target A1
├── A.txt      version 1
├── B.txt      same
└── local.txt
```

Result under `add-only`:

```text
A.txt      → SKIP
B.txt      → SKIP
C.txt      → ADD
local.txt  → IGNORE
```

After execution:

```text
Target A1
├── A.txt      version 1   # unchanged
├── B.txt
├── C.txt                  # added
└── local.txt              # untouched
```

Typical uses:

- distribute missing resources without overwriting local customization;
- bootstrap folders that may later diverge;
- require manual approval before existing content can be replaced.

---

## 7.2 Update Only

Configuration value:

```text
update-only
```

Purpose:

> Keep an already-existing target subset current without introducing new source items into that target.

Behavior:

| State | Action |
|---|---|
| MISSING | SKIP |
| SAME | SKIP |
| DIFFERENT | UPDATE |
| TARGET-ONLY | IGNORE |

Example:

```text
Source M
├── A.txt      version 2
├── B.txt
└── C.txt

Target A2
├── A.txt      version 1
├── B.txt      same
└── local.txt
```

Result under `update-only`:

```text
A.txt      → UPDATE
B.txt      → SKIP
C.txt      → SKIP
local.txt  → IGNORE
```

After execution:

```text
Target A2
├── A.txt      version 2   # updated
├── B.txt
└── local.txt              # untouched
```

`C.txt` is not introduced because it did not already exist in the target.

Typical uses:

- maintain an approved subset of shared content;
- allow targets to opt into selected resources only;
- update previously distributed items without automatically expanding target scope.

---

## 7.3 Add + Update

Configuration value:

```text
add-update
```

Purpose:

> Keep the target supplied with all source content and keep corresponding shared content current.

Behavior:

| State | Action |
|---|---|
| MISSING | ADD |
| SAME | SKIP |
| DIFFERENT | UPDATE |
| TARGET-ONLY | IGNORE |

Example:

```text
Source M
├── A.txt      version 2
├── B.txt
└── C.txt

Target A3
├── A.txt      version 1
├── B.txt      same
└── local.txt
```

Result under `add-update`:

```text
A.txt      → UPDATE
B.txt      → SKIP
C.txt      → ADD
local.txt  → IGNORE
```

After execution:

```text
Target A3
├── A.txt      version 2
├── B.txt
├── C.txt
└── local.txt
```

Typical uses:

- centrally maintained shared assets;
- common scripts;
- shared templates;
- common AI-agent skills;
- resources where the source should remain authoritative.

---

## 8. Policy Matrix

The V1 behavior contract is:

| State | Add Only | Update Only | Add + Update |
|---|---|---|---|
| MISSING | ADD | SKIP | ADD |
| SAME | SKIP | SKIP | SKIP |
| DIFFERENT | SKIP | UPDATE | UPDATE |
| TARGET-ONLY | IGNORE | IGNORE | IGNORE |

This matrix is authoritative for V1.

If implementation behavior conflicts with this table, the implementation should be treated as incorrect unless the product contract is explicitly revised.

---

## 9. Per-Target Policies

Policies are target-specific.

One Sync Profile may therefore contain:

```text
Source M
│
├── Target A1 → add-update
├── Target A2 → add-only
└── Target A3 → update-only
```

The CLI must evaluate every target independently.

Example:

```text
Source contains:
shared-a
shared-b
shared-c
```

Target states:

```text
A1
├── shared-a    same
└── local-a

A2
├── shared-a    old
└── local-b

A3
├── shared-a    old
├── shared-b    same
└── local-c
```

Policies:

```text
A1 = add-update
A2 = add-only
A3 = update-only
```

Expected plan:

```text
A1
  ADD shared-b
  ADD shared-c

A2
  ADD shared-b
  ADD shared-c
  SKIP shared-a because Add Only does not update

A3
  UPDATE shared-a
  SKIP shared-c because Update Only does not add
```

All:

```text
local-a
local-b
local-c
```

remain untouched.

---

## 10. Comparison Rule

The V1 engine should not rely only on timestamps to decide whether content differs.

Timestamps can change without content changing, and copied files may preserve or alter timestamps depending on the operation.

For files, a reliable comparison strategy should prioritize actual file content.

A practical V1 approach is:

```text
1. Compare file size.
2. If size differs → DIFFERENT.
3. If size matches → compare file hash.
4. If hashes match → SAME.
5. If hashes differ → DIFFERENT.
```

SHA-256 is suitable for deterministic comparison.

This keeps the meaning of `SAME` tied to actual content rather than metadata alone.

Metadata such as modification time may still be used for reporting or optimization, but it should not silently redefine content equality.

---

## 11. Directory Comparison

Folders themselves are structural containers.

The engine should primarily decide actions from the files and subdirectories they contain.

Example:

```text
M\
└── skill-a\
    ├── SKILL.md
    └── references\
        └── guide.md
```

If `skill-a` does not exist in a target, the required structure is created as part of adding its source content.

If `skill-a` already exists but one nested file is missing:

```text
A1\
└── skill-a\
    └── SKILL.md
```

then:

```text
references\guide.md
```

is classified independently as `MISSING`.

The selected target policy determines whether it is added.

This keeps behavior consistent for nested trees.

---

## 12. Target-Only Content Inside Shared Folders

Target-only protection applies not only to top-level folders, but also to target-only files nested inside otherwise shared folders.

Example:

```text
Source:
M\
└── skill-a\
    └── SKILL.md

Target:
A1\
└── skill-a\
    ├── SKILL.md
    └── private-notes.md
```

`private-notes.md` is:

```text
TARGET-ONLY
```

and must remain untouched in V1.

Therefore, even when `skill-a` is managed from the source, Mimic Sync V1 does not interpret the entire target folder as disposable mirror content.

This is why V1 must avoid destructive mirror behavior.

---

## 12.1 Reparse-Point Boundary

V1 does not use reparse points, symbolic links, or Directory Junctions as synchronization transport.

- A Source or Target root that is itself a reparse point is rejected.
- Reparse-point items encountered inside the Source are skipped and are not treated as distributable Source content.
- Target-only reparse points are left untouched.
- If a Source-managed relative path would require the CLI to traverse or write through a Target reparse point, the Sync Plan is blocked before mutation.

This prevents a Target path from silently redirecting an `ADD` or `UPDATE` operation into another physical location.

---

## 13. Sync Plan

Before any write operation, the CLI must build an actual Sync Plan from the real filesystem.

A Sync Plan should summarize only actions relevant to the configured policy.

Example:

```text
SYNC PLAN

Target: Codex Skills
Mode: Add + Update

  [ADD]    new-skill
  [UPDATE] portfolio-packaging

Target: Claude Skills
Mode: Update Only

  [UPDATE] shared-review-skill

Target: Archive
Mode: Add Only

  No changes.
```

Items that are `SAME` normally do not need to clutter the default plan.

Policy-driven `SKIP` items may be summarized when useful, especially in verbose or audit output.

Target-only content should not be listed as an actionable change.

---

## 14. Confirmation Gate

The default interactive execution model is:

```text
Scan
→ Show Plan
→ Ask
→ Write
```

The prompt should be explicit:

```text
Proceed with sync? [Y/n]
```

V1 default behavior:

```text
Y or Enter → proceed
n          → cancel
```

If cancelled:

```text
No target content is changed.
```

This confirmation is a product safety feature, not merely terminal UX.

---

## 15. Final Report

After execution, Mimic Sync should report results independently for every target.

Example:

```text
SYNC REPORT

Target A1
  Added: 2
    + skill-a
    + skill-b

  Updated: 1
    * shared-config

Target A2
  No changes.

Target A3
  Updated: 1
    * shared-script

  Failed: 1
    ! templates\report.md
```

The report should distinguish:

- successful additions;
- successful updates;
- no-change targets;
- failed operations.

A failure in one target should be reported clearly and should not be disguised as a successful overall sync.

---

## 16. Error Boundaries

The CLI should stop before mutation when the Sync Profile itself is invalid.

Examples:

- source path missing;
- source path is not a directory;
- target path missing when V1 requires an existing target;
- unsupported mode;
- malformed JSON;
- duplicate or invalid target configuration;
- source and target resolve to an unsafe or nonsensical relationship.

Execution-time failures should be reported per target or per item where practical.

The engine should prefer controlled failure over partial silent behavior.

---

## 17. Source and Target Relationship Safety

V1 should validate obvious unsafe path relationships.

Examples requiring rejection or explicit handling include:

```text
Source == Target
```

and recursive configurations such as:

```text
Target is inside Source
```

or:

```text
Source is inside Target
```

when such relationships could make copied content recursively appear in future scans.

The exact validation implementation may be finalized in the CLI milestone, but the architecture should not assume every pair of syntactically valid paths is safe.

---

## 18. No Deletion Semantics

V1 never converts absence from the source into a delete instruction.

Example:

```text
Previous source:
M\
├── A
├── B
└── C

Current source:
M\
├── A
└── B

Target:
A1\
├── A
├── B
└── C
```

V1 sees:

```text
C = TARGET-ONLY
```

and therefore:

```text
IGNORE
```

It does not know whether C is:

- stale;
- exclusive;
- intentionally preserved;
- renamed in the source;
- copied manually.

Deleting it would require historical state and stronger ownership semantics.

That is outside V1.

---

## 19. No Rename Inference in V1

V1 compares the current source and target snapshots by relative path.

If:

```text
old-folder
```

disappears from the source and:

```text
new-folder
```

appears, V1 does not infer that one is a rename of the other.

It will treat them according to the current snapshot:

```text
old-folder in target only → TARGET-ONLY → IGNORE

new-folder missing in target
→ ADD under Add Only / Add + Update
→ SKIP under Update Only
```

Historical rename detection is reserved for V2 with state-aware evidence.

---

## 20. Execution-Time Revalidation

The Sync Plan is derived from a read-only filesystem snapshot, but the filesystem can change between preview and execution. V1 hardening therefore treats the plan as an optimistic contract rather than permission to overwrite whatever exists later.

Immediately before a planned write, the engine revalidates the relevant state:

- planned `ADD` actions confirm that the Source file still matches the scanned content and that the Target path is still missing;
- planned `UPDATE` actions confirm that both the Source and existing Target still match the hashes observed during the scan;
- if the Target changed after preview, Mimic Sync refuses to overwrite the newer local state and reports a failure instead;
- target path components are rechecked for reparse points before mutation;
- ADD writes are staged beside the destination before the final move;
- UPDATE writes keep a temporary pre-update backup so ordinary copy/verification failures can attempt rollback.

This does not make the whole multi-target run transactional. A failure can still occur after earlier independent actions succeeded, and such partial execution is reported explicitly. The goal is to prevent silent destructive overwrite and reduce partial-file failure risk without turning V1 into a transactional filesystem system.

---

## 21. Web Configurator Boundary

The Web Configurator describes intended behavior.

It can summarize:

```text
Source: D:\Shared\Mimic

Target A
Mode: Add + Update

Target B
Mode: Update Only
```

But it must not claim:

```text
Target A will add skill-x
Target B will update skill-y
```

unless an actual filesystem scan has been performed by the execution layer.

Therefore:

```text
Configurator Summary = configuration summary
CLI Sync Plan         = filesystem-derived action plan
```

These are different artifacts.

---

## 22. AI-Agent Skills as a Reference Case

A practical use case is:

```text
Mimic Skills
│
├── shared-skill-a
├── shared-skill-b
└── shared-skill-c
```

distributed to:

```text
Codex Skills
Claude Skills
Other Agent Skills
```

Each agent may also contain:

```text
agent-exclusive-skill
```

Because the item is target-only:

```text
TARGET-ONLY → IGNORE
```

This use case demonstrates the general model but does not change the core synchronization semantics.

---

## 23. Generic Folder Example

The same engine can manage project templates.

```text
M = Common Project Assets

M\
├── templates\
├── scripts\
└── shared-config\
```

Targets:

```text
Project A → add-update
Project B → add-only
Project C → update-only
```

This demonstrates why synchronization policy belongs to each target rather than to the source as a whole.

---

## 24. V1 Test Contract

At minimum, automated or controlled fixture tests should verify:

### Add Only

- missing content is added;
- different existing content is not overwritten;
- identical content is not rewritten;
- target-only content remains untouched.

### Update Only

- missing content is not added;
- different existing content is updated;
- identical content is not rewritten;
- target-only content remains untouched.

### Add + Update

- missing content is added;
- different existing content is updated;
- identical content is not rewritten;
- target-only content remains untouched.

### Shared behavior

- nested directories preserve structure;
- multiple targets can use different policies;
- spaces in paths are handled;
- Unicode paths are handled;
- invalid paths produce controlled errors;
- no mutation happens before confirmation;
- failed operations appear in the final report.

---

## 25. V1 Sync Contract Summary

The entire V1 model can be reduced to this:

```text
For every target:

1. Read its configured policy.
2. Compare source content against the target by relative path.
3. Classify each relevant item:
   MISSING / SAME / DIFFERENT / TARGET-ONLY.
4. Convert state into action using the policy matrix.
5. Build a read-only Sync Plan.
6. Show the user the planned changes.
7. Require explicit confirmation.
8. Execute only approved ADD / UPDATE actions.
9. Never delete or modify TARGET-ONLY content.
10. Report what changed and what failed.
```

Authoritative policy matrix:

| State | Add Only | Update Only | Add + Update |
|---|---|---|---|
| MISSING | ADD | SKIP | ADD |
| SAME | SKIP | SKIP | SKIP |
| DIFFERENT | SKIP | UPDATE | UPDATE |
| TARGET-ONLY | IGNORE | IGNORE | IGNORE |

This is the V1 synchronization contract.
