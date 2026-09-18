# Handoff — Portfolio HQ (neoGeoDevOrg)

What a new context window needs and cannot read from the repo. Decisions and their
reasoning live in `docs/adr/`; per-build narrative lives in `docs/build-summaries/`.
**This file holds only what git does not know: org state, invariants, and traps.**

Current as of the refactor pass after Build 06 (`docs/build-summaries/refactor-01.md`).
Builds 01–06 are deployed and verified against live Jira. Class names below reflect the
refactor: `JiraWebhookProcessor` became `WorkItemInboundProcessor`, and Jira payload parsing
moved into `JiraAdapter.parseInbound`. Older ADRs and summaries use the old name.

---

## 1. Org state that is not in source control

None of this survives an org rebuild, and none of it is visible in the repo.

| Thing                     | Value / where                                                                                                                                                         |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scratch org alias         | `MyScratchOrg`                                                                                                                                                        |
| Jira API token            | Pasted by hand into External Credential `Jira_Token`, principal **`Personal Key`**. Username is the Atlassian account email. Never in source.                         |
| Webhook signing secret    | `Integration_Secret__mdt` record **`Jira_Webhook`**, `Is_Active__c = true`. Created in Setup. `customMetadata/` is gitignored on purpose.                             |
| Jira webhook registration | Registered in Jira, event **Issue → updated** only, JQL `project = DOPP`, secret set, "Exclude body" off.                                                             |
| Parked metadata           | Named credential `Jira_Atlassian` and permission set `Jira_Demo_Access` exist in the org and are deliberately out of source (`.forceignore`) until a build uses them. |

### Permission set assignments — manual, not metadata

Deploying a permission set does **not** assign it. This has broken the build three
separate times. Current assignments:

```
Portfolio_HQ_Developer  -> test-vuqbitgj0ulq@example.com                      (admin)
Jira_Webhook_Guest      -> test_professional_site@...org.force.com            (site guest)
Portfolio_HQ_Guest      -> test_professional_site@...org.force.com            (site guest)
```

```bash
sf org assign permset --name <Name> --on-behalf-of "<username>" --target-org MyScratchOrg
```

### The two sites, and which one does what

```
Test_Professional_Site   /neoGeoTestvforcesite   <- serves Apex REST (the webhook endpoint)
Test_Professional_Site1  /neoGeoTest             <- LWR site, hosts the public board
```

**Both share one guest user.** Its `CommunityNickname` is **`Test_Professional_Site`** —
which is what guest sharing rules reference, and which looks like the wrong site because
the board lives on `/neoGeoTest`. It is correct. Do not "fix" it.

The webhook endpoint answers only on `/neoGeoTestvforcesite`. `/neoGeoTest` returns a
302 to login for Apex REST. The public board needs site public access enabled **and the
site published** — it 302s to login otherwise, including the home page, which is how to
tell a site-level problem from a page-level one.

### Sharing models — already correct, do not change

```
Work_Item__c  internal=ReadWrite  external=Private
Project__c    internal=ReadWrite  external=Private
```

External is already Private, which is all guest sharing rules need. **Tightening the
internal OWD would break internal access**: most work items are owned by Automated
Process, and `Portfolio_HQ_Developer` holds `viewAllRecords=false` on both objects.

### Demo data

Two projects, one public. 6 of the 14 work items under the public project are flagged public
(14 since the refactor pass back-filled six that had no project).
To restore after a rebuild:

```bash
sf apex run --file scripts/apex/flag-public-demo-data.apex --target-org MyScratchOrg
```

Deliberately partial — records are left private so "no non-public record leaks" is
testable. One of them is a child of a public parent.

Build 06 added two things to it. A **hierarchy**, because a flat set of orphans renders the epic
view empty and that is indistinguishable from a broken one. And the **canary**: `SEED-CANARY`, a
work item flagged public under the _private_ project, owned by a real user so sharing genuinely
grants the row. It must never render.

