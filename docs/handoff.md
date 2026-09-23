# Handoff — Portfolio HQ (neoGeoDevOrg)

What a new context window needs and cannot read from the repo. Decisions and their
reasoning live in `docs/adr/`; per-build narrative lives in `docs/build-summaries/`.
**This file holds only what git does not know: org state, invariants, and traps.**

Current as of **Build 07** (`docs/build-summaries/build-07.md`), which added Asana as a second
source system. The manual Asana setup in section 6 **has been done** and the integration is live:
real tasks sync in, six Asana work items render on the public board, and the Format field types
them. Builds 01–06 are deployed and verified against live Jira. Class names below reflect the
refactor after build 06: `JiraWebhookProcessor` became `WorkItemInboundProcessor`, and Jira
payload parsing moved into `JiraAdapter.parseInbound`. Older ADRs and summaries use the old name.

**Two things changed late in build 07 and reversed an earlier decision within it.** Step 8 made
sync inbound-only for anything flagged public; step 9 removed that, because `Is_Public__c` gates
reading and says nothing about writing - see section 2. And inbound now inherits the project's
`Is_Public__c` when it creates a record, so synced work reaches the public board without a manual
tick.

---

## 1. Org state that is not in source control

None of this survives an org rebuild, and none of it is visible in the repo.

| Thing                     | Value / where                                                                                                                                                                                                  |
| ------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Scratch org alias         | `MyScratchOrg`                                                                                                                                                                                                 |
| Jira API token            | Pasted by hand into External Credential `Jira_Token`, principal **`Personal Key`**. Username is the Atlassian account email. Never in source.                                                                  |
| Webhook signing secret    | `Integration_Secret__mdt` records, `Is_Active__c = true`. Jira's is **`Jira_Webhook`**, created in Setup. Asana's is `Webhook_<resource gid>`, promoted by script. `customMetadata/` is gitignored on purpose. |
| Asana PAT                 | External Credential **`Asana_Token`**, principal **`PAT1`**, behind Named Credential `Asana_Personal` (base URL `https://app.asana.com/api/1.0`). Out of source, like `Jira_Atlassian`.                        |
| Jira webhook registration | Registered in Jira, event **Issue → updated** only, JQL `project = DOPP`, secret set, "Exclude body" off.                                                                                                      |
| Parked metadata           | Named credential `Jira_Atlassian` and permission set `Jira_Demo_Access` exist in the org and are deliberately out of source (`.forceignore`) until a build uses them.                                          |

### Scheduled jobs — manual, not metadata

`WorkItemInboundSweeper` runs every 15 minutes via **four** CronTriggers named
`Work Item Inbound Sweeper :00/:15/:30/:45`. Deploying the class does not create them.

```bash
sf apex run --file scripts/apex/schedule-inbound-sweeper.apex --target-org MyScratchOrg
```

**Run that script as a user holding the `Asana_Token-PAT1` external credential grant.** That is
the mechanism, not a convention: an async job runs as the user who started it and a Queueable
inherits the user of whatever enqueued it, so the Asana callout inside `WorkItemInboundQueueable`
is made as whoever ran the script. Schedule it as a user without the grant and every sweep ends in
`We couldn't access the credential(s)`.

Four jobs rather than one because Salesforce cron rejects a list in the seconds or minutes field -
`0 0,15,30,45 * * * ?` throws `Seconds and minutes must be specified as integers`. The org allows
100 scheduled Apex jobs, so four is cheap, but it is four.

The nightly purge is a **fifth** job, scheduled separately:

```bash
sf apex run --file scripts/apex/schedule-data-purge.apex --target-org MyScratchOrg
```

`IntegrationDataPurge` holds `Webhook_Event__c` and `Integration_Log__c` at their **50 most
recent rows each**, at 23:00. **The cron runs in the scheduling user's time zone, not the org's
and not UTC** - the admin is `America/Los_Angeles`, so this is 11pm Pacific and follows daylight
saving on its own. Schedule it as a user in another zone and it fires at 11pm in that zone.

