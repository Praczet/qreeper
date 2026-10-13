# Qreeper

A Blightmud companion for exploring 3Scapes. It watches room output, remembers rooms, directed exits and notes in SQLite, draws a rough map, and whispers opinions on the status line. It does not play for you and it does not pretend a guess is geography.

## Running

Blightmud needs Lua 5.4 `lsqlite3` from luarocks, hence the wrapper:

```bash
#!/usr/bin/env bash
eval "$(luarocks --lua-version=5.4 path)"
export LD_PRELOAD=/usr/lib/liblua5.4.so
exec blightmud "$@"
```

`LD_PRELOAD` works on this machine. It is not a universal fix, so don't copy it elsewhere without checking.

World database: `~/.local/share/blightmud/qreeper/worlds/3scapes.sqlite`. Back it up before experiments (`sqlite3 3scapes.sqlite ".backup 'copy.sqlite'"`).

## Commands

| Command | What it does |
| --- | --- |
| `qreeper` | Ping. |
| `qreeper:help` | All commands, grouped, with one line each. |
| `qreeper:what` | Replay recent whispers in scrollback. |
| `qreeper:movement` | Show queued movement/look intents the tracker is still waiting on. |
| `qreeper:map` | ASCII map of the current level, plus conflicts, unexplored exits and notes. |
| `qreeper:goto N` / `qreeper:goto #N` | Start a journey to room N: prints the route, then whispers the remaining moves after every room. Ends on arrival. |
| `qreeper:stay` | End the current journey. |
| `qreeper:check` | List room pairs that record the same direction both ways (`36 east → 37`, `37 east → 36`): almost always lookalike rooms merged into one. Prints the `qreeper:forget-room` fix. |
| `qreeper:forget-room N` | Delete a misidentified room and its outgoing exits so the area can be re-walked. Refuses rooms with notes. |
| `qreeper:relayout` | Forget stored QREEP map positions and lay out the current map again. Rooms keep their maps, types, names and realms; other maps are placed again when you visit them. |
| `qreeper:rooms [realm\|map\|level [VALUE]]` | Room catalogue, flat, grouped, or filtered. |
| `qreeper:where` | Where you are: room number, name, level and cell, map (type, realm, entrance), exits with the doors to other maps, the room you came from, note count. |
| `qreeper:level N` | Set the current room's level by hand. |
| `qreeper:map-type TYPE [NAME]` | Run in the first room inside a building, cave, sewer…: labels the current map. If you came in by a compass exit, the room (and whatever lies behind it) is split off into a new map and that exit becomes a door. Asks first when the split would take most of the map (you may be standing outside); repeat the command within a minute to confirm. Never splits off the map's own first room (#1 for Maple Street): that always means you are outside. Refuses when it never saw how you came in (just after login or a reload): step out and back in. |
| `qreeper:map-types` | Current map and the known types. |
| `qreeper:map-type-add NAME` | Add a type to the list (`outdoor`, `building`, `cave` to start with). |
| `qreeper:portal REALM` | Run just after stepping through a realm gate: the exit you used becomes a portal and this map lies in REALM. Maps entered from here inherit it. |
| `qreeper:realm NAME` | Set the current map's realm (Foundation, or one of the three realms). |
| `qreeper:map-merge` | Undo a split: the current map rejoins its neighbour across the compass door. Maps behind named exits stay separate. |
| `qreeper:note TEXT` | Add a note to the current room. |
| `qreeper:notes` / `qreeper:notes-for-room ID` | Show notes. |
| `qreeper:notes-by-room` | Rooms that have notes. |
| `qreeper:forget-note ID` | Delete a note from the current room. |

Movement (`n`, `ne`, `north`, `u`, ...), named exits (`enter`, `out`, `tutorial`, `jump`, `omp`, `gswap`, `wishroom`, `exit`, `gate`) and `l`/`look` are aliased so the tracker can queue them. Any other named exit the current room advertises in its header (`stables` in `(w,enter,n,s,stables)`) is tracked too: an alias for exactly those words is registered on arrival and replaced in the next room. Other commands still work; they just don't create map edges.

## How movement becomes a map edge

1. A movement alias queues an intent. That is a claim, not a fact.
2. A room header arrives. The oldest intent explains it, unless:
   - a failure message already removed it (`triggers/movement.lua`);
   - it was a compass direction the previous room never advertised;
   - it is older than 8 seconds.
3. Only then is `from --direction--> to` written. An existing exit pointing elsewhere is never overwritten.

Arrivals with nothing queued (follow, teleport, unaliased commands) update the position but record no edge.

Levels: a room discovered by `up`/`down` gets the previous room's level ±1; other moves keep the level. An unknown previous level counts as 0, so the first room is level 0 and every room after it gets one. On later visits a confirmed `up`/`down` into a room whose stored level disagrees produces a whisper and a scrollback line with the `qreeper:level N` fix. Nothing is changed automatically.