The script **never writes `Status__c`**, and that is load-bearing rather than tidy.
`WorkItemTriggerHandler` enqueues a real outbound push on any status change to a record carrying an
`External_Id__c`, so assigning a status here would transition live Jira issues as a side effect of
seeding demo data. It picks epics from records that already hold the status each role needs. The
canary carries no `External_Id__c` at all, so it can never be pushed however it is later edited.
Check `Integration_Log__c` does not grow across a run.

---

## 2. Invariants — breaking these produces silent failure

**`Sync_Status__c = 'Synced'` is illegal when `Status__c = 'Unspecified'`.**
Validation rule `Sync_Status_Requires_Known_Status`. Inbound hits this whenever Jira
reports an unmapped status, and handles it by staying `Pending`.

**The outbound push needs `Sync_Status__c` staged to `Pending`.**
`JiraAdapter` skips its callout when the status matches the target _and_
`Sync_Status__c = 'Synced'`. The service passes the record's own status as the target,
so the first half is always true. `WorkItemTrigger`'s **before update** context resets
`Sync_Status__c` on a real status change. Remove that and a record syncs exactly once,
then goes silent forever **while reporting success**.

**DML before a callout throws.** `You have uncommitted work pending`. All callouts in a
chunk run first; `Integration_Log__c` rows buffer in memory and are written after.

**Callout budget.** 2 callouts per item, 100 per transaction → chunks of 50. The other
ceiling is 120s cumulative callout time; measured ~563ms per call, so count binds first
at current latency.

**`External_Id__c` is namespaced** (`jira:10023`). Jira's REST paths need the raw id —
`ExternalIdUtil.rawIdOf()`. Uniqueness is per field, not per system, which is why the
prefix exists.

**Loop prevention is three mechanisms, and the third is the load-bearing one.**
Suppression flag (one transaction only), timestamp comparison (durable), and the
**status-delta check on the trigger**. The first two cannot stop the echo of our own
push — each cycle is genuinely newer. Only the delta check does.

**Inbound-created records need `OwnerId` set.** Guest sharing rules do not share records
owned by Automated Process, and the webhook subscriber owns everything it creates.
`WorkItemInboundProcessor` sets the owner on creation only. Without it, every newly synced
issue is invisible on the public board with no error anywhere.

**Inbound-created records also need `Project__c` set, and since the refactor pass they get it
from the payload.** `fields.project.key` is matched against `Project__c.External_Project_Key__c`
with the same `External_System__c` as the delivery. Assigned on creation, or when the record has
no project; an existing link is never overridden. No match, or more than one, leaves the lookup
null and writes an `Integration_Log__c` row naming the key. The public board's query requires a
public parent project, so an unlinked record is public, synced and invisible - the same failure
shape as the owner. Records created by hand before this existed are linked on their next
delivery, provided the project record carries the key and the system.

**The guest must never reach `WorkItemBoardController`.** Apex class access is per class,
not per method — reaching it at all exposes `changeStatus`. That is why
`PublicBoardController` exists as a separate class with no write method.

**The guest DTO's key set is asserted exactly** in `PublicBoardControllerTest`. Adding a
field fails the test on purpose, so publishing something new to an anonymous visitor is
a deliberate act.

**Status, timestamps, title, type and parent all sync inbound** as of build 06.
`Type__c` comes from `fields.issuetype.name` through `IWorkItemAdapter.normalizeType`;
`Parent_Work_Item__c` comes from `fields.parent`; `Project__c` from `fields.project.key`.
All of that reading happens in `JiraAdapter.parseInbound`, which returns a vendor-neutral
`InboundChange`. The processor never sees a payload, which is what lets Asana be a second
adapter rather than a second processor.

**Every one of those is assigned only when the payload carries it.** Most deliveries are
status transitions carrying no summary, issuetype or parent at all — writing a null
through would blank known data on every one of them. An `issuetype` object present but
with a blank `name` counts as absent, not as unmapped.