It hard-deletes: rows are removed from the recycle bin too, so there is no undelete. It will never
take a `Webhook_Event__c` still `Pending` - that is work in progress, not history - and Pending
rows are excluded from the row count as well as the delete, so stuck deliveries cannot push real
history over the cap.

**What the 50-row cap costs, deliberately.** Rejected-signature rows age out like everything else,
and they are the only record that unauthenticated traffic reached a public endpoint. Version 2
archives to a Big Object before deleting; until then the cap is simply the policy.

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

**`Ignored` means two different things, and `Ignore_Reason__c` is which.** `Superseded` is a
newer delivery for the same external id winning inside the batch - the winner carries the whole
story. `Not Applicable` is the adapter having nothing to say about the resource, so no retry would
ever produce a change; Asana story events are the bulk of these. Retention rules read the field.
Before it existed the only way to tell them apart was to string-match `Error_Message__c`, which
breaks silently the day somebody rewords a message. Values live in `IgnoreReason`; do not write
the literal.

**`Is_Public__c` is a READ gate and nothing else.** It gates the guest board, in two
places: `PublicWorkItemSelector`'s `WHERE` clause and the two criteria-based guest sharing
rules. It does **not** govern who may write the record. Build 07 step 8 added
`item.Is_Public__c != true` to `WorkItemTriggerHandler.isPushable`, making sync inbound-only
for anything on public display — which silently turned every item on the public board
read-only from the internal board, Jira's included, with no error anywhere. Step 9 removed it.
`WorkItemTriggerHandlerTest.aPublicJiraItemStillPushesOnAStatusChange` and
`AsanaOutboundTest.aPublicItemsStatusChangeEnqueuesOneJobToo` fail if it comes back.

**Inbound sets `Is_Public__c` from the parent project, on creation only.** The field defaults
to `false`, so before this every synced item arrived invisible and stayed invisible until
somebody ticked the box by hand — no error when that was missed, the item simply never
appeared. `WorkItemInboundProcessor` now inherits the resolved project's flag when it creates
a record, and never on update, so an item unpublished by hand is not republished by the next
delivery from the source system. An item whose project key resolves to nothing is created
private, which is the safe direction.

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
with the same `External_System__c` as the delivery. No match, or more than one, leaves the lookup
null and writes an `Integration_Log__c` row naming the key. The public board's query requires a
public parent project, so an unlinked record is public, synced and invisible - the same failure
shape as the owner. Records created by hand before this existed are linked on their next
delivery, provided the project record carries the key and the system.

**Since build 07 step 2 the link follows a move, and the old rule is gone.** The refactor pass
said "an existing link is never overridden", which protected links made by hand and froze stale
ones in the same breath. On the guest path it failed open: an issue moved in Jira from a public
project to a private one carries the new key, the key was ignored, and the record kept pointing
at the public project - so the public board, whose only enforcement of the parent flag is
`PublicWorkItemSelector`'s WHERE clause, kept rendering it to anonymous visitors after its remote
home had become private. Three cases now, and they are distinct:

| Record     | Payload               | Result                                |
| ---------- | --------------------- | ------------------------------------- |
| no project | names one             | assign. The back-fill path, unchanged |
| a project  | names a different one | follow the move, and log both keys    |
| a project  | names the same one    | nothing written, nothing logged       |

A move whose new key resolves to nothing, or to more than one project, **keeps the link it has**
and logs. Nulling a working link because a lookup failed would hide the record from the board
rather than correct it. The `Is_Public__c` flag on the work item is deliberately left alone:
following the move is what closes the leak, and the flag is a separate decision.

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

**A site guest can write a custom object row and can never read one back.** Not its own row,
not in system mode, not through a `without sharing` class. This is the Guest User Security
Policy and it is not configuration - in build 07 step 4 object access, field-level security,
view-all and `without sharing` were each granted in turn and each only moved the error along
(`sObject type not supported`, then `No such column`, then a silent null). `JiraWebhookResource`
already relied on this for its rate-limit comment; step 4 measured it.

**Consequently, a webhook signing secret cannot be verified from a custom object field.** The
endpoint runs as the guest. So secrets live in two places on purpose:

