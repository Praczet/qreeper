# Data repair — 2026-10-14

One-time cleanup of `~/.local/share/blightmud/qreeper/worlds/3scapes.sqlite`.

Backup taken first: `3scapes.backup-20261014-101713-before-chaos-repair.sqlite` in the same folder. Its integrity check passed.

## Why

`168 cave` is recorded as leading to 169 (The Chaos Mountains). On the next walk the arrival became a new room, 233, although name, exits and the detail line (Orsurus the Guide) were the same. The Chaos Mountains redraw a room's description from stock sentences on every visit. The two texts scored 0.42, below `SIMILAR` (0.6), and the identity rules let the text overrule the recorded exit.

From 233 on there was no graph evidence, so 234–236 were made as copies of 170 and the rooms after it.

## What changed

| Rows | Action | Reason |
| --- | --- | --- |
| rooms 233, 234, 235, 236 | deleted (their exits cascade) | Duplicates of 169 and its neighbours. No notes, no exit from another room pointed into them. |

Result: 231 rooms, 820 exits, `PRAGMA integrity_check` ok, `PRAGMA foreign_key_check` clean. `168 cave → 169` is untouched.

Blightmud was running when the update was applied.

## Code change in the same session

`identity.lua`: when the exit just taken leads to a candidate whose text disagrees, and that candidate has recorded details, the plugin waits for the details. If one detail line is shared, the candidate matches. Without a recorded exit, or without a shared detail, nothing changes. Covered by new cases in `tests/identity_test.lua`.

## Rollback

With Blightmud closed:

```bash
cd ~/.local/share/blightmud/qreeper/worlds
cp 3scapes.backup-20261014-101713-before-chaos-repair.sqlite 3scapes.sqlite
```

---

# Second repair — 2026-10-14, Foothills

Backup taken first: `3scapes.backup-20261014-102139-before-foothills-repair.sqlite`. Its integrity check passed.

## Why

`193 east` had never been walked, so there was no recorded exit. Room 231 (Foothills in the Chaos Mountains) already sat exactly on the cell `east` lands on, (22,1). The name is crowded, so the text needed 0.9, and the Chaos text is redrawn on every visit. The arrival became a new room, again numbered 233.

While checking, a second fault showed up: a long "Obvious exits" line wraps, and its second line (`southwest, south, northwest`) was stored as a detail. 43 rooms, most of the Valley of Eras and the Foothills, carried that line as their only detail. The detail rules were comparing junk there.

## What changed

| Rows | Action | Reason |
| --- | --- | --- |
| room 233 | deleted (its exits cascade, `193 east` destination set to NULL) | Duplicate of 231. No notes. Relearned on the next walk. |
| `details` of 42 other rooms | set to NULL | Their only detail line was the wrapped exits line. |

Result: 231 rooms, 820 exits, `PRAGMA integrity_check` ok, `PRAGMA foreign_key_check` clean.

## Code change in the same session

- `memory.lua` / `identity.lua`: a candidate exactly on the cell the move lands on (`here`) is the room, whatever the text, when no exit is recorded yet. A recorded exit still outranks it.
- `observer.lua`: the first line after "Obvious exits" is not a detail when it lists only the room's own exits.

## Rollback

With Blightmud closed:

```bash
cd ~/.local/share/blightmud/qreeper/worlds
cp 3scapes.backup-20261014-102139-before-foothills-repair.sqlite 3scapes.sqlite
```

---

# Third repair — 2026-10-14

Backup: `3scapes.backup-20261014-102342-before-third-repair.sqlite` (integrity ok).

Blightmud was still running the code from before both fixes, so walking `193 east` and then `west` made two more duplicates: 233 (on 231's cell) and 234. Room 193 had the wrapped exits line stored as its detail again.

| Rows | Action |
| --- | --- |
| rooms 233, 234 | deleted (no notes; `193 east` destination set to NULL) |
| `details` of 193 | set to NULL (wrapped exits line) |

Result: 231 rooms, 820 exits, integrity and foreign keys clean.

---

# Guessed ways back — 2026-10-14

Backup: `3scapes.backup-20261014-102833-before-way-back.sqlite` (integrity ok).

The map showed 31 connections walked in one direction only (`172 south → 231`, but `231 north` unknown). Exits are only recorded when walked.

## Code change

- Schema v6: `exits.guessed`. After a walked compass or up/down move `A dir → B`, B's advertised, unexplored opposite exit is filled with A and marked guessed (`Memory:guess_way_back`).
- A real walk always overwrites a guess (`connect_rooms`). Identity ignores guesses (`get_room_exits` reports them as unexplored), so a wrong guess cannot cause a wrong merge. The navigator routes over them as probable; placement does not use them as geometry. `qreeper:where` shows them as `#N?`, the snapshot carries `guessed: true`.

## What changed in the data

The plugin's own `Memory` migrated the database to v6 and ran `guess_way_back` for every walked exit: 31 guessed ways back, exactly the one-way list. Result: 233 rooms, 836 exits, integrity ok, foreign keys clean.

---

# Fourth repair — 2026-10-14, `192 south`

Backup: `3scapes.backup-20261014-103128-before-235-repair.sqlite` (integrity ok).

`192 south` was recorded (walked) to 194, and 194 sits on the cell south of 192. The text was redrawn and 194 has no details, so neither earlier rule applied: the exit only overrode the text with a shared detail, the position only counted without a recorded exit. A twin, 235, was made on a new map 38.

| Rows | Action |
| --- | --- |
| room 235 | deleted (no notes, nothing led into it) |
| maps 37, 38 | deleted (no rooms: 37 left over from the first repair, 38 held only 235) |

Code: `identity.lua` now also accepts the landing-cell candidate when the recorded exit leads to it. Exit and position agreeing outrank the text.

Result: 233 rooms, 836 exits, integrity and foreign keys clean.
