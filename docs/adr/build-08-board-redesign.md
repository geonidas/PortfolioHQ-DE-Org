# ADR — Build 08: board redesign, in-card editing, live updates

Decisions taken during build 08, with the reasoning that would otherwise be lost. Narrative lives
in `docs/build-summaries/build-08.md`; org state and traps live in `docs/handoff.md`. The design
decisions themselves - palette, type, wireframes - are in `docs/build-08/design-plan.md`.

---

## 1. The public board names the vendor

**Context.** Build 08 puts a source label on every card - "Jira", "Asana" - with a colour accent
per source, and gives both boards a filter by source. The public board is read by anonymous
visitors.

**What this reverses.** Build 07, decision 6: "no vendor name reaches an anonymous visitor at all,
which is strictly better than sending one." The public card carried `condensesIntoEpic`, a boolean,
precisely so the client could act on the source without learning which it was.

**Decision.** Publish the label. `PublicCard` and `PublicEpic` carry `sourceLabel` and
`accentToken`, answered by `BoardSourceRules` from `Board_Source__mdt`. The half of build 07's rule
that mattered is kept, and is now enforced rather than merely followed: **the client never branches
on a vendor.** It renders the label and paints the token; it never compares either.
`lwc/__tests__/vendorNeutrality.test.js` fails on any vendor name in LWC source outside a comment.

**Why the reversal is sound.**

- **The portfolio's point is the integrations.** A public board that hides which systems it
  integrates hides the thing it exists to show.
- **Nothing is disclosed that was secret.** The label is display text chosen in custom metadata, not
  a system identifier. The public page already showed Jira-shaped keys (`DOPP-16`).
- **The capability behind the old rule stays intact.** Adding a source is still a metadata record
  and an adapter; no component learns its name. The label and token are data, like the title.

**Enforcement, so this stays a deliberate act.**

- `PublicBoardControllerTest` asserts both DTO key sets exactly, and failed first on this step,
  naming `sourceLabel` and `accentToken` (and the three date fields beside them).
- `GuestAccessTest` now asserts the guest permission set's readable fields exactly - it previously
  only forbade four - and failed first, naming the three new field grants.
- Neither test was updated until it had failed on the change.

**Consequences.** The accent colour is a token name on the wire (`accent-1`), mapped to a colour by
the shared stylesheet; an unknown token renders neutral. Changing what a source is called or how it
looks is a metadata or stylesheet change. `condensesIntoEpic` stays a boolean: it is a behaviour, and
behaviours stay answered rather than inferred.

**Revisit when** a source is added whose name should not appear publicly - its `Board_Source__mdt`
label can say something generic without any code change.
