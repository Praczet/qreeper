# Agent task — inspect Qreeper and establish its project scope

You are working **inside the Qreeper repository**. Read `AGENTS.md` first and follow it for this task.

## Goal

Inspect the **actual current codebase**, not chat history or imagined architecture, and create accurate, maintainable project documentation under `docs/`. The central deliverable is `docs/PROJECT-SCOPE.md`: a clear description of what Qreeper **is**, what it **currently does**, what it **must guarantee**, what it **does not yet do**, and how it will integrate with QREEP/Quickshell.

This is primarily a **research and documentation task**. Do **not** implement features, refactor modules, change behavior, modify SQLite databases, or install dependencies unless separately authorized. If a critical bug or uncertainty is discovered, document it and recommend a separate follow-up task.

## Repository investigation (mandatory)

1. Read `AGENTS.md`, then list the repository structure. Identify entry points, project docs, tests, examples, scripts, and any generated files.
2. Read the actual `main.lua` startup path, module loader, reload and cleanup behavior, and lifecycle ownership of triggers and aliases.
3. Inspect room parsing and observation (header, compass, description completion), movement tracking and failure handling, room matching, fingerprints, geography inference, whispers, notes, and all `qreeper:*` commands. Follow real call sites; do not infer functionality from names.
4. Inspect SQLite schema, schema initialization, migrations/scripts, statement usage, conflict behavior, notes and exit relationships, and any snapshots or export code.
5. Inspect `map/` modules, including graph traversal, anchor selection, conflict/unplaced handling, renderer, legend, and current-room behavior. Identify whether map layout is derived or persisted.
6. Inspect anything interfacing with external systems (3Scapes, Blightmud API, filesystem, Quickshell/QREEP). Determine whether JSON snapshots, IPC, watches, or QREEP support actually exist. Record their exact paths if implemented.
7. Look for tests, fixture output, config/example paths, and environment setup. **Run only safe, non-destructive checks**. If no automated tests exist, say so.
8. Use `git status` to understand uncommitted work. Do not reset, overwrite, or include unrelated changes. Avoid writing to live databases during documentation work.

For every public command and supported workflow, verify the source file that registers or implements it. A README claim, previous AI suggestion, or sample JSON is not sufficient evidence on its own.

## Required deliverables

### A. `docs/PROJECT-SCOPE.md` (primary)

Write a concise but substantive document with the following sections:

1. **Identity and mission** — Qreeper's role as an exploratory companion for Blightmud and initially 3Scapes; what belongs in its scope vs the client, the MUD server, and QREEP.
2. **Current status (as inspected)** — what is implemented, partially implemented, and absent. Give concrete file references and avoid optimistic claims.
3. **User experience and commands** — an accurate table of registered aliases and their effects, including any diagnostics/test commands. Clarify whisper vs scrollback output.
4. **Runtime and environment** — Lua/Blightmud dependencies, SQLite location/configuration, plugin load/reload, runtime caveats, startup and reproducible verification steps. State when environment facts are not represented in the repository.
5. **Architecture and data flow** — actual modules and a readable flow from player command → game response → observation → room identity → persistent data → map/UI, with uncertainty and errors explicitly marked. Use text or Mermaid if useful.
6. **Persistent data model** — existing tables/fields/relationships, IDs, fingerprints, directed exits, unknown destinations, notes, geography, and migrations. Explain what each field means *where evidenced*, otherwise mark unresolved.
7. **World-model invariants** — movement intent vs confirmed arrival, ambiguous matching, one-way connections, named exits and portals, graph truth vs geometric layout, manual labels vs inferred ones, no destructive remapping.
8. **Map behavior** — spatial layout algorithms as actually implemented, deterministic or unstable aspects, conflicts, levels, current-room highlighting, unknown exits, legend and notes. Separate terminal-map behavior from future QREEP graphical map.
9. **QREEP integration boundary** — planned product experience: QREEP bar icon (left click movable minimap, right click atlas); live current-room updates; immediate highlight; idle-debounced camera recentering; novel/unplaceable room handling. Explicitly state this is **planned unless code proves otherwise**. Describe the proposed producer/consumer division and versioned snapshot contract, but don't invent a finalized schema/path. If an existing contract exists, document it exactly.
10. **Risks and known limitations** — only evidence-supported problems, with source references and reproducible cases where possible. Distinguish observed defects from architectural risks.
11. **Roadmap and non-goals** — short phased plan (reliable world observation, robust graph identity, stable visual representation, QREEP publisher/consumer bridge, navigation), each labeled *proposed*, not implemented. Non-goals include replacing Blightmud, claiming exact geometry without evidence, or silently editing world records.
12. **Decision log / open questions** — decisions already reflected in code vs proposed choices needing developer approval.