## Journeys

`qreeper:goto 18` finds the shortest route over exits that have actually been walked, in their recorded direction. One exception, for routing only: after walking `down` into a room that lists an unexplored `up`, that `up` is offered as the probable way back, marked `u?` and costed as three walked moves so a known route still wins. Nothing is written to the database; the real move records what the exit actually does. The full route with room ids goes to scrollback; the whisper line shows the moves to type.

Only the destination is remembered. After every confirmed arrival the route is recalculated from where you really are, so detours and failed moves just produce new directions. Qreeper never sends the moves for you. Losing the position pauses the journey until a room is recognised again.

## QREEP map snapshot

`publisher/` writes `~/.local/state/qreeper/map.json` (or `$QREEP_QREEPER_MAP_PATH`) for the QREEP minimap and Atlas. Format: schema version 1, documented on the consumer side in QREEP's `modules/qreeper/README.md`.

- Written after every finished room observation, note change, geography change, on load, and every 60 seconds as a heartbeat. QREEP calls a snapshot stale after 5 minutes without a new revision, so a running Qreeper never looks stale; a closed one does.
- Atomic: written to `map.json.tmp` in the same directory, then renamed over `map.json`.
- `revision` is `max(previous + 1, epoch seconds)`, continued from the existing file, so it only goes up, including across restarts.
- Positions are stored in SQLite (schema v2: `x`, `y`, `z`, `position_status`) the first time a room is placed, and never moved after that. A room next to a placed one takes the cell its compass exit implies. Exits confirmed in both directions are followed before one-way ones, which keeps maze contradictions on the weakest evidence. A collision leaves it unplaced. A component with no placed room is laid out when you stand in it, shifted east of everything else.
- Maps (schema v4–v5: `maps`, `map_types`, `rooms.map_id`, `exits.boundary`): every placed room belongs to one map, a separately laid-out group such as the streets, a building or a dungeon. Compass and `up`/`down` exits keep a room in its neighbour's map, so a building's floors are z levels of its own map. Named exits (`enter`, `out`, `board`, ...) and compass exits marked as a `door` or `portal` are the boundaries between maps; layout never crosses them. The rooms behind one become a new map when you first stand there, named after the entrance room (the `Newbie Tower` of `Newbie Tower: Forest`), of type `outdoor`, in the realm of the map you came from. `qreeper:map-type` / `qreeper:portal` / `qreeper:realm` correct that by hand. Coordinates are only comparable inside one map. Rooms placed before v4 were grouped by compass connectivity, so their layout did not change. v5 dropped the per-room `realm`/`area` labels: realm is a property of the map.
- Published as `mapId` per room, `boundary` (`null`, `"door"`, `"portal"`) per exit, and a top-level `maps` list of `{ id, name, type, realm, entranceRoomId }`.
- `geometry` per exit: `unknown` (never travelled), `named` (no compass offset), `unplaced` (an endpoint has no position), `regular` (matches positions) or `irregular` (contradicts them).
- The file is derived output. Nothing reads it back; deleting it is harmless.

## Tests

Pure Lua, no Blightmud needed:

```bash
lua5.4 tests/tracker_test.lua
LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/memory_test.lua
LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/publisher_test.lua [out.json]
```

`memory_test.lua` takes an optional path to an existing database and migrates it. Give it a copy, never the live file.

## Known limits

- Failure messages in `triggers/movement.lua` are generic guesses. Add the real 3Scapes wording when you see it.
- Identity (`identity.lua`): name + exits narrow the candidates; then, in order: the exit just taken (if already recorded), description similarity (word overlap ≥ 0.6, or ≥ 0.9 when the map places the lookalike more than a cell away from where the move should land, or when several rooms already share the name and the exit just taken doesn't already lead there: the Chaos Mountains and Valley of Eras build every room from the same stock sentences), the detail lines after "Obvious exits" (statues, fixed items; only lines that repeat on every visit are kept), and "a confirmed move does not land where it started". Details only matter for rooms that are otherwise identical (Hall of Champions); ordinary rooms ignore them, so monsters can't split a room. Those lookalike rooms are booked when their details arrive (prompt, next header, or ~1 s), so they lag slightly without a prompt. If nothing tells rooms apart, the position is dropped rather than guessed. Fix a past merge with `qreeper:forget-room N` and walk it again.
- `qreeper:map` (the terminal map) still recomputes its own layout every time and ignores the stored positions, so it can disagree with QREEP. Switching it over is a small follow-up.
- Components you have not stood in since schema v2 stay unplaced on the QREEP map until you visit them.
- Publishing rebuilds the whole snapshot each time. Fine at this size; per-area snapshots are the fix if it ever gets slow.

See `docs/` for the agent rules and the data repair log.