- `Webhook_Secret__c` is a **write-only staging row**. The registration handshake is the only
  moment a vendor sends its secret, and staging it is all the guest can do. Insert only - the
  guest licence forbids `Edit` on a custom object outright, and first-write-wins also stops an
  unauthenticated caller replacing a live secret with one of their own.
- `Integration_Secret__mdt` is what verification reads. Apex reads protected Custom Metadata
  with **no object grant, no field-level security and no sharing rule**, from any user including
  the guest. That is how Jira has verified since build 02.
- `scripts/apex/promote-webhook-secret.apex` carries the value across, run by hand beside the
  curl that registers the webhook. Apex cannot write Custom Metadata synchronously and the guest
  could not deploy it anyway. Until it is run, deliveries are rejected 401 and the vendor
  retries; Asana tolerates 24 hours of failures. **Delete the staged row once promoted.**

**`In Review` is unreachable.** It exists in the picklist; the Jira board offers only
To Do, In Progress and Done. Board columns are configurable so it can be added later
without a code change.

---

## 3. Traps, each of which cost real time here

**A schedulable class cannot be deployed while it has scheduled jobs.** The deploy fails whole -
every other class in the same command with it - with `This schedulable class has jobs pending or in
progress - CronTrigger IDs (...)`. The message names ids and never says "unschedule it first". So
any change to `WorkItemInboundSweeper` **or `IntegrationDataPurge`** is a three-step loop:

```bash
sf apex run --file scripts/apex/unschedule-inbound-sweeper.apex --target-org MyScratchOrg
```

then deploy, then re-run `schedule-inbound-sweeper.apex`. The alternative is the "Allow deployments
of components when corresponding Apex jobs are pending or in progress" checkbox in
Setup > Deployment Settings, deliberately not enabled: the schedule script is also the thing that
records which user the sweeps run as, and that matters more here than the convenience does.

**Scheduled Apex cannot make callouts.** Which is why `WorkItemInboundSweeper` enqueues
`WorkItemInboundQueueable` rather than calling `WorkItemInboundProcessor.process` itself. Same
family of refusal as the trigger-context one that created the queueable in the first place.

**A `PlatformEventSubscriberConfig` does not take effect until the subscriber is restarted.**
The inbound queueable calls Asana, and a callout needs the `Asana_Token-PAT1` external
credential principal. The platform event subscriber runs as **Automated Process**, which
cannot be granted it — `sf org assign permset --on-behalf-of` refuses with
`user license doesn't match`. Pointing the subscriber at a real user with a
`PlatformEventSubscriberConfig` record is the fix, but creating the record changes nothing on
its own, and **redeploying the trigger does not re-register it either**. Every delivery kept
failing with `System.CalloutException: We couldn't access the credential(s)`, an error that
names neither the running user nor the subscriber. Suspend and resume the trigger in
**Setup → Platform Events → Webhook Event Received → Subscriptions** and the config is picked
up. Symptom to recognise: events stuck `Pending`, jobs reporting `Completed errors=0`, and the
credential error only in `Integration_Log__c`.

**Test the identity, not just the code.** Three separate defects in build 07 were the same
mistake — verifying a path as the admin when it runs as somebody else. The guest FLS failure
on inbound DML, the trigger-callout defect, and the credential failure above all passed a
hand-run check from anonymous Apex because anonymous Apex runs as you. Anything reached by a
guest, by Automated Process, or by a platform event subscriber has to be exercised as that
user or the check is vacuous.

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

**Encrypted Text is not readable by Apex the way everyone assumes.** Apex returns an encrypted
field **masked** unless the running user holds the `ViewEncryptedData` USER PERMISSION - and
system mode does **not** bypass it the way it bypasses field-level security. Proved with an A/B
holding FLS constant: granting the permission to the permission set flipped the same system-mode
read from asterisks to clear text and back. Worse, a **guest permission set silently cannot hold
it**: the deploy reports success and the org keeps `PermissionsViewEncryptedData = false`. So
Encrypted Text is unusable for anything a guest-run endpoint must read.

