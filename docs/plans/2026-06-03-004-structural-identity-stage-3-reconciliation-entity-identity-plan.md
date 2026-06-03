# Structural Identity — Stage 3: Structural Reconciliation & Entity Identity

**Date:** 2026-06-03
**Status:** Plan. Not started. Depends on Stage 2.
**Stage:** 3 of the structural-identity migration. This is the second half of
001's **Option B** — make the reconciliation key
`(structural slot + type + entity identity)` instead of an overloaded
final-identity string, and introduce `EntityIdentity` as a first-class axis.
**Entry point:**
[`2026-06-03-001-first-class-structural-identity-proposal.md`](2026-06-03-001-first-class-structural-identity-proposal.md).
**Predecessor:**
[Stage 2 — Resolve-Time Structural Identity](2026-06-03-003-structural-identity-stage-2-resolve-time-structural-identity-plan.md).
**Verified against:** `swift-tui` working tree at commit `a020fa55`.

---

## Executive summary

Today, SwiftTUI reconciles children by diffing `[ChildDescriptor]` with
`CollectionDifference.inferringMoves()` (`StructuralDiff.swift:19-23`), where each
descriptor's equality fuses `identity + explicitID + typeIdentity +
typeDiscriminator` (`ChildDescriptor.swift:41-52`) and `explicitID` is *re-parsed
out of the identity string* by matching `ID[` (`:67-77`). There is **no
entity→lifetime routing table** — recon confirmed zero `LSID`/`EntityID`/lifetime
matches across the codebase. `Identity` equality through `inferringMoves()` *is*
the routing.

That has two consequences this stage fixes:

1. **The reconciliation key is a string projection, not a model.** "Same node"
   is decided by string equality that conflates structural position, entity id,
   and runtime identity. Stage 2 gave us a real structural slot; Stage 3 gives us
   a real entity id; together they let reconciliation match on what it actually
   means — `(structural slot, type, entity)` — instead of on a fused string.

2. **Duplicate ids are undefined-but-silent.** Duplicate runtime identities are
   *confirmed reachable* (`ForEach.swift:26-28` derives identity from
   `explicitID(element[keyPath: id])` with no occurrence ordinal;
   `GeometryTypes.swift:625-627` stringifies with no disambiguator). `StructuralDiffTests`
   does not cover the duplicate case, so `inferringMoves()` over two identical
   descriptors produces an *undefined-but-deterministic* pairing — and worse,
   the duplicate identity then aliases **every** identity-keyed map (`@State`,
   handlers, animation, retained index), not just the diff. Stage 3 makes the
   reconciler's response to duplicates deterministic and diagnosed.

Stage 3 does **not** yet make runtime lifetime survive a transformation that
*changes* the runtime identity (a view moving between containers, an id added or
removed). That is Stage 6's persistent routing table. Stage 3 builds the
**per-frame** matching on an explicit entity axis; Stage 6 makes it persistent.

## Current state

Verified at `a020fa55`:

- `diffChildren(old:new:)` = `new.difference(from: old).inferringMoves()` over
  `[ChildDescriptor]` (`StructuralDiff.swift:19-23`).
- `ChildDescriptor` equality/hash fuses `identity + explicitID + typeIdentity +
  typeDiscriminator` (`ChildDescriptor.swift:41-65`); `explicitID` is parsed from
  the identity's last component by `ID[` prefix matching (`:67-77`).
- Reconciliation extracts only `.removed` ops for eager teardown
  (`ViewGraphStructuralReconciliation.swift:21-49`; applied at
  `ViewGraph.swift:1142-1152` before the child-list swap at `:537-547`).
  Matched/moved/inserted are intentionally not torn down here.
- `ForEach` already diverges `structuralIdentity := elementContext.identity`
  while keeping `viewIdentity` at the outer scope (`ForEach.swift:36-44`), so the
  element identity is simultaneously: the structural id `.panel()` reads
  (`Panel.swift:101`), the `@State` graph base (via `stateStorageIdentity`
  prefixing), and the reconciliation key (`ChildDescriptor`). **A naive split
  risks decoupling these three** in ways that break `.panel()` id stability or
  `@State` ownership — Stage 3 must keep them coherent.
- Static unkeyed child slots are ordinal: `indexedChild(kind:index:)` produces
  `kind[index]` (`ResolveContext.swift:171-177`), so inserting before a sibling
  changes that sibling's slot — the SwiftUI-like structural behavior.

## Design: the entity axis

Introduce `EntityIdentity` — the explicit, user-or-data-supplied identity that
should route lifetime — as a typed attribute distinct from both the structural
path (Stage 2) and the runtime identity string:

```swift
package struct EntityIdentity: Hashable, Sendable {
  package let value: AnyID                 // the user's .id value / ForEach element id (cf. AnyID, ActionScope.swift:33)
  package let occurrence: Int             // disambiguator within a collision scope; 0 if unique
}
```

Two design commitments that make this stage land cleanly:

1. **`EntityIdentity` is carried, not parsed.** Stage 2 stopped `ChildDescriptor`
   from string-parsing the structural component; Stage 3 stops it from
   string-parsing the entity component. `.id`/`ForEach` attach a typed
   `EntityIdentity` to the resolved node; the reconciler reads the attribute.

2. **The `occurrence` disambiguator lives on the entity axis ONLY — never on the
   runtime `Identity` string.** This is the needle recon flagged: adding an
   occurrence ordinal to `explicitID` would change every `Identity.path`,
   invalidating every Codable fixture and breaking `ChildDescriptor`'s `ID[`
   re-parse (`ChildDescriptor.swift:67-77`). So the collision-resistant key the
   migration needs is minted on `EntityIdentity.occurrence` for *reconciliation
   and lifetime routing*, while the runtime `Identity` keeps its current,
   collision-prone string form for compatibility. The string can lie about
   uniqueness; the entity axis cannot.

## The new reconciliation key

```text
two children are "the same node" iff:
  same structural slot         (Stage 2 structuralPath, positional)
  AND compatible type          (typeIdentity + typeDiscriminator, as today)
  AND same entity identity      (EntityIdentity, when present)
```

`ChildDescriptor` is rebuilt around this triple. `diffChildren` still uses
`CollectionDifference.inferringMoves()`, but now over descriptors whose equality
is the explicit triple rather than a fused string. The behavioral contracts this
makes precise:

- **`ForEach` reorder preserves lifetime.** Elements match by `EntityIdentity`,
  so a reorder with stable ids yields moves, not remove+insert — the same
  observable outcome as today (`StructuralDiffTests.swift:7-43`), but now by
  model rather than by string coincidence.
- **Static insertion shifts unkeyed siblings.** An unkeyed child has no
  `EntityIdentity`; its identity is its ordinal structural slot. Inserting before
  it changes that slot, so it reconciles as a different node — the expected
  SwiftUI structural behavior, now stated as a contract and tested.
- **Keyed insertion preserves keyed siblings.** A `.id`-keyed sibling matches by
  entity identity across an insertion even though its ordinal shifted — the
  inverse case, also tested.

## Duplicate-identity policy (existence resolved by Stage 0; policy decided here)

Stage 0 produces the measured fact this policy rests on: duplicate runtime
identities trace exclusively to user-supplied ids (`ForEach` / `.id`), never to
framework composition. That makes them **user error**, which the structural layer
must *contain*, not lavishly model — SwiftUI itself treats duplicate `ForEach`
ids as undefined and warns.

Stage 3's deterministic response, in order of preference:

1. **Disambiguate on the entity axis.** Within a sibling collision scope, assign
   `EntityIdentity.occurrence = 0, 1, 2, …` in resolved order. Reconciliation and
   lifetime routing become deterministic (occurrence-stable across frames as long
   as the collision order is stable), with **no change to the runtime `Identity`
   string**. This is the default.
2. **Emit a non-fatal diagnostic** (release) naming the colliding id, the view
   kind, and the structural slot — so the user can find and fix the bad id.
3. **Optional hard precondition** in debug/test configurations, gated behind a
   build flag, to catch the mistake at its source during development.
4. **Conservative fallback** for any scope where occurrence assignment cannot be
   made stable (e.g. the collision count itself changes frame-to-frame): rebuild
   the affected sibling subtree rather than risk a wrong lifetime match.

Note this *also* resolves the latent aliasing in every other identity-keyed map:
once `EntityIdentity.occurrence` disambiguates colliding elements, Stage 5/6 can
allocate distinct `ViewNodeID`s for them, so duplicate ids stop aliasing `@State`,
handlers, and animation — the collision is contained at the entity axis and never
propagates to runtime lifetime.

## Mechanics

### L3.1 — `EntityIdentity` type + carrier
Define `EntityIdentity` and add an optional `entityIdentity: EntityIdentity?`
attribute to `ResolvedNode` (most nodes have none). Populate it at the two entity
sites: `.id(_:)` (`ViewMetadataModifiers.swift:187-212`) and `ForEach`/
`IndexedChildSources` element resolution (`ForEach.swift:26-44`,
`IndexedChildSources.swift:54-91`). The runtime `Identity` still gains its
`ID[...]` suffix as today (compatibility); the entity attribute is the *typed*
truth.

### L3.2 — Occurrence assignment
Assign `occurrence` within each sibling collision scope during resolve, in
resolved order. Single-occurrence ids get `occurrence: 0` and behave exactly as
today. This is the only new resolve-time computation and it is O(siblings) within
a `ForEach`/container, folded into the existing element loop.

### L3.3 — Rebuild `ChildDescriptor` + `diffChildren`
Re-key `ChildDescriptor` equality/hash on `(structuralPath-slot, typeIdentity,
typeDiscriminator, entityIdentity?)`. Delete the `ID[` string re-parse
(`:67-77`) — its job moves to the typed `entityIdentity`. `diffChildren` is
otherwise unchanged (still `inferringMoves()`), but now deterministic under
duplicates because descriptors carry distinct occurrences.

### L3.4 — Formalize reconciliation outcomes
Today only `.removed` is acted on at reconciliation
(`ViewGraphStructuralReconciliation.swift:21-49`). Stage 3 documents and tests
the full outcome set — matched (lifetime preserved), moved (lifetime preserved,
edge order changed), inserted (new lifetime), removed (eager teardown) — as the
contract Stage 6 will make persistent. No teardown-timing change this stage; the
goal is a *specified* reconciliation, not a re-timed one.

### L3.5 — Keep the three roles coherent for `ForEach`
The element identity currently triple-duties as structural id (`.panel()`),
`@State` base (`stateStorageIdentity`), and diff key. Stage 3's split must:
- keep `.panel()` reading a *stable, distinct-per-element* structural id (Stage 2
  `structuralPath` for the element slot, which `PanelTests` asserts is stable and
  distinct);
- keep `@State` ownership on the outer `viewIdentity` (unchanged — `@State` in a
  `ForEach` row stays owned by the closure owner, per `State.swift:248-256`);
- route lifetime on `EntityIdentity`.
These three now read three different axes instead of one overloaded string — the
decoupling recon warned about, done deliberately and tested rather than by
accident.

## Tests

1. **Reorder preserves lifetime by entity, not by string.** `ForEach` reorder
   with stable ids → moves only; assert via the explicit entity match, and assert
   `@State` per row survives the reorder (precursor evidence for Stage 6).
2. **Duplicate ids are deterministic + diagnosed.** Two `ForEach` elements with
   equal ids reconcile to two distinct nodes (occurrence 0/1), emit the
   diagnostic, and do **not** alias each other's descriptor. This is the test
   `StructuralDiffTests` is missing today.
3. **Static unkeyed insertion shifts siblings; keyed insertion preserves them.**
   The two halves of the insertion contract, each asserted.
4. **`.panel()` / `@State` / diff read different axes.** A `ForEach` row's panel
   id (structural), state ownership (owner viewIdentity), and reconciliation key
   (entity) are independently correct and independently stable.
5. **No fixture churn.** Runtime `Identity` strings and `ID[...]` suffixes are
   byte-unchanged (the occurrence disambiguator never touches them) — assert the
   Codable identity fixtures and `SwiftUISurfaceTests` path strings are stable
   across Stage 3.

Suites: `StructuralDiffTests` (extend with duplicates + insertion contracts),
`ChildDescriptorTests` (re-key), `RegistrationAliasDiagnosticsTests`,
`RegistrationAliasFindingsTests` (alias-record timing unchanged), `PanelTests`,
`ForEach`/collection suites.

## Execution order and touchpoints

| Step | Lands | Primary files |
| --- | --- | --- |
| L3.1 | `EntityIdentity` + `ResolvedNode.entityIdentity` carrier | `Geometry/GeometryTypes.swift` (or new `EntityIdentity.swift`), `Resolve/ResolvedNode.swift`, `Modifiers/ViewMetadataModifiers.swift:187`, `Collections/ForEach.swift:26`, `Collections/IndexedChildSources.swift:54` |
| L3.2 | occurrence assignment in resolve | `Collections/ForEach.swift`, `Collections/IndexedChildSources.swift` |
| L3.3 | re-keyed `ChildDescriptor` + `diffChildren` | `Resolve/ChildDescriptor.swift:26-77`, `Resolve/StructuralDiff.swift:19-71` |
| L3.4 | formalized reconciliation outcomes | `Resolve/ViewGraphStructuralReconciliation.swift:21-49` |
| L3.5 | three-axis coherence for ForEach | `Collections/ForEach.swift:36-44`, `ActionScopes/Panel.swift:101`, `State/State.swift:248-256` |

## Validation

```bash
swift test --package-path swift-tui --filter StructuralDiffTests
swift test --package-path swift-tui --filter ChildDescriptorTests
swift test --package-path swift-tui --filter RegistrationAliasFindingsTests
swift test --package-path swift-tui --filter PanelTests
swift test --package-path swift-tui --filter SwiftUISurfaceTests
bazel test //:org_fast
```

No direct perf claim. The reconciliation refactor must not regress
`resolve_ms` (rows=6/20/40 sweep), and the duplicate-id determinism must not
introduce per-frame occurrence-recompute cost beyond O(siblings).

## Risks and non-goals

- **Do not** make lifetime survive identity-*changing* transformations in this
  stage. Per-frame matching only; the persistent routing table is Stage 6.
- **Do not** put the occurrence disambiguator on the runtime `Identity` string.
  It lives on `EntityIdentity` exclusively. Changing the string churns fixtures
  and breaks the `ID[` re-parse and every `.path`-embedded key
  (presentation item ids, surface stableKeys).
- **Do not** move `@State` ownership off the outer `viewIdentity` for `ForEach`
  rows. Recon is explicit: a naive entity split here breaks `@State` ownership.
- **Do not** change reconciliation *timing* (eager-removal-only) — only its
  *specification*. Re-timing teardown is out of scope.

## Open questions

1. Is `occurrence` stable enough in practice when the collision *count* changes
   frame-to-frame? Stage 0 measures collision-scope volatility; if scopes are
   stable (the expected case for a static bad-id bug), occurrence is stable. If a
   scope's membership churns, fall back conservatively (L3.4 policy 4).
2. Should the debug hard-precondition (policy 3) be default-on in test
   configurations? Leaning on for the framework's own test suite (catch our bugs)
   and off for user debug builds (a non-fatal diagnostic is friendlier).
3. Does `inferringMoves()` remain the right engine once entity routing is
   persistent (Stage 6), or does the routing table subsume it? Revisit at Stage 6.