**Parent resolution is a second pass, and deliberately creates no stub records.** A
delivery batch can carry a child and its parent in either order, so linking happens after
every record in the batch exists. A parent `External_Id__c` Salesforce has never seen
leaves `Parent_Work_Item__c` null, writes an `Integration_Log__c` row naming both sides,
and the delivery still succeeds. **Nothing back-fills that link when the parent later
arrives** — only a subsequent delivery for the _child_ repairs it. The log row is the
only record of the gap.

**`In Review` is unreachable.** It exists in the picklist; the Jira board offers only
To Do, In Progress and Done. Board columns are configurable so it can be added later
without a code change.

---

## 3. Traps, each of which cost real time here

**Metadata deploys do not grant field-level security.** Symptom:
`Operation failed due to fields being inaccessible`. Fix: assign the permission set.

**Deploying an LWC does not update the site.** An LWR site serves a built bundle. Deploy the
component, see the org's `LightningComponentBundle.LastModifiedDate` move, and the public page
still serves the old markup until the site is republished:

```bash
sf community publish --name "Test Professional Site" --target-org MyScratchOrg
```

`--name` is required and is the **Network** name, not the Site name — so `Test Professional Site`
even though the board lives on `/neoGeoTest`, which is Site `Test_Professional_Site1`. Same trap as
the `guestUser` CommunityNickname. The publish is **asynchronous**: it returns a job id, and the
change goes live a minute or so later. Poll it:

```bash
sf data query -o MyScratchOrg -q "SELECT Status, Error FROM BackgroundOperation WHERE Id = '<job id>'"
```

**`standard__LightningSales` cannot be deleted, and trying takes the whole deploy with it.** The org
rejects it twice over — "standard and cannot be deleted", and separately because in-app guidance is
attached. Deploys are atomic, so one unrelated deletion in the set fails everything. It is a standard
app present in every org and needs no source file, so the answer is never to delete it.

**`.forceignore` does not retract a deletion already pending.** A pending delete lives in source
tracking, not in file presence, so ignoring the path stops future retrieves pulling it back but does
not stop the CLI trying to delete it. Both are needed:

```bash
# after adding the path to .forceignore
sf project reset tracking --target-org MyScratchOrg --no-prompt
```

**Source tracking breaks constantly.** Scoped deploys and `deploy validate` leave every
component's `lastRetrievedFromServer` null, which reports the whole org as remotely
changed and produces a wall of conflicts on the next deploy.

```bash
sf project reset tracking --target-org MyScratchOrg --no-prompt
```

**Always diff before `--ignore-conflicts`.** It overwrites the org with local content.
Once in this project a conflict was real — the site page had been edited in Experience
Builder. Retrieve the org's copy and compare semantically (JSON/XML formatting differs,
content usually does not).

**Retrieves strip XML comments but keep `<description>`.** Rationale written as an XML
comment in metadata disappears on the next retrieve. Put it in a `description` element.

**Prettier reformats metadata between edits.** String-match patches silently no-op —
assert that a replacement actually changed the file.

**Prettier and the org fight over formatting, and the loop never settles on its own.**
A retrieve reporting 60+ modified files is almost always this, not real drift. The
mechanism is the **pre-commit hook**, not the editor extension — `package.json` wires
`husky` → `lint-staged` → `prettier --write`, so:

1. You deploy — the org stores those exact bytes.
2. You commit — the hook reformats the staged files.
3. The repo now holds prettier's version; the org holds the pre-prettier version.
4. The next retrieve drags the org's version back.

Repo and org are never formatted the same way, by construction. Disabling the VS Code
Prettier extension changes nothing, because step 2 is a git hook.

Six flavours of pure churn, none of them meaningful: trailing newline (prettier adds,
Salesforce strips), `UTF-8 ?>` vs `UTF-8?>`, LWC JS quote style / indent / 80-col
wrapping and prettier's `return ( … )` parens, the `<description\n  >` break in XML,
`&apos;` vs a literal apostrophe, and `" : "` vs `": "` in digitalExperiences JSON.

**Two fixes, applied in build 06:**

