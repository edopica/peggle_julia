# Pinned reference source

The Julia port is validated against one frozen Lua reference revision. This
directory contains a byte-for-byte export of that revision.

| Field | Value |
| --- | --- |
| Repository | `git@github.com:edopica/peggle_evolved.git` |
| Revision (full) | `d17f6e7089b6e761f4367fc6a6dcd5b4da0309b9` |
| Revision (short) | `d17f6e7` |
| Commit date | 2026-10-03 |
| Commit subject | Pool collision-side allocations in physics and contact presentation |
| Tree hash | `3dc7ddfe19916e149d2531b20c73463c28a202c8` |
| Export method | `git archive --format=tar --prefix=peggle_evolved/ d17f6e7` |
| Extracted tree | `reference/peggle_evolved/` |
| File manifest | `reference/files.sha256` (133 files) |
| Config hash (`src/config.lua`) | `455757c900c604563865b5195eda2f31cfeba3d8666b6d782390e38c47e91d4d` |

The commit `d17f6e7` was the working-tree `HEAD` when M0 started. The working
tree also contained uncommitted edits to `src/systems/path.lua` and
`src/systems/physics.lua`. Those edits are deliberately excluded: a reference
must be reconstructible from a committed revision. If they are committed later,
the pin must be advanced and all fixtures and baselines re-captured.

## Verification

Run `scripts/verify_reference.sh` to check every vendored file against
`reference/files.sha256`:

```bash
scripts/verify_reference.sh
```

The script fails on any missing, extra, or modified file. The pin is advanced
only by re-exporting a new revision and regenerating the manifest.
