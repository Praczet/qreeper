# AGENTS.md — Qreeper

## Purpose

Qreeper is a Blightmud Lua companion for exploring text MUDs, initially 3Scapes. It observes play, remembers places and journeys, and offers a witty, unobtrusive companion voice. It should help a player explore and create useful maps without replacing the MUD client or pretending uncertain observations are facts.

This file governs **how coding agents work** in this repository. The actual implemented architecture, public commands, data model, and roadmap must be documented separately under `docs/` after inspecting the code. **Do not treat a plan or an earlier assistant suggestion as implemented functionality.**

## Working style

- Communicate with the developer **in English**. Be direct, collaborative, and technically precise; explain significant trade-offs without padding.
- Prefer **small, comprehensible, incremental changes** to speculative rewrites. The developer wants to understand the system as it grows.
- Before implementing, inspect the relevant code, current documentation, and call sites. Follow existing naming, module organization, and style unless there is a concrete reason to change them.
- State assumptions and uncertainties plainly. Ask before making an irreversible or high-impact design choice.
- Keep the task scoped. Do not quietly add unrelated features or refactor half the project.
- A proposed change is not complete until it is checked with the available tests, examples, or a reproducible manual validation plan.
- When asked for a full file, provide a **complete usable file**, not a fragment presented as a replacement. For agent edits, modify the actual files and summarize what changed.
- Avoid repetitive confirmations. Move forward when the instructions and code support a safe interpretation.

## Required orientation for each task

1. Read this `AGENTS.md`.
2. Read relevant documentation under `docs/` if it exists; verify critical statements against code.
3. Inspect affected source files and registration/call paths **before editing**.
4. Describe the smallest viable implementation and any compatibility or persistence risks.
5. Implement, validate, and report concrete results and remaining limitations.

When documentation conflicts with executable behavior, **the code is the current source of truth**; fix or flag the documentation. Never invent files, commands, API methods, tests, or tool output.

## Design boundaries

Keep responsibilities distinct where the code permits:

- **MUD observation:** identify room headers, descriptions, exit summaries, and failed movements using actual incoming MUD output.
- **Movement tracking:** distinguish player intent from confirmed arrivals. Typing a direction is *not* evidence that travel succeeded.
- **Room identity:** names and exit lists are *evidence*, not globally unique IDs. Multiple rooms may share names, exits, and similar descriptions. Resolve ambiguity conservatively.
- **Persistence:** SQLite is the durable world record. Use prepared statements, explicit constraints, and safe lifecycle management.
- **Graph:** preserve **directed** exits, named exits, portals, unknown destinations, and irregular geometry. Never invent a reverse connection.
- **Geography:** realm, area, level, and coordinates have different meanings. Manually assigned facts must not be silently overwritten by inference; explicitly label guesses as such.
- **Presentation:** Qreeper's whispers are flavor, not a place to dump debugging logs. Provide longer reports in suitable scrollback/UI surfaces.
- **Visualization:** an approximate geometric layout is a *view* of the graph, not proof of physical geography. The graph remains authoritative.
- **External UI:** QREEP/Quickshell is a separate consumer. Keep the Lua plugin useful without QREEP running and use a documented versioned interchange contract.

Prefer the current module boundaries over a giant all-purpose module. Introduce new abstractions only when they remove real coupling or duplication.

## Qreeper's voice

User-visible in-world messages normally use **“Qreeper whispers:”** through the project's whisper mechanism. Voice: witty, dry, lightly sarcastic, fantasy-companion-like, intelligent, sometimes self-deprecating. Never obscure whether an operation succeeded; don't mock or scold the player. Keep messages short enough for the status display.

Use normal output or structured logs for diagnostics, SQL errors, migrations, and long lists. Debug messages must not remain in gameplay output after debugging unless explicitly enabled by a debug setting.

## Lua / Blightmud discipline