- `.prettierignore` now covers `digitalExperiences/`, `profiles/`, `sharingRules/`,
  `permissionsets/` and `**/*-meta.xml`. These are org-generated; prettier's only effect
  on them was guaranteed churn. **For these paths the org's format is now canonical** —
  commit what the retrieve gives you rather than reformatting it.
- **The cure in use since build 06: deploy freely, retrieve minimally.** The clash only happens
  when a retrieve pulls the org's formatting back over prettier's, so source that lives in git
  travels local → org only and is never retrieved. `manifest/org-changes.xml` is the declarative-only
  package for that: `sf project retrieve start -x manifest/org-changes.xml`. It deliberately omits
  ApexClass, ApexTrigger, LWC, DigitalExperience **and Profile** — every churn source identified.
  Running `npm run prettier` before deploy would also have narrowed the gap, but not retrieving the
  files at all closes it.
- **Since the refactor pass, every project Apex file is formatted at prettier's defaults** (two
  spaces), and `.prettierignore` also excludes the org's site scaffolding. `npm run
prettier:verify` and `npm run lint` are clean and should stay so. The hook only reformats
  files you stage, so a file nobody has touched keeps whatever style it had - which is how the
  repo ended up half 2-space and half 4-space before the pass.

**A side effect worth knowing when reviewing a commit:** the hook reformats whole files on
the way in, so a commit's diff can be far larger than the change you reviewed. Build 06
step 2 was ~35 lines of real change; `JiraAdapter.cls` went into `e0fc34c` as 801 changed
lines because the hook prettier-formatted the whole file at the same time.

**Sorting a post-retrieve working tree.** Normalising whitespace and quote style is enough
to separate churn from substance:

```bash
for f in $(git diff --name-only); do
  a=$(git show HEAD:"$f" | tr -d "[:space:]'\"()"); b=$(cat "$f" | tr -d "[:space:]'\"()")
  [ "$a" != "$b" ] && echo "SUBSTANTIVE: $f"
done
```

Run this before reverting anything. In build 06 it reduced 63 modified files to two real
changes: `Admin.profile` gaining `PublicBoardControllerTest` class access, and the route's
`pageAccess` going `UseParent` → `Public` — the latter being build 05's site-public-access
click, which the repo had never captured.

**Salesforce API gotchas found the hard way:**

- Long Text Area fields are not filterable in SOQL.
- `Owner.UserType` is not filterable through a polymorphic lookup; compare `OwnerId`.
- `PermissionSet.description` caps at 255 chars; field and object descriptions at 1000.
- Guest sharing uses `sharingGuestRules`, not `sharingCriteriaRules`.
  `includeRecordsOwnedByAll` is **invalid** there. `guestUser` takes a
  `CommunityNickname`.
- A criteria sharing rule cannot reference a parent field, so
  `Project__r.Is_Public__c` is enforced **only** by `PublicBoardController`'s WHERE
  clause. Any future guest-reachable class touching `Work_Item__c` inherits that duty.

**Apex gotchas:**

- Identifiers are case-insensitive: a field named `outcome` shadows a type named
  `Outcome`. Qualify enums as `ClassName.Enum.VALUE`.
- Trailing underscores are illegal in identifiers (`update_` will not compile).
- `@TestVisible` does not expose members to anonymous Apex.
- Apex only type-checks server-side. Nothing is verified until it deploys.

**Page layouts.** Deploys create fields but do not place them on layouts. This made
`Secret_Value__c` invisible in Setup until a layout was added. `Project__c`,
`Work_Item__c`, `Integration_Log__c` and `Webhook_Event__c` still have bare layouts.

---

## 4. Open items

| Item                                                                                                                                                                                                                                 | Trigger point                         |
| ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------- |
| Integration owner resolved by `Profile.Name = 'System Administrator'` — brittle. A dedicated integration user named in configuration is the right answer.                                                                            | Before a second admin exists          |
| `Integration_Log__c` and `Webhook_Event__c` grow unbounded; no purge job.                                                                                                                                                            | At volume                             |
| Unauthenticated callers can still create `Webhook_Event__c` rows. Bounded to ~106 chars each (payload dropped on signature failure) but the row count is not capped — capping needs a query the guest cannot run.                    | If the endpoint sees hostile traffic  |
| `Retry_Count__c` is inert; retry policy was never built.                                                                                                                                                                             | When retries are wanted               |
| Bare page layouts on four objects.                                                                                                                                                                                                   | Cosmetic                              |
| An unresolved parent reference is never back-filled. The child must be delivered again after the parent exists. Closing this needs either a `Parent_External_Id__c` field or the reconciliation job.                                 | When hierarchy gaps are noticed       |
| Prettier and the org disagree on formatting for hand-written source. Mitigated by retrieving only through `manifest/org-changes.xml`; a full retrieve still churns. See section 3.                                                   | Next time a full retrieve is needed   |
| Both non-admin profiles carry 49 disabled `classAccesses` entries from an old retrieve. Harmless — they grant nothing — and now unreachable by the minimal-retrieve manifest, which omits Profile entirely.                          | Cosmetic                              |
| An epic card does not truncate its title. Real Jira summaries run to four lines in a board column.                                                                                                                                   | Cosmetic                              |
| A `npm audit fix` that bumps `@salesforce/sfdx-lwc-jest` to v8 breaks Jest completely — v8 stops transforming `@lwc/engine-dom` and every suite dies on its ESM export before a test runs. Revert to `^7.0.2`.                       | If `npm run test:unit` dies wholesale |
| Work items created by hand or before project linkage may still have no `Project__c`. They are linked on their next delivery if the project record carries the Jira key and `External_System__c = Jira`; otherwise a log row says so. | After the next few live deliveries    |

---

## 5. Verifying the system still works

```bash
# Tests
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human
npm run test:unit

