# Data repair — 2026-10-13

One-time cleanup of `~/.local/share/blightmud/qreeper/worlds/3scapes.sqlite`.

Backup taken first: `3scapes.backup-20261013-144247-before-eras-repair.sqlite` in the same folder. Its integrity check passed (231 rooms, 820 exits).

## Why

Two Valley of Eras exits pointed at room 190, seven cells from where they start:

| Exit | From | Should land | Recorded |
| --- | --- | --- | --- |
| `223 west` | (134,2) | (133,2) | 190 at (127,2) |
| `225 east` | (132,2) | (133,2) | 190 at (127,2) |

Both moves land on the same empty cell. The likely explanation: (133,2) is a real room built from the same stock sentences as 190, word for word. The identity rules only raised the description threshold for a far, crowded candidate, and an identical text passes any threshold, so the new room was merged into 190.

In QREEP's Atlas this showed up as rooms 221–232 dragged into the 19x block.

## What changed

| Row | Action | Reason |
| --- | --- | --- |
| `223 west → 190` | destination set to NULL | Far lookalike merge, see above. Relearned on the next walk. |
| `225 east → 190` | destination set to NULL | Same. |
| `212 north → 190` | destination set to NULL | Re-merged by the still-running old plugin after the first repair; `212` is at (133,3), so it points at the same missing cell (133,2). Third confirmation. |

Result: 820 exits, `PRAGMA integrity_check` ok, `PRAGMA foreign_key_check` clean. Rooms, descriptions, and notes were not touched. Room 190 keeps all eight of its own exits, which agree with the grid.

Blightmud was running (restarted by then) when the update was applied. SQLite took the committed write; the published snapshot catches up on the next publish.

## Code change in the same session

`identity.lua`: a candidate that is `far` and `crowded`, with no graph evidence (`predicted_id`), never matches on description alone. It becomes a `twin`. Covered by two new cases in `tests/identity_test.lua`.

Trade-off: in a maze with genuinely non-Euclidean exits, a revisit through a weird exit now creates a duplicate room instead of a correct merge. A duplicate is visible and can be removed with `qreeper:forget-room N`; a wrong merge silently rewires the graph.

## Rollback

With Blightmud closed:

```bash
cd ~/.local/share/blightmud/qreeper/worlds
cp 3scapes.sqlite 3scapes.after-eras-repair.sqlite
cp 3scapes.backup-20261013-144247-before-eras-repair.sqlite 3scapes.sqlite
```