**Callouts are forbidden from triggers, and the inbound subscriber IS a trigger.** The
subscriber on `Webhook_Event_Received__e` therefore only ENQUEUES: `WorkItemInboundProcessor.handle`
hands the batch to `WorkItemInboundQueueable`, which is where `parseInbound` runs and where an
adapter is allowed to call out. Jira never revealed this because it calls out for nothing; the
first live Asana delivery failed with `System.CalloutException: Callout from triggers are
currently not supported` while the whole test suite stayed green, because every test calls
`WorkItemInboundProcessor.process` directly. **A test that drives processing directly is not
testing the path that runs in production.** The outbound path has always had this shape - the
trigger enqueues `WorkItemSyncQueueable` - and inbound now matches it.

**A queueable enqueued while `Test.stopTest()` delivers a platform event does not execute.** So
an endpoint test cannot assert an end-to-end outcome any more; `JiraWebhookResourceTest` drives
the second half itself via a `drainStagedDeliveries()` helper. The async boundary is real, not a
test artefact.

**`FieldMappingService` reads live custom metadata when nothing is injected, so org data can
change what a test measures.** Deploying the three real Asana status mappings made
`anItemForAnUnsupportedSystemFailsWithoutStoppingTheRest` pass an Asana item through that it had
always rejected - it had used `asana:` as its example of an unregistered system. It uses
`trello:` now. Any test asserting "no mapping exists" must inject an empty table rather than
assume the org has none.

**Asana's batch endpoint rejects query parameters in `relative_path`**, and rejects them as a
**400 inside an otherwise 200 response** - so the batch call looks like it worked and every task
inside it silently fails. `opt_fields` goes in `options.fields` as an array per action. The mock
did not catch this because it read the gid out of the path and answered happily whatever else
was in it.

**Guest field-level security is enforced on DML, so one ungranted field fails the whole insert -
silently, if the caller catches.** Apex runs in system mode for every other user and ignores
field-level security on writes; the guest is the exception. `AsanaWebhookResource.record()` set
`Webhook_Event__c.External_Id__c`, which `Jira_Webhook_Guest` does not grant, so every rejection
and handshake row failed to insert while the endpoint still answered correctly. **No Apex test
could catch it, because tests run as the admin.** Found by POSTing to the live endpoint and
finding no row. Any guest-written field must be in that permission set, and any endpoint test
worth trusting runs inside `System.runAs(<the site guest>)`.

**The Guest User licence refuses `Edit` on a custom object**, and says so at deploy time: `The
user license doesn't allow the permission: Edit <Object>`. Guest-facing writes must be inserts.

**Apex gotchas:**

