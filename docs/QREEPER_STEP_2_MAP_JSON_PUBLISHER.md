# Qreeper × QREEP — Step 2: Live `map.json` publisher (Lua / Blightmud)

## Assignment

Implement the **Qreeper Lua producer** for the graphical minimap and Atlas implemented in QREEP (Step 1). Work **in the Qreeper plugin repository**, not the QREEP repository, unless a read-only inspection of the consumer is possible. The deliverable is a **working, verified publisher**, not merely a design proposal.

Qreeper observes the text MUD **3Scapes**, persists room knowledge in SQLite, tracks confirmed movement, and provides room notes, realm/area/level, and an approximate graph layout. QREEP is the read-only graphical consumer. Its bar icon toggles the floating minimap (left click) and Atlas (right click); those interactions are **not implemented in this step**.

**Most important prerequisite:** inspect the **actual completed Step 1 QREEP implementation** and its final documented JSON schema/fixture, if accessible. The earlier contract included below is a **baseline**, not license to override a schema that the QREEP agent finalized differently. If Step 1's definitive contract is unavailable, implement the baseline here and explicitly document the assumption, rather than silently inventing another schema. Do not change QREEP's public contract without coordinating it.

## Required reading and inspection

1. Read root `AGENTS.md` and the project's source-grounded documentation, especially `docs/PROJECT-SCOPE.md`, architecture/data-model documentation, and any QREEP integration notes. Respect actual repository rules.
2. Inspect the actual `main.lua` startup and cleanup/reload lifecycle; `memory.lua`/SQLite schema and `get_map()`/notes queries; `tracker.lua`; `observer.lua`; `triggers/room.lua`; `aliases/notes.lua`, `aliases/location.lua`, and any room/connection modification paths; `map/layout.lua`; existing JSON/dependency utilities; and current tests. Do **not** assume the conversational examples represent the current code.
3. Inspect whether the installed Lua runtime/Blightmud offers a suitable JSON encoder (`dkjson`, `cjson`, or existing project utility), filesystem functions, safe directory creation, and other APIs. Verify availability rather than assuming. Avoid adding native modules if pure Lua suffices; any dependency must be documented and tested in embedded Blightmud.
4. Inspect the final QREEP Step 1 file watcher and sample fixture, if accessible. Check required field names, nullability, path, revision behavior, timestamp conventions, geometry status values, and atomic-rename watcher behavior. Record the agreed producer/consumer contract.
5. Before editing, briefly explain the implementation plan and any contract differences. Then implement and test, without stopping after a plan.

## Product and functional contract

Qreeper shall publish an **authoritative, complete latest-state snapshot** to:

```text
~/.local/state/qreeper/map.json
```

The path should resolve from `$XDG_STATE_HOME/qreeper/map.json` where applicable, with `~/.local/state/qreeper/map.json` as fallback; **if Step 1's consumer hardcodes the above path, use that exact shared path until both ends agree on configurable resolution**. Ensure world-specific SQLite data stays in its existing location; this JSON is a disposable derived view, **not** the database or a second source of truth. Keep snapshots local to the user with sensible permissions and no network listener.

**Publish on:**

- Plugin startup, after SQLite initialization and state loading, even when no current room is known (`currentRoomId: null`). Do not fabricate a current room from the last DB visit if the tracker has not established one.
- Every completed, **successfully identified room observation** where current room changes; publish the changed highlight promptly, after durable writes complete.
- New room discovery, added/changed directed connection, observed exit additions, or other map-affecting graph changes.
- Add/delete/edit room note (when such operation exists), realm/area/level assignment or inference, and other metadata edits represented in JSON.
- Explicit optional `qreeper:publish-map` development command if useful; it should republish safely, ideally without gratuitously treating unchanged data as a movement.

Do **not** publish a successful move merely on `tracker:attempt_move()` or a raw direction alias. A typed command is only intent. Failed, canceled, or ambiguous movement must never manufacture a connection, a destination ID, or a false highlight change. A room can have identical name/fingerprint to others; room IDs are the identity. If the existing resolver has limitations, preserve and surface uncertainty; **do not rewrite the resolver or corrupt SQLite as part of this task**.

## JSON v1 baseline (verify against Step 1)