- Confirm Blightmud APIs and callback contracts from installed documentation or existing verified usage; don't guess trigger/alias syntax.
- **Lua patterns are not regular expressions.** `string.match()` uses Lua pattern syntax, while Blightmud trigger and alias patterns may use regex syntax. State which is used.
- Know Lua's multiple-return behavior (e.g. `gsub()` inside `table.insert()`). Protect single-value contexts where necessary.
- Track lifecycle-owned aliases/triggers and unregister old registrations on reload. Avoid adding or removing aliases from inside an alias iteration if it risks invalidating traversal.
- Ensure reloading also refreshes the project's owned `package.loaded` modules without clearing unrelated third-party modules.
- Avoid potentially unbounded callbacks, loops, expensive synchronous map algorithms, or large filesystem operations in Blightmud's event callbacks.
- Preserve custom/named movement commands such as `enter`, `out`, and `tutorial`, but only confirm their destinations on reliable arrival evidence.
- Treat the native `lsqlite3`/Lua runtime launch configuration as environment-dependent. Do not claim an LD_PRELOAD workaround is universally safe.

## Data integrity and migrations

- **Never delete or reset the user's discovered world as a debugging shortcut.** Preserve room IDs, notes, descriptions, exits, metadata, and history.
- For schema/data migrations: back up first, check for conflicts, run changes transactionally where possible, make behavior rerunnable or fail safely, and provide verification/rollback steps.
- Normalize direction names consistently between parsed exits, movement tracking, fingerprints, and SQL records.
- Do not merge potentially distinct rooms solely because a fingerprint matches. Do not force a connection when either endpoint is ambiguous.
- Record uncertainty and spatial conflicts rather than quietly coercing the map to fit a grid.
- Use SQLite foreign keys where required and handle failed writes visibly but without corrupting tracker state.
- Write generated snapshots atomically if external clients watch them. Keep published data consistent with committed storage.

## Tests and verification

Choose the smallest applicable test set, and record what was actually run. At minimum, where relevant, cover:

- Room output with ordinary and vertical compass decorations, blank/omitted lines, and varying descriptions.
- Repeat visits; same room name/exits in genuinely different locations; ambiguous observations.
- Successful movement, failed movement, `look`, multiple rapid commands, and named exits.
- One-way passages, unknown destinations, portals, diagonal/vertical movement, and spatial contradictions.
- Notes, manual geography updates, restart persistence, and reload without duplicate registrations.
- SQLite migration and snapshot compatibility with existing world files.
- Large/cyclic graph layout that terminates promptly; map updates during rapid movement.

Prefer deterministic fixtures or pure Lua tests for parsing/layout. If Blightmud or 3Scapes is needed, clearly mark steps as **manual/unverified** rather than claiming tests passed.

## Changes, commits, and reports

- Respect the repository's actual test/format/lint commands; discover them instead of assuming they exist.
- Preserve the project's formatting conventions (tabs if the surrounding Lua source uses tabs).
- Update relevant docs and example payloads when observable behavior or public commands change.
- Don't introduce dependencies, modify global environment configuration, alter SQLite schema, or rewrite migration history without explaining the reason and compatibility impact.
- Don't create commits, push, or rewrite history unless the developer's task or repository-specific rules request it. If a commit is requested, use a concise, meaningful message and inspect the diff first.
- Final report: **what changed, why, files touched, validation performed, known caveats, and next sensible step**. Distinguish completed work from suggestions.

## Cross-project agreement: Qreeper ↔ QREEP

The agreed product direction is a QREEP bar integration: **left click toggles a movable overlay minimap**, **right click opens a larger atlas**. The current location highlights promptly after a **confirmed** room observation; during rapid travel the viewport should not constantly recenter, instead following after a short idle delay (initial target around 700 ms, configurable). Newly discovered or unplaceable rooms must remain visible without falsifying geometry.

These are **design requirements**, not proof that either repository has implemented them. Confirm the actual contract in code/docs before integrating. Prefer a versioned, atomic JSON snapshot consumed by QREEP without requiring it to access Qreeper's SQLite file directly. The exact path, schema, error behavior, and update mechanism belong in the project documentation and must be reconciled with the consumer implementation.

## Documentation conventions

Maintain human-readable Markdown under `docs/`. Keep separate:

- **Current implementation:** observed from source and tests.
- **Architecture and invariants:** why components are separated and what they guarantee.
- **Known limitations:** reproduced or evidence-supported issues.
- **Planned work:** ideas and agreed goals that are not yet implemented.

Avoid enormous duplicative docs. Use links to code paths, concise examples, and explicit version/status labels. Never let generated documentation masquerade as a validated implementation report.
