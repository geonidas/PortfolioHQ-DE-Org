# ADR — Build 07: a second source system

Decisions taken while adding Asana, with the reasoning that would otherwise be lost. Narrative
lives in `docs/build-summaries/build-07.md`; org state and traps live in `docs/handoff.md`.

---

## 1. A webhook secret cannot live in a custom object field

**Context.** Asana hands its signing secret over once, during the registration handshake, to the
endpoint — which on a Salesforce site runs as the guest user. Verification must happen
synchronously in that same user's transaction, because a bad signature has to answer 401 and
stage nothing.

**Considered.** Encrypted Text on a Private object with field-level security granted to the
integration owner only. This is what the build brief specified, and it was built first.

**Measured, not assumed.** Encrypted Text deploys, but Apex returns it **masked** unless the
running user holds the `ViewEncryptedData` user permission — which system mode does _not_ bypass
the way it bypasses field-level security, proved by an A/B with that security held constant. A
guest permission set silently cannot hold that permission. Granting object access, then field
access, then view-all each moved the error along rather than fixing it. The wall: **a site guest
cannot read any custom object row, including one it just wrote itself, even through a
`without sharing` class.**

**Decision.** Split the two directions.

- `Webhook_Secret__c` is a **write-only staging row**. Writing is the one thing the guest can do,
  and being unable to read it back is enforced by the platform rather than by our configuration.
- Verification reads **protected Custom Metadata**, which Apex reads with no object grant, no
  field-level security and no sharing rule, from any user. Proven in this org since build 02.
- `scripts/apex/promote-webhook-secret.apex` carries the value across, run by a real user.

**Consequences.** One manual step per webhook registration, and a window in which deliveries are
rejected and retried. In exchange there is no mode in which a guest reads a secret — a stronger
guarantee than the field-level security this started as. Insert-only also makes first-write-wins
the rule, so an unauthenticated caller cannot replace a live secret with one of their own.

**Revisit when** the webhook moves behind a gateway.
`AsanaWebhookResource.signatureVerifiedUpstream` is the seam, and the case for that build is now
evidence rather than preference: Salesforce has no secret store that Apex can read and a person
cannot, and Shield would not change it.

---

## 2. `parseInbound` takes a batch

**Context.** Asana's webhook payloads name a resource gid and an action and carry nothing else.
Applying one means fetching the task. Jira's payloads carry everything and need no fetch.

**Considered.** A seventh interface method for hydration; a per-event `parseInbound` that fetches
one task each time.

**Decision.** Change the granularity instead: `List<Webhook_Event__c>` in,
`List<InboundChange>` out, correlated by `sourceEventId`.

**Consequences.** The adapter deduplicates the gids a delivery refers to and fetches ten per
request, so fifty tasks cost five callouts. A returned list shorter than the input is legal and
means "leave those deliveries staged", which is also how the callout budget is respected. The
processor learned nothing: it hands over rows and gets back vendor-neutral changes.

**The cost.** A rule that fails silently when broken: no DML may happen before `parseInbound`,
because Apex refuses a callout after uncommitted work — and it refuses it for Asana only, with an
error that never mentions Asana. Written onto the interface, into `CLAUDE.md` and into the
handoff, because the ordering happened to be safe and nothing enforced it.

---

## 3. The completion flag beats the section, in both directions

**Context.** Asana models a board column and a completion checkbox as independent things. The
checkbox is the easiest way in the UI to finish a task, and it moves nothing.

**Decision.** Inbound, `completed: true` means Done whatever the section says. Outbound, a status
change writes **both** the section move and the flag.

**Consequences.** Ticking the box in Asana no longer leaves the Salesforce board showing In
Progress. Writing only one half outbound would author exactly the contradiction the inbound rule
exists to absorb: only the move leaves a task in Completed that Asana thinks is unfinished; only
the flag leaves a struck-through task in the In Progress column. The move goes first, so a
failure of the second write still leaves the board looking right and the result names the half
that failed.

---

## 4. Section **gids**, never section names

**Context.** `Field_Mapping__mdt` could key on either.

**Decision.** Key on the gid. Store the name as a label only.

**Consequences.** A renamed column keeps mapping. Had this keyed on names, a rename would stop
matching silently and the board would go wrong with nothing anywhere saying why. The cost is that
the mapping table is unreadable without the labels, which is why the label field exists.

---

## 5. Type splits into a restricted picklist and a private raw field

**Context.** Asana's typing will evolve — Badge, Superbadge, Course, Book, Certification are
likely and the set is not settled.

**Considered.** An unrestricted picklist; a second Asana-specific type field.

**Rejected.** A second field splits the board, because `boardLayout` nests on type and the epic
walk keys on `Type__c`. An unrestricted picklist puts free text on the guest payload — and
`Type__c` reaches the public board, so whatever somebody typed into Asana would be published.
"Reading: Negotiating After a Layoff" is a real leak, and one nobody would notice, because
`Type__c` is not a field anyone thinks of as free text.

**Decision.** `Type__c` stays restricted and gains nothing until a value is committed to.
`Source_Type__c` holds the raw vendor string, on no DTO and no guest permission set.

**Consequences.** "Which types am I actually using" becomes a `GROUP BY` over rows where
`Type__c = 'Unspecified'`. A raw value that appears often enough earns a picklist entry. Evidence
rather than guesswork.

---

## 6. The board branches on a boolean, not a vendor

**Context.** The epic toggle must condense Jira tasks into their epics and leave Asana items
alone. Asana items are neither epics nor orphans.

**Considered.** Sending the source system on the card and branching in the component.

**Decision.** `BoardSourceRules` answers one question — does this system's work roll up into
epics — and `PublicBoardController` publishes the **answer** as `PublicCard.condensesIntoEpic`.

**Consequences.** No method on either side branches on a vendor, and no vendor name reaches an
anonymous visitor at all, which is strictly better than sending one. `BoardSourceRules` is the
board's counterpart to `WorkItemAdapterFactory`: the one place allowed to name a system, because
something has to. It lists what _does_ condense, so a third system is flat until somebody decides
otherwise rather than silently inheriting Jira's hierarchy.

---

## 7. Public items became inbound-only, which changed Jira too

**Context.** The build brief described Asana outbound as "the same shape as Jira: bidirectional
for private items, inbound-only for public ones". No such rule existed — there was no
`Is_Public__c` check anywhere on the outbound path, and Jira pushed public items.

**Decision.** Build the rule, in the shared `WorkItemTriggerHandler`, because public-ness is a
property of the work item rather than of the system it came from and a branch on
`Source_System__c` is what the adapter seam exists to prevent.

**Consequences.** **A public Jira issue no longer responds to a status change made in
Salesforce.** That is a behaviour change to a working integration, not a restatement of one. It
is asserted by two tests written on a Jira record precisely so the change is visible in the test
names, and it is flagged in the class comment, the build summary and the handoff.

**Revisit if** the intent was only ever about Asana. Reverting is one clause in one method.