- `nulls` is a reserved word (SOQL's `ORDER BY ... NULLS FIRST`) and cannot be a variable name.
  The Apex parser's message names the token but not the reason. Same family as the trailing
  underscore rule below.
- Identifiers are case-insensitive: a field named `outcome` shadows a type named
  `Outcome`. Qualify enums as `ClassName.Enum.VALUE`.
- **No DML may happen before `IWorkItemAdapter.parseInbound` is called.** An adapter is
  allowed to call out from there and `AsanaAdapter` does, because Asana's payloads name a
  resource and an action and carry neither the task's title nor its section. Any earlier DML
  in the transaction produces `CalloutException: You have uncommitted work pending`, and it
  does so **for Asana deliveries only**, with an error that never mentions Asana. The same
  shape of trap as the line above: the message does not name the cause. The rule is written
  on the interface, in `CLAUDE.md` and here, because ordering alone happened to be safe and
  nothing enforced it.
- `Test.stopTest()` restores the limits context that was in force before `Test.startTest()`.
  A `Limits.getCallouts()` reading taken _after_ `stopTest` therefore reports the outer
  transaction's count, not the code under test - which makes
  `Assert.areEqual(before, Limits.getCallouts())` a vacuous assertion that passes even when a
  callout was made. Take both readings inside the window. Found in build 07 step 3 by breaking
  the test on purpose, which is the only reason it was found at all.
- Trailing underscores are illegal in identifiers (`update_` will not compile).
- `@TestVisible` does not expose members to anonymous Apex.
- Apex only type-checks server-side. Nothing is verified until it deploys.

**Page layouts.** Deploys create fields but do not place them on layouts. This made
`Secret_Value__c` invisible in Setup until a layout was added. `Project__c`,
`Work_Item__c`, `Integration_Log__c` and `Webhook_Event__c` still have bare layouts.

---

## 4. Open items

| Item                                                                                                                                                                                                                                                           | Trigger point                         |
| -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------- |
| Integration owner resolved by `Profile.Name = 'System Administrator'` — brittle. A dedicated integration user named in configuration is the right answer.                                                                                                      | Before a second admin exists          |
| ~~`Integration_Log__c` and `Webhook_Event__c` grow unbounded~~ **Closed.** `IntegrationDataPurge` caps both at 50 rows nightly. The cost is that rejected-signature rows and Processed history age out; version 2 archives them to a Big Object first          | Closed                                |
| Unauthenticated callers can still create `Webhook_Event__c` rows. Bounded to ~106 chars each (payload dropped on signature failure) but the row count is not capped — capping needs a query the guest cannot run.                                              | If the endpoint sees hostile traffic  |
| `JiraAdapter` deliveries go through the same sweeper as Asana's, but Jira never strands one - it calls out for nothing, so the retry budget is exercised by Asana alone.                                                                                       | Informational                         |
| Bare page layouts on four objects.                                                                                                                                                                                                                             | Cosmetic                              |
| An unresolved parent reference is never back-filled. The child must be delivered again after the parent exists. Closing this needs either a `Parent_External_Id__c` field or the reconciliation job.                                                           | When hierarchy gaps are noticed       |
| Prettier and the org disagree on formatting for hand-written source. Mitigated by retrieving only through `manifest/org-changes.xml`; a full retrieve still churns. See section 3.                                                                             | Next time a full retrieve is needed   |
| Both non-admin profiles carry 49 disabled `classAccesses` entries from an old retrieve. Harmless — they grant nothing — and now unreachable by the minimal-retrieve manifest, which omits Profile entirely.                                                    | Cosmetic                              |
| An epic card does not truncate its title. Real Jira summaries run to four lines in a board column.                                                                                                                                                             | Cosmetic                              |
| A `npm audit fix` that bumps `@salesforce/sfdx-lwc-jest` to v8 breaks Jest completely — v8 stops transforming `@lwc/engine-dom` and every suite dies on its ESM export before a test runs. Revert to `^7.0.2`.                                                 | If `npm run test:unit` dies wholesale |
| Work items created by hand or before project linkage may still have no `Project__c`. They are linked on their next delivery if the project record carries the Jira key and `External_System__c = Jira`; otherwise a log row says so.                           | After the next few live deliveries    |
| The Asana `Format` option "Article / paper" (`1218523733859544`) has no `Field_Mapping__mdt` row, because `Work_Item__c.Type__c` has no value to map it to. A task carrying it lands on `Unspecified` with the raw word in `Source_Type__c`.                   | When an article is added in Asana     |
| A project's `Is_Public__c` is read at creation time only, so flipping a project public does not retroactively publish the work already synced into it. Fix by hand, or with a one-off update that touches `Is_Public__c` and nothing else - never `Status__c`. | When a project is made public         |
| Nothing enforces deletion of a `Webhook_Secret__c` staging row after promotion; the script only says to. The Asana row was deleted by hand on 2026-09-21.                                                                                                      | After the next real registration      |
| Rotating a secret means deleting the staged row first: `Resource_Id__c` is unique and the guest cannot update a row.                                                                                                                                           | At first rotation                     |
| Secret promotion is manual. Automating it needs a platform event plus a Metadata API deployment from a user that can deploy metadata - untested for Automated Process.                                                                                         | If re-registration becomes frequent   |
| Flat items (any source with no epics) are always visible on the board, so their Done column grows unbounded. The orphan cap does not apply to them.                                                                                                            | At volume                             |
| `JiraAdapter` still uses hardcoded `STATUS_ALIASES` / `TYPE_ALIASES` while Asana reads `Field_Mapping__mdt`. Two mechanisms for one job.                                                                                                                       | Next time a Jira mapping changes      |

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

---

## 6. Asana — the manual setup (done; kept as the recipe for a fresh org)

Build 07's code is deployed and tested. None of it has met live Asana, because all of this is by
hand and out of build scope. Until it is done, an Asana delivery is rejected 401 and no Asana
work item exists.

### In Asana

1. Create the learning project with sections named **Up Next**, **In Progress**, **Completed**.
2. Capture the **project gid** and each **section gid**. The API returns them; the UI shows them
   in the URL.
3. Add an **enum** task custom field named **`Format`**, with an option per kind of work
   (`Book`, `Online course`, `Video series`, ...). This is a convention this project chose, not
   an Asana feature: a task has no native type, and `resource_subtype` is almost always
   `default_task`. `AsanaAdapter` matches the field name case-insensitively and reads the chosen
   option's **gid**, falling back to the display name for a non-enum field.

### In Salesforce

4. `Project__c` record with `External_Project_Key__c` = the project gid and
   `External_System__c` = `Asana`. **Without this the adapter cannot tell which of a task's
   memberships to read a section from**, so the item arrives with no project and no status.
5. `Field_Mapping__mdt` records, created in Setup (`customMetadata/` is gitignored):

   | External System | Mapping Type | External Value            | External Label | Normalized Value |
   | --------------- | ------------ | ------------------------- | -------------- | ---------------- |
   | Asana           | Status       | _Up Next section gid_     | Up Next        | To Do            |
   | Asana           | Status       | _In Progress section gid_ | In Progress    | In Progress      |
   | Asana           | Status       | _Completed section gid_   | Completed      | Done             |

   Keyed on the **gid**, never the section name: a gid survives a rename and a name does not.
   There is deliberately no `In Review` row — Asana has no such column, and that asymmetry is
   correct.

6. Type mappings, with `Mapping_Type__c = Type`, keyed on the **enum option gid** for the same
   reason status mappings are keyed on section gids. `scripts/apex/add-asana-type-mappings.apex`
   deploys them; read the gids with
   `GET /projects/<gid>/custom_field_settings?opt_fields=custom_field.name,custom_field.enum_options.name`.

   `Type__c` is a restricted picklist and carries both vocabularies: Jira's `Epic`, `Story`,
   `Bug`, `Task`, `Spike`, and the learning board's `Book`, `Online Course`, `Video`, `Tutorial`,
   `Trailhead`, `Superbadge`. An Asana option with no mapping lands on `Unspecified` with
   `Source_Type__c` keeping the raw name - that is the promotion path working, not a failure.

### Register the webhook, by hand

The target URL must carry the resource gid as its **last path segment** — the handshake carries
no body and a delivery names only the resources that changed, so neither can say which secret to
verify against.

```bash
curl -X POST https://app.asana.com/api/1.0/webhooks \
  -H "Authorization: Bearer $ASANA_PAT" \
  -H "Content-Type: application/json" \
  -d '{"data":{"resource":"<project_gid>","target":"https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTestvforcesite/services/apexrest/v1/webhook/asana/<project_gid>"}}'
```

A **201** means the handshake succeeded and a `Webhook_Secret__c` row exists. Anything else means
the endpoint did not echo correctly — check the row before retrying. A **409** means a secret is
already staged for that resource: delete the row first, deliberately.

### Then promote the secret — deliveries fail until you do

```bash
sf apex run --file scripts/apex/promote-webhook-secret.apex --target-org MyScratchOrg
```

The endpoint runs as the guest, and **a guest cannot read a custom object row** — so verification
reads protected Custom Metadata instead, and something run by a real user has to carry the value
across. Asana tolerates 24 hours of failures before deleting a webhook, so running this straight
after registering is comfortably inside the window. **Delete the staged row once promoted.**

### Known cost of the scratch org

The site URL dies with the org, and Asana deletes a webhook after 24 hours of failed delivery.
Re-registration is one curl plus one script run per org recreation.

### Seeding

Let real webhooks create Asana work items. If a script is ever needed, it sets the outbound
suppression flag on its first line - a status write on a record carrying an `External_Id__c`
enqueues a real push to real Asana.