```json
{
  "schemaVersion": 1,
  "world": "3scapes",
  "revision": 42,
  "publishedAt": "2026-10-12T10:00:00Z",
  "currentRoomId": 22,
  "rooms": [
    {
      "id": 22,
      "name": "Newbie Tower: Forest",
      "description": "A trail between dense trees.",
      "realm": "Newbieland",
      "area": "Newbie Tower: Forest",
      "level": 0,
      "x": 0,
      "y": 2,
      "z": 0,
      "positionStatus": "inferred",
      "notes": [
        {"id": 8, "text": "Thieves here", "createdAt": "2026-10-12T09:00:00Z"}
      ]
    },
    {
      "id": 18,
      "name": "Newbie Tower: Forest",
      "description": null,
      "realm": "Newbieland",
      "area": "Newbie Tower: Forest",
      "level": 0,
      "x": 1,
      "y": 1,
      "z": 0,
      "positionStatus": "inferred",
      "notes": []
    }
  ],
  "exits": [
    {"from": 22, "direction": "northeast", "to": 18, "geometry": "irregular"},
    {"from": 22, "direction": "north", "to": null, "geometry": "unknown"}
  ],
  "layout": {
    "anchorRoomId": 11,
    "coordinateSystem": "east+x,south+y,up+z"
  }
}
```

This is a **format example**, not real room/edge information. Never hardcode illustrative data into production output.

### Field semantics

- `schemaVersion`: integer `1` for this baseline. Treat changes as a versioned contract.
- `world`: initial value `3scapes`, from actual configured world if supported; no phantom multi-world support.
- `revision`: integer, strictly increasing across **actual published updates**, including plugin restarts. Avoid the common bug where a restart resets revision to `1` and QREEP ignores the new snapshot as old. Consider reading the last valid snapshot revision or persisting a small counter safely. Handle missing/corrupt old snapshots gracefully. For a *new world* decide/document reset semantics with the consumer.
- `publishedAt`: UTC ISO-8601 string (or precisely specified consumer-agreed format), generated at publication time; not a monotonic ordering primitive.
- `currentRoomId`: integer or JSON `null`; never emit empty string/`0` as fake unknown.
- `rooms`: array of **every relevant discovered room** (prefer complete world graph for v1; if limited for performance, agree scope with QREEP and document explicitly), unique by integer ID, with name, description, realm/area/level, optional spatial coordinates and all notes. Do **not** key by name; many forest rooms share the same name.
- `level` is an existing world/area-level attribute; `z` is **relative spatial layout height**. Do not equate unknown level with zero, nor assume absolute level equals the layout `z`.
- `positionStatus`: `inferred`, `fixed`, or `unplaced` as supported by the actual source. Only use `fixed` for genuinely user-verified/persisted positions; do not label computed graph coordinates as facts. Unplaced rooms must still appear in `rooms`, with `x/y/z` null or absent per final contract.
- `notes`: array of real notes (`id`, `text`, `createdAt`) for each room, ordered and serialized safely; preserve note IDs and text. SQLite's default `CURRENT_TIMESTAMP` is `YYYY-MM-DD HH:MM:SS` UTC; if emitting ISO strings, convert accurately without inventing timezone offsets.
- `exits`: every recorded directed exit including unknown destination (`to: null`), diagonals, vertical exits and named exits (`enter`, `out`, `tutorial`). Normalize abbreviations consistently with DB conventions. Never invent reverse exits.
- `geometry`: explicitly classify `regular`, `irregular`, `named`, `unknown`, or `unplaced` based on the graph and selected spatial layout. The actual edge remains authoritative even if the geometry is irregular. E.g. known `22 northeast → 18` must remain present and visible in the irregular-edge list/UI even if it disagrees with inferred positions.
- `layout.anchorRoomId` and coordinate system: stable within a connected spatial component according to the actual layout implementation; avoid current-room-relative reflow on every movement. If multiple disconnected components/portals exist, represent unplaced/different components faithfully and document v1 limitations. Do not invent coordinates for named exits.
- JSON strings must be correctly escaped for quotes, newlines, backslashes and Unicode; booleans/numbers/null must be true JSON types, not Lua-string approximations.

## Ownership and module design

Prefer a small production module such as `publisher.lua` or `map/publisher.lua` (choose based on actual conventions) that offers an interface like:

```lua
publisher:publish(current_room_id, reason)
```

The publisher should read committed state from SQLite through explicit Memory APIs, build a pure Lua snapshot model, compute/reuse the stable layout with the existing graph algorithm (without drawing ASCII), serialize JSON, and atomically publish. Keep it separate from `map/render.lua` and Blightmud output APIs. A `map/snapshot.lua` pure model builder may help if warranted, but don't over-abstract.