Use the terminology and naming that actually appear in source. Link directly to relevant repository-relative source paths. Keep the doc readable as a starting point for future coding agents.

### B. `docs/ARCHITECTURE.md` (only if valuable)

Create only if the architectural details would make `PROJECT-SCOPE.md` unwieldy. Explain module responsibilities, startup/lifecycle, mutable state, data ownership, error boundaries, and cross-project data flow. Keep `PROJECT-SCOPE.md` as the canonical scope overview and cross-link the documents; avoid duplicated paragraphs.

### C. `docs/DATA-MODEL.md` (only if valuable)

Create only if a focused record of schema, relationships, invariants, direction normalization, migrations, and room-identity limitations would materially help. Derive exact columns/constraints from actual SQL and code; include a warning that descriptions, name/exits fingerprints, and inferred coordinates may be imperfect identifiers.

### D. `docs/INTEGRATION-QREEP.md` (only if valuable)

Describe the intended Lua → QREEP interface and its state. Mark all unimplemented fields/contracts as **proposal**, including JSON structure, snapshot path, update trigger, atomic publication, versioning, and failure/restart behavior. Define what must be verified with the QREEP agent's Step 1 implementation before finalizing Step 2. If integration already exists, describe it instead of designing a replacement.

Do not create extra files just to fill out a template. If one well-structured PROJECT-SCOPE is sufficient, make only that file.

## Accuracy rules

- Tag substantive statements as **Implemented**, **Partial**, **Planned**, **Unknown**, or **Decision needed** when ambiguity matters.
- Never claim a public API is usable merely because a function name exists: verify registration and end-to-end path.
- Never claim map connections are reliable just because SQLite contains them; inspect matching and failed-move handling.
- Do not derive absolute world geography from relative map coordinates.
- Treat an earlier assistant-generated implementation plan as a proposal, not an authoritative account of code.
- Explicitly document uncertainty around identical-looking rooms, changing descriptions/exits, named exits, and spatially contradictory graph edges.
- Do not include fabricated console logs, test results, or exact file paths absent from the repository.
- Keep development instructions consistent with installed versions and existing project tooling; do not assume an automated test suite or CI exists.

## Validation and completion

After writing docs:

1. Recheck every listed command against its actual alias registration.
2. Recheck every schema field and file link against the repository.
3. Search docs for unsupported phrases such as “already supports,” “automatically,” and “always”; substantiate or qualify them.
4. Verify no code or user database was changed. Run `git diff --check` on the documentation changes where available.
5. Report: exact files created/changed, notable verified findings, important ambiguities, missing tests, and decisions needing developer input.

**Stop and ask** if a crucial repository area is unavailable or if accurately documenting scope would require inspecting a different private repository not accessible to you. For QREEP behavior, reference only available QREEP source or explicitly call it a planned external dependency.

## Hand-off objective

The resulting `docs/PROJECT-SCOPE.md` should allow a new developer or coding agent to understand the project's real state before touching code, and should make the eventual **Step 2: Qreeper JSON publisher for the QREEP minimap/atlas** straightforward to specify without guessing.