# Guest record access must equal Is_Public__c exactly
sf data query -o MyScratchOrg -q "SELECT COUNT() FROM Work_Item__c WHERE Is_Public__c = true"

# Synced records with no project cannot appear on the public board. Expect this to fall to 0
# as issues are redelivered; each one that stays unlinked has an Inbound log row naming why
sf data query -o MyScratchOrg -q "SELECT COUNT() FROM Work_Item__c WHERE Project__c = null AND External_Id__c != null"
# Or link them all now, by key prefix, without waiting for a redelivery (never writes Status__c)
sf apex run --file scripts/apex/backfill-work-item-projects.apex --target-org MyScratchOrg

# Outbound: change a status, expect 2 Integration_Log__c rows and no more
sf data query -o MyScratchOrg -q "SELECT Name, HTTP_Method__c, Status_Code__c FROM Integration_Log__c ORDER BY CreatedDate DESC LIMIT 4"

# Inbound: every event should reach a terminal status, none stuck Pending
sf data query -o MyScratchOrg -q "SELECT Processing_Status__c, COUNT(Id) c FROM Webhook_Event__c GROUP BY Processing_Status__c"

# The public board, as an anonymous visitor
curl -s -o /dev/null -w '%{http_code}\n' https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
```

Build 06 added a second view. Both payloads ship on every call whichever is on screen, so check
what the guest actually receives rather than what renders:

```bash
sf apex run --target-org MyScratchOrg <<'EOF'
PublicBoardController.PublicBoardData b = PublicBoardController.getPublicBoardData();
System.debug('>>> tasks=' + b.itemCount + ' epics=' + b.epics.size());
System.debug('>>> epic keys=' + ((Map<String,Object>)JSON.deserializeUntyped(JSON.serialize(b.epics[0]))).keySet());
EOF
```

Expect **exactly one SOQL query** in that debug log's limit block. Ancestry and child counts are
computed in memory; a per-epic query would put the guest page one busy project away from the
governor limit.

The seed script is the way to get a board worth looking at after a rebuild, and it now also plants
a **canary**: a work item flagged public under a _private_ project. It must never render. If it
does, the only enforcement of the parent project flag has gone.

A loop-prevention check: change one `Status__c`, then watch `Integration_Log__c`. It
should gain exactly 2 rows and stop. Climbing by 2 repeatedly means the loop did not
terminate.