Avoid relying on `pairs()` ordering when producing arrays; sort rooms by ID, exits deterministically by `(from, direction, to)` and notes by ID to make fixtures/tests/review reproducible. Keep any geometry conflict diagnostics separate and nonfatal. The map can show true graph edges that do not align geometrically.

**No partial snapshots:** SQLite queries should see a consistent state. Consider a read transaction or other appropriate mechanism for consistent multi-table reads, without interfering with in-progress writes or Blightmud's existing connection. Do not publish within a half-completed write path; ensure publish happens after the entire observation/connection/geography change commits (or improve transaction boundaries narrowly and safely). SQLite must remain source of truth.

**Operational cost:** The plugin runs inside Blightmud, whose callbacks can be time-limited. Evaluate complexity of graph traversal and JSON serialization for larger worlds. Avoid unbounded synchronous work or large repetitive writes on each raw MUD line. If needed, add a bounded/coalesced publication strategy, but ensure the final current-room state is eventually written promptly and document scheduling/API assumptions.

## Atomic filesystem publication

1. Create the destination directory using a verified, safe mechanism. No command concatenation using untrusted input; no `os.execute("mkdir -p " .. user_string)`.
2. Generate the complete JSON string in memory and validate basic invariants before touching the live file.
3. Write a uniquely named temporary file **in the same directory** as `map.json` (restrictive permissions where supported). Write all bytes, flush and close, check errors.
4. Atomically rename the temporary file over `map.json` on the same filesystem. If rename fails, preserve the old valid file, report an actionable error, and remove temporary debris if safe. Confirm Lua/OS behavior under Linux; optional durability/fsync enhancements only when supported.
5. A reader must never observe half-written JSON. Verify with the actual QREEP file watcher, since some watchers follow the old file inode across atomic renames. If the watcher needs changes, coordinate through the documented contract rather than degrading to in-place writes.
6. Never embed DB credentials, personal details, terminal logs, secrets or unrelated files in the snapshot. Escape notes and descriptions safely.
7. Missing/unwritable state directory or JSON-encoding errors should **not** break Blightmud or corrupt the SQLite record. Report technical errors in debug/log output and/or a brief truthful whisper; avoid repeated spam every movement.

## Integration points and update ordering

Inspect actual call paths and wire only the necessary hooks. Candidate sites:

- `main.lua`: initialize the publisher **after** Memory init; publish initial snapshot; ensure plugin reload doesn't register duplicate callbacks/watchers and refreshes `package.loaded` appropriately. Close/cleanup cleanly. Do not publish a fictitious last room on startup.
- `triggers/room.lua`: after an observation is finished, room ID is unambiguous, `Memory:remember_room()` has succeeded and all intended exit connections, location inference, and notes-related state is consistent. **Even if room ID didn't change**, a newly discovered exit/description/location can require a snapshot. Avoid publishing before `connect_rooms()`/`infer_location()` if those write afterward.
- `aliases/notes.lua`: after successful add/delete and any other note mutation; not for simply listing notes.
- `aliases/location.lua`: after successfully setting realm/area/level. Respect manual values; do not reset them during publication.
- Other mutation sites discovered via a repository search: cover every supported mutation to the map snapshot; avoid missing calls hidden in other aliases or code paths.

Favor **one explicit mutation notification interface** (e.g. `qreeper:map_changed(reason)` or a tiny coordinator) rather than every alias independently opening/writing JSON. If moving a publisher reference through registration signatures, update every call site carefully; obey lifecycle cleanup rules. Publish failures should not change movement outcome or database transaction success.

### Rapid movement and camera behavior

The QREEP UI already owns marker highlighting and camera behavior: new confirmed room updates immediately; camera recenters after ~700 ms of inactivity, with early safety-margin follow. Lua **does not** animate or debounce the camera. A fast `s,s,s,w,s,e,e,e` should generate correct latest room state and map graph; watcher may coalesce intermediate file replacements, which is acceptable in v1. The consumer must converge on the newest revision; don't fabricate a replay log. Only add movement/event metadata if the Step 1 consumer explicitly finalized it as an optional contract.

## Tests / validation — implement and actually run what is feasible

Prepare small deterministic Lua tests or fixtures where feasible; use a disposable SQLite DB and temporary JSON output path, **not** the real 3Scapes world file.

