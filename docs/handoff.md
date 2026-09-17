# Handoff — Portfolio HQ (neoGeoDevOrg)

What a new context window needs and cannot read from the repo. Decisions and their
reasoning live in `docs/adr/`; per-build narrative lives in `docs/build-summaries/`.
**This file holds only what git does not know: org state, invariants, and traps.**

Current as of Build 05. Builds 01–05 are deployed and verified against live Jira.

---

## 1. Org state that is not in source control

None of this survives an org rebuild, and none of it is visible in the repo.

| Thing                     | Value / where                                                                                                                                 |
| ------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------- |
| Scratch org alias         | `MyScratchOrg`                                                                                                                                |
| Jira API token            | Pasted by hand into External Credential `Jira_Token`, principal **`Personal Key`**. Username is the Atlassian account email. Never in source. |
| Webhook signing secret    | `Integration_Secret__mdt` record **`Jira_Webhook`**, `Is_Active__c = true`. Created in Setup. `customMetadata/` is gitignored on purpose.     |
| Jira webhook registration | Registered in Jira, event **Issue → updated** only, JQL `project = DOPP`, secret set, "Exclude body" off.                                     |

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

6 of 11 work items and 1 project are flagged public. To restore after a rebuild:

```bash
sf apex run --file scripts/apex/flag-public-demo-data.apex --target-org MyScratchOrg
```

Deliberately partial — records are left private so "no non-public record leaks" is
testable. One of them is a child of a public parent.

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
`JiraWebhookProcessor` sets the owner on creation only. Without it, every newly synced
issue is invisible on the public board with no error anywhere.

**The guest must never reach `WorkItemBoardController`.** Apex class access is per class,
not per method — reaching it at all exposes `changeStatus`. That is why
`PublicBoardController` exists as a separate class with no write method.

**The guest DTO's key set is asserted exactly** in `PublicBoardControllerTest`. Adding a
field fails the test on purpose, so publishing something new to an anonymous visitor is
a deliberate act.

**Only status, timestamps and title sync inbound.** `Type__c` and
`Parent_Work_Item__c` are set by hand. A Jira-side change to either does not propagate.

**`In Review` is unreachable.** It exists in the picklist; the Jira board offers only
To Do, In Progress and Done. Board columns are configurable so it can be added later
without a code change.

---

## 3. Traps, each of which cost real time here

**Metadata deploys do not grant field-level security.** Symptom:
`Operation failed due to fields being inaccessible`. Fix: assign the permission set.

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

| Item                                                                                                                                                                                                              | Trigger point                        |
| ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------ |
| Integration owner resolved by `Profile.Name = 'System Administrator'` — brittle. A dedicated integration user named in configuration is the right answer.                                                         | Before a second admin exists         |
| `Integration_Log__c` and `Webhook_Event__c` grow unbounded; no purge job.                                                                                                                                         | At volume                            |
| Unauthenticated callers can still create `Webhook_Event__c` rows. Bounded to ~106 chars each (payload dropped on signature failure) but the row count is not capped — capping needs a query the guest cannot run. | If the endpoint sees hostile traffic |
| `Retry_Count__c` is inert; retry policy was never built.                                                                                                                                                          | When retries are wanted              |
| Bare page layouts on four objects.                                                                                                                                                                                | Cosmetic                             |
| `Title__c` and `Parent_Work_Item__c` do not sync inbound.                                                                                                                                                         | When field sync is built             |

---

## 5. Verifying the system still works

```bash
# Tests
sf apex run test --target-org MyScratchOrg --test-level RunLocalTests --result-format human
npm run test:unit

# Guest record access must equal Is_Public__c exactly
sf data query -o MyScratchOrg -q "SELECT COUNT() FROM Work_Item__c WHERE Is_Public__c = true"

# Outbound: change a status, expect 2 Integration_Log__c rows and no more
sf data query -o MyScratchOrg -q "SELECT Name, HTTP_Method__c, Status_Code__c FROM Integration_Log__c ORDER BY CreatedDate DESC LIMIT 4"

# Inbound: every event should reach a terminal status, none stuck Pending
sf data query -o MyScratchOrg -q "SELECT Processing_Status__c, COUNT(Id) c FROM Webhook_Event__c GROUP BY Processing_Status__c"

# The public board, as an anonymous visitor
curl -s -o /dev/null -w '%{http_code}\n' https://customization-speed-3039-dev-ed.scratch.my.site.com/neoGeoTest/work-item-board
```

A loop-prevention check: change one `Status__c`, then watch `Integration_Log__c`. It
should gain exactly 2 rows and stop. Climbing by 2 repeatedly means the loop did not
terminate.
