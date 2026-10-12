# Data repair — 2026-10-12

One-time cleanup of `~/.local/share/blightmud/qreeper/worlds/3scapes.sqlite`, done with Blightmud closed.

Backup taken first: `3scapes.backup-20261012-132321-before-repair.sqlite` in the same folder. Its integrity check passed (84 exits).

## Why

The old tracker kept a single pending direction and never cleared it on a failed move. A refused or fast-overwritten command could wire the next arrival to the wrong direction. The fixed tracker (FIFO intents, advertised-exit check, expiry, failure triggers) prevents new cases. This repair removes the ones already recorded.

Evidence was found by comparing each stored exit with the exits the room's own header advertises (the part of `fingerprint` after `|`).

## What changed

| Row | Action | Reason |
| --- | --- | --- |
| `11 north → 8` | deleted | Room 11 advertises only `enter,south`. `11 enter → 8` already exists. Stale-intent edge. |
| `1 west → ?` | deleted | Not advertised by room 1, never travelled. Probably copied from room 2's exits by an earlier code version. |
| `2 southeast → ?`, `2 southwest → ?` | deleted | Not advertised by room 2, never travelled. Same story in reverse. |
| `1 south → 2` | destination set to NULL | `1 north → 2` also exists. Both going to the same room is unlikely. The exit stays and will be relearned on the next walk south. |

Result: 80 exits, `PRAGMA integrity_check` ok, `PRAGMA foreign_key_check` clean, no exit left that its room does not advertise. Rooms and notes were not touched.

## Left alone on purpose

Forest edges that break the grid (`18 west → 12`, `21 east → 12`, `18 southwest → 22`, ...) are advertised and plausible for a maze-like forest. The map reports them as conflicts. Re-walk them if they look wrong.

## Rollback

With Blightmud closed:

```bash
cd ~/.local/share/blightmud/qreeper/worlds
cp 3scapes.sqlite 3scapes.after-repair.sqlite
cp 3scapes.backup-20261012-132321-before-repair.sqlite 3scapes.sqlite
```

## Schema version

The same change set added `PRAGMA user_version` migrations to `memory.lua`. On first load the plugin adopts this database as schema v1 without changing tables. `tests/memory_test.lua` was run against a copy to confirm the room and exit counts survive.
