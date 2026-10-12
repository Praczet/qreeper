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
| `qreeper:what` | Replay recent whispers in scrollback. |
| `qreeper:movement` | Show queued movement/look intents the tracker is still waiting on. |
| `qreeper:map` | ASCII map of the current level, plus conflicts, unexplored exits and notes. |
| `qreeper:rooms [realm\|area\|level [VALUE]]` | Room catalogue, flat, grouped, or filtered. |
| `qreeper:realm NAME` / `qreeper:area NAME` / `qreeper:level N` | Set geography on the current room by hand. |
| `qreeper:note TEXT` | Add a note to the current room. |
| `qreeper:notes` / `qreeper:notes-for-room ID` | Show notes. |
| `qreeper:notes-by-room` | Rooms that have notes. |
| `qreeper:forget-note ID` | Delete a note from the current room. |

Movement (`n`, `ne`, `north`, `u`, ...), named exits (`enter`, `out`, `tutorial`) and `l`/`look` are aliased so the tracker can queue them. Commands outside that list still work; they just don't create map edges.

## How movement becomes a map edge

1. A movement alias queues an intent. That is a claim, not a fact.
2. A room header arrives. The oldest intent explains it, unless:
   - a failure message already removed it (`triggers/movement.lua`);
   - it was a compass direction the previous room never advertised;
   - it is older than 8 seconds.
3. Only then is `from --direction--> to` written. An existing exit pointing elsewhere is never overwritten.

Arrivals with nothing queued (follow, teleport, unaliased commands) update the position but record no edge.

## Tests

Pure Lua, no Blightmud needed:

```bash
lua5.4 tests/tracker_test.lua
LUA_CPATH="$HOME/.luarocks/lib/lua/5.4/?.so;;" lua5.4 tests/memory_test.lua
```

`memory_test.lua` takes an optional path to an existing database and migrates it. Give it a copy, never the live file.

## Known limits

- Failure messages in `triggers/movement.lua` are generic guesses. Add the real 3Scapes wording when you see it.
- A room is identified by `name|sorted exits`. Two different rooms with the same name and exits will be merged. That is an open design decision.
- Map coordinates are recomputed on every `qreeper:map` and never stored, so rooms can shift as edges are added. Only the current room's spatial component is placed.
- No QREEP snapshot publisher yet. That is Step 2.

See `docs/` for the agent rules and the data repair log.
