# Test Fixtures

These folders intentionally begin in different states.

- `mimic/` is the Source baseline.
- `target-a/` seeds the Add Only test.
- `target-b/` seeds the Update Only test.
- `target-c/` seeds the Add + Update test.

Each target contains:

- one outdated shared file;
- one identical shared file;
- one target-only private file.

The Source additionally contains missing content, a root-level file, and a nested path with spaces and Unicode characters.

`run-tests.ps1` copies these fixtures into `tests/tmp/` before every scenario. The checked-in fixture files themselves are not mutated during testing.

## Unicode fixture note

`run-tests.ps1` also creates `nested folder\深层\guide.txt` dynamically inside
the temporary Source tree. This avoids making the Unicode-path verification
depend on how a downloaded ZIP was extracted on a particular Windows system.
The test still verifies that Mimic Sync itself can scan and replicate the
Unicode path.