1. Cold start: no current room; valid snapshot with `currentRoomId: null` and all known rooms.
2. After room #11 confirmed: snapshot has `currentRoomId: 11`; after moving to #12, it changes and revision increases; file remains parseable.
3. Same room observed with updated description/exit: correct new snapshot despite unchanged current ID.
4. Rapid movement sequence: final current room and graph correct, revision monotonic and no excessive callback stalls.
5. Failed `south`, `look`, or ambiguous fingerprint: no invented movement or edges, and no false new current room.
6. Named `enter/out` known destination: directed edge retained with `geometry: named` and no fake coordinate; unknown named exit preserved with null destination.
7. Contradictory `22 northeast → 18`: edge present and classified irregular (or accurately equivalent in final contract), not silently omitted.
8. Two rooms with same name: both IDs and their different exits/notes survive JSON serialization.
9. Notes: add/delete note reflected under correct room after successful mutation; characters with quotes, backslashes, non-ASCII and embedded newlines properly round-trip.
10. Realm/area/level edits and inferred area: update correct room and do not overwrite manual information merely by publishing.
11. Plugin reload/restart: revision stays increasing; no duplicate registration, stale publisher, or extra output spam.
12. Missing/unwritable directory and malformed prior snapshot: safe failure/recovery without losing SQLite data.
13. Atomic rename: parallel reader always gets full JSON (old or new); Step 1 QREEP detects successive replacements on actual runtime where testable.
14. Larger cyclic graph with vertical levels and collisions: bounded performance; all rooms retained (including unplaced), known edges not dropped.
15. Run project test/format/lint commands actually present. If GUI/Blightmud integration is not runnable in the agent environment, provide exact manual test instructions and explicitly mark it unverified.

## Manual end-to-end acceptance in the user's environment

With QREEP Step 1 running and Blightmud Qreeper loaded:

```text
l
qreeper:map
qreeper:note Thieves here
s
n
```

Check `~/.local/state/qreeper/map.json` with `jq`, confirming an increasing revision, valid IDs, directed exits and notes. Watch the bar/minimap: current marker changes after **confirmed** room arrival, map nodes/notes update, and the camera settles after rapid movements rather than centering on every step. The large Atlas should show the same state. Test with QREEP stopped: Qreeper remains playable and SQLite intact.

Example CLI checks:

```bash
jq '{schemaVersion, world, revision, currentRoomId, rooms: (.rooms|length), exits: (.exits|length)}' ~/.local/state/qreeper/map.json
jq '.rooms[] | select(.id == 22) | {id, name, notes, positionStatus}' ~/.local/state/qreeper/map.json
jq '.exits[] | select(.from == 22 and .direction == "northeast")' ~/.local/state/qreeper/map.json
```

## Documentation and final deliverables

- Implement the real Lua module(s), registration/hooks, read-only database query API(s) as required, safe publisher I/O, and tests.
- Add/update `docs/INTEGRATION-QREEP.md`: authoritative path; exact versioned schema and nullable fields; field semantics; publisher triggers; revision/restart handling; atomic-write strategy; coordinate/conflict semantics; limitations and troubleshooting; manual verification commands.
- Add a checked-in sample JSON fixture representing duplicate-name rooms, unknown/named exits, the irregular 22→18 connection, and notes. Do not write fixture into the production state location automatically.
- Update `docs/PROJECT-SCOPE.md` / relevant architecture docs to accurately distinguish newly implemented functionality from earlier plans.
- Ensure the Lua plugin still works even if QREEP is not running; don't add a dependency on QREEP, shell process state, or graphical UI.
- Final report should state precisely: files modified, integration hooks, schema used and whether it matches Step 1, test commands/results, observed performance, unverified manual behavior, known risks, and any QREEP-side follow-up genuinely necessary. **Do not claim end-to-end confirmation unless it was tested.**

## Out of scope

Do not redesign QREEP's bar/minimap/Atlas, reimplement QML graph layout, add sockets or an HTTP server, overhaul the MUD room resolver, rewrite the ASCII mapper, drop/recreate the real SQLite DB, or invent teleportation/portal geometry. Keep the task focused on a safe, accurate and timely JSON publication bridge.

**Definition of done:** Qreeper can publish a complete, versioned, atomically replaced `map.json` containing the actual world graph, notes, geography, layout uncertainty, and latest **confirmed** room; QREEP can consume successive updates without either project requiring the other to stay alive.
