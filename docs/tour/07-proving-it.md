# Proving it: tests and operations

How the claims in the other tours are held true. Most of the silent failures this project guards
against come not from wrong logic but from a check made in the wrong conditions: as the wrong user,
through the wrong entry point, against a mock looser than the real service, or with an assertion
that could not fail. This tour is about those conditions, and about the operational habits that keep
the org and the repository in agreement.

Concepts: `System.runAs`, `Test.startTest` and `Test.stopTest` with governor limits, custom metadata
in tests, seed data, scheduled jobs, source tracking.

<!-- stops:start -->

1. [Why do some tests run as the site guest?](#1-why-do-some-tests-run-as-the-site-guest)
2. [Why is there a test just for the async hop?](#2-why-is-there-a-test-just-for-the-async-hop)
3. [How can a test prove that no callout was made?](#3-how-can-a-test-prove-that-no-callout-was-made)
4. [How are metadata-driven rules tested when a test can't insert metadata?](#4-how-are-metadata-driven-rules-tested-when-a-test-cant-insert-metadata)
5. [Why does the seed data plant a canary?](#5-why-does-the-seed-data-plant-a-canary)
6. [Why does the nightly purge never touch a Pending delivery?](#6-why-does-the-nightly-purge-never-touch-a-pending-delivery)
7. [Why deploy freely but retrieve through a narrow manifest?](#7-why-deploy-freely-but-retrieve-through-a-narrow-manifest)
8. [What carries over to the next project?](#8-what-carries-over-to-the-next-project)

<!-- stops:end -->

## 1. Why do some tests run as the site guest?

<!-- at: force-app/main/default/classes/AsanaWebhookResourceTest.cls | static void theGuestCanActuallyWriteTheRowsThisEndpointRecords() { -->

[AsanaWebhookResourceTest.cls:415](../../force-app/main/default/classes/AsanaWebhookResourceTest.cls#L415)

Apex runs in system mode for every user but one: for the site guest, field-level security is
enforced on DML. `AsanaWebhookResource` once set a `Webhook_Event__c` field that the guest's
permission set did not grant, so every rejection and handshake row failed to insert - silently,
because the code caught the failure - while the endpoint still answered correctly. A test run as
the admin passes either way. This one finds the site guest and posts inside `System.runAs`, then
asserts the row exists.

**Concept.** `System.runAs(user)` runs a block of test code as that user, with their permissions and
sharing.

**Failure mode.** Build 07 had three defects of this shape - the guest's field-level security on
inbound DML, the callout from a trigger, and the subscriber's credential - each of which passed a
hand-run check from anonymous Apex, which runs as whoever runs it. Build 10 found a fourth, in the
custom setting write (tour 5).

**Pattern: Test as the real user.** The test's value is entirely in who it runs as.

## 2. Why is there a test just for the async hop?

<!-- at: force-app/main/default/classes/WorkItemInboundQueueableTest.cls | static void theSubscriberEnqueuesRatherThanApplyingInline() { -->

[WorkItemInboundQueueableTest.cls:26](../../force-app/main/default/classes/WorkItemInboundQueueableTest.cls#L26)

Every other inbound test calls `WorkItemInboundProcessor.process` directly, which is a good way to
test what processing does and no way at all to find out whether processing can run where it
actually runs. This test drives the subscriber's entry point and asserts that it enqueues rather
than applying the batch inline.

The endpoint tests have the mirror-image problem: a queueable enqueued while `Test.stopTest()`
delivers a platform event does not run, so `JiraWebhookResourceTest` drives the second half itself
with a `drainStagedDeliveries()` helper. The async boundary is real, not an artefact of the tests,
and each side of it is tested from its own entry point.

**Failure mode.** The first live Asana delivery failed with `Callout from triggers are currently not
supported` while the whole suite was green (tour 3).

**Pattern: Test the path production takes.** A test that enters below the real entry point skips
exactly the constraints the entry point brings.

## 3. How can a test prove that no callout was made?

<!-- at: force-app/main/default/classes/AsanaWebhookResourceTest.cls | // Both readings inside the window: Test.stopTest restores the outer limits context -->

[AsanaWebhookResourceTest.cls:349](../../force-app/main/default/classes/AsanaWebhookResourceTest.cls#L349)

By taking both readings inside the test window. `Test.stopTest()` restores the limits context that
was in force before `Test.startTest()`, so a `Limits.getCallouts()` reading taken after it reports
the outer transaction, not the code under test - and an assertion comparing it with an earlier
reading passes even when a callout was made. It was found by breaking such a test on purpose, which
is the only reason it was found at all.

The JavaScript side has its own version: Jest's `toEqual` ignores `undefined` entries in an array,
so a test that maps elements to an attribute and compares the list is blind to exactly the element
that lacks it. Such lists are compared with `toStrictEqual`.

**Pattern: Watch the test fail.** An assertion that has never been seen failing may be one that
cannot.

## 4. How are metadata-driven rules tested when a test can't insert metadata?

<!-- at: force-app/main/default/classes/FieldMappingService.cls | private static List<Field_Mapping__mdt> injected; -->

[FieldMappingService.cls:37](../../force-app/main/default/classes/FieldMappingService.cls#L37)

Custom metadata records cannot be created by DML, so every class that reads them has a
`@TestVisible` seam a test can fill instead: `FieldMappingService`, `BoardSourceRules`,
`IntegrationSecretService` and `WebhookSecretStore`. The same approach covers other things a test
cannot set up honestly, such as the count of push jobs in flight (`assumeOtherPushesInFlight`) and
the Asana projects the org tracks.

With nothing injected, these classes read the org's live metadata, so org data can change what a
test measures. Deploying the real Asana status mappings made a test that used `asana:` as its
example of an unregistered system pass an item it had always rejected. It uses `trello:` now, and a
test that asserts "no mapping exists" injects an empty table rather than assuming the org has none.

**Pattern: Control what the test reads.** A test states its own world, so the org it runs in cannot
quietly change the answer.

## 5. Why does the seed data plant a canary?

<!-- at: scripts/apex/flag-public-demo-data.apex | External_Key__c = 'SEED-CANARY', -->

[flag-public-demo-data.apex:128](../../scripts/apex/flag-public-demo-data.apex#L128)

The demo-data script flags some work public, shapes it into an epic hierarchy, and plants one record
that must never render: a work item flagged public under a private project, owned by a real user so
that sharing genuinely grants the row. If the canary ever appears on the public board, the only
enforcement of the project's flag - the selector's WHERE clause - has gone.

The seed is deliberately partial, so "no private record leaks" is something a person can check. It
never changes an existing record's `Status__c`, because a status change on a record with an
external id pushes to live Jira, and the canary has no external id at all, so it can never be pushed
however it is later edited.

**Pattern: Surface, don't drop.** The failure it guards against produces no error, so the seed
makes it visible instead.

## 6. Why does the nightly purge never touch a Pending delivery?

<!-- at: force-app/main/default/classes/IntegrationDataPurge.cls | WHAT IT WILL NOT DELETE. -->

[IntegrationDataPurge.cls:23](../../force-app/main/default/classes/IntegrationDataPurge.cls#L23)

Each night, `Webhook_Event__c` and `Integration_Log__c` are cut to their 50 most recent rows and
hard-deleted from the recycle bin. A delivery still Pending is work in progress, not history, so it
is excluded from both halves: the delete, and the count that sets the cutoff. Rows sharing the
cutoff's timestamp all survive, so ties keep more, never fewer.

The class names its cost too: rejected-signature rows, the only record that unauthenticated traffic
reached the endpoint, age out like everything else until version 2 archives them first.

**Failure mode.** Excluding Pending rows from the delete alone lets stuck rows push the same number
of real rows under the cutoff - so if the sweeper stopped, the purge would erode the history of an
outage just when it was worth reading. It was written that way first, and
`pendingRowsAreKeptOnTopOfTheCapNotInsteadOfIt` caught it.

**Pattern: Bound everything that grows.** Both audit tables have a ceiling, and the ceiling is
applied only to what is finished.

**Pattern: Watch the test fail.** The test for the subtle half existed before the subtle half was
right.

## 7. Why deploy freely but retrieve through a narrow manifest?

<!-- at: manifest/org-changes.xml | Deliberately excludes ApexClass -->

[org-changes.xml:6](../../manifest/org-changes.xml#L6)

Source that lives in git travels one way, local to org. This manifest retrieves only declarative
metadata changed in Setup, and deliberately leaves out Apex, LWC, site JSON and profiles.

The pre-commit hook formats staged files with Prettier, so the repository holds Prettier's
formatting while the org holds the bytes that were deployed. A full retrieve drags the org's
formatting back over the repository's and reports sixty-odd changed files of pure churn, in which a
real change is easy to miss. Reasons for a metadata choice go in a `<description>` element rather
than an XML comment, because a retrieve strips comments.

**Pattern: One home for each fact.** Each artefact has one canonical home - git for code, the org
for clicks made in Setup - and it only ever travels out of that home.

## 8. What carries over to the next project?

Thirty patterns recur across the tours. Each stop names the ones it is an instance of; here they
are together, grouped, each stated as the rule it is. The [index](README.md#patterns) lists every
stop where each one appears.

<!-- patterns:define -->

**Moving data between systems**

- **Stage, then act.** Record what has to happen where it is cheap and transactional, then do the slow, remote or privileged part later, from that record.
- **Attach the side effect to the change.** Hang a consequence on the data changing, not on one caller's code path, so every way of making the change gets it exactly once.
- **Deltas, not snapshots.** Send and write back only what changed, worked out against the current state, so edits made elsewhere in the meantime survive.
- **Remote calls before local writes.** Make every network call a unit of work needs before its first local write, and keep what you want to record about those calls in memory until then.
- **Absent is not empty.** Keep "not sent" and "sent as empty" as two different values in every payload, argument and DTO.
- **Make replays harmless.** Assume deliveries repeat, arrive late or arrive out of order, and decide from current state and the source's own timestamps, never from the order of arrival.
- **One guard per path.** Where several mechanisms protect against one failure, know which path each one closes, so none is ever removed as a duplicate.
- **One owner per piece of work.** Decide which job or edit owns each piece of work, so two workers never both do it or undo each other.

**Boundaries and trust**

- **Vendor at the edge.** Third-party vocabulary stops at an adapter, and everything above it speaks the domain's own terms.
- **Send answers, not inputs.** Give a client the decision it needs to render - a label, a flag, a rank - rather than raw data it would have to interpret.
- **Safe by construction.** Make the forbidden action impossible to express - no write method, no parameter, no id, no import - rather than forbidden by a setting.
- **Fail closed.** A missing secret, a failed lookup or any doubt means refuse or hide, never skip the check.
- **The server holds the rule.** Hiding a control is presentation; enforce the rule where every path passes, such as a trigger, a controller or a validation rule.
- **Know who your code runs as.** Every entry point runs as some user - a guest, a process user, whoever enqueued or scheduled the job - and permissions, credentials and visibility follow that user.
- **One flag, one meaning.** A field that answers one question must not quietly start answering another, and when one state means two things, add a field that says which.

**State and data**

- **Honest state.** A status claims only what is true: Pending until the other side confirms, Synced only when both agree, and partial success recorded as partial.
- **One home for each fact.** Every rule, mapping, constant and canonical copy lives in exactly one place, and everything else asks it.
- **Key on what doesn't change.** Identify and order records by values that are present and permanent - ids, and the source's own timestamps - never by names, display keys or anything assigned later.
- **Name every case.** When a decision has several outcomes, list them in the code and its comments rather than folding them into one rule that quietly mishandles some.
- **Configuration, not code.** What varies between orgs, sites or workspaces - mappings, field ids, columns, per-source rules - lives in metadata, not in constants.
- **A day is not an instant.** Carry calendar dates as dates or `YYYY-MM-DD` strings, never through a type that has a time zone.
- **Surface, don't drop.** Nothing disappears silently: log the gap, show the card that fits no column, or plant a detector for the failure that raises no error.

**Limits and resilience**

- **Design to the limit.** Know the platform's budgets - callouts, time, queries, server minutes - size the work to them, and check before each unit rather than after.
- **Bound everything that grows.** Chains, retries, walks and tables each get a ceiling, and a loop that makes no progress stops.
- **Answer for the caller's next move.** Choose a response by what its receiver will do with it - retry or not - and give an untrusted caller one answer for every rejection.

**Testing**

- **Pin the contract exactly.** Assert whole sets - payload keys, granted fields, reachable classes, query counts - so any widening fails a test and becomes a decision.
- **Test as the real user.** Run a check as the user the path runs as in production, because a check made as the admin can pass for the wrong reason.
- **Test the path production takes.** Drive the real entry point, against a mock as strict as the real service; a test that bypasses either proves nothing about what runs.
- **Watch the test fail.** See an assertion fail before trusting it to pass, by breaking the code or writing the assertion first; one never seen failing may be unable to.
- **Control what the test reads.** Inject the tables, time zones, counts and configuration a test depends on, so the org or the machine cannot change what it measures.

<!-- nav:start -->

---

[← 6 · Two boards, one set of parts](06-boards.md) · [All tours](README.md)

<!-- nav:end -->
