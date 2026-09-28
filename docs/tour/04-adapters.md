# Two adapters behind one interface

Jira and Asana differ in almost every way the integration cares about. Jira sends everything in
the payload and moves status through workflow transitions. Asana sends an id and an action, models
a board column and a completion checkbox as separate things, and names everything by gid. The
interface absorbed both.

Concepts: Named Credentials, untyped JSON in Apex, Asana's batch API, custom metadata as a mapping
table.

<!-- stops:start -->

1. [What does the Jira adapter know that nothing else does?](#1-what-does-the-jira-adapter-know-that-nothing-else-does)
2. [Why is the id `issue.id` and the timestamp `fields.updated`?](#2-why-is-the-id-issueid-and-the-timestamp-fieldsupdated)
3. [How does the adapter tell a cleared date from a missing one?](#3-how-does-the-adapter-tell-a-cleared-date-from-a-missing-one)
4. [Why is an unknown priority left alone instead of cleared?](#4-why-is-an-unknown-priority-left-alone-instead-of-cleared)
5. [Why does the Asana adapter call out while parsing?](#5-why-does-the-asana-adapter-call-out-while-parsing)
6. [Why pair events and gids by position instead of a map?](#6-why-pair-events-and-gids-by-position-instead-of-a-map)
7. [Why map sections by gid and never by name?](#7-why-map-sections-by-gid-and-never-by-name)
8. [Why does the completion checkbox beat the section?](#8-why-does-the-completion-checkbox-beat-the-section)
9. [Why must a mock be as strict as the API?](#9-why-must-a-mock-be-as-strict-as-the-api)
10. [Where do mappings live?](#10-where-do-mappings-live)

<!-- stops:end -->

## 1. What does the Jira adapter know that nothing else does?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | Everything Jira-shaped is confined here -->

[JiraAdapter.cls:4](../../force-app/main/default/classes/JiraAdapter.cls#L4)

The named credential, the `/rest/api/3` paths, the webhook payload's shape, the transitions
envelope, and the tables that map Jira's status and issue type names to Salesforce's. Both
directions read the same tables, so inbound and outbound cannot disagree about what a status means.
Two judgement calls are recorded beside them: Jira's Sub-task maps to Task, because `Type__c` has no
subtask value and a flattening reads better than a blank; and nothing maps to Unspecified on
purpose, so "not mapped" stays distinguishable from a real value.

Those tables are still constants, while Asana's mappings are custom metadata - two mechanisms for
one job, recorded in the handoff as an open item for the next time a Jira mapping changes.

**Pattern: Vendor at the edge.** Jira's paths, payloads and workflow rules live in this class;
above it, a work item is a work item.

**Pattern: One home for each fact.** `normalizeStatus` and the outbound `match` read one table, so a
status added to it is understood in both directions at once.

## 2. Why is the id `issue.id` and the timestamp `fields.updated`?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | Two things are read from the issue, not the envelope. -->

[JiraAdapter.cls:235](../../force-app/main/default/classes/JiraAdapter.cls#L235)

Both come from the issue rather than the webhook's envelope. The id is `issue.id`, numeric and
permanent, never the key (`DOPP-15`), which changes when an issue moves project. The timestamp is
`issue.fields.updated`, when the issue changed, never the envelope's own timestamp, which says when
the event fired - and on a redelivery, that is later than the change it describes.

**Failure mode.** Keyed on the key, a moved issue arrives as a new record. Ordered by the event's
time, a redelivered old state can beat a newer one.

**Pattern: Key on what doesn't change.** Identity and ordering both come from the values the source
guarantees, not the ones that happen to be nearby.

## 3. How does the adapter tell a cleared date from a missing one?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | if (fields.containsKey('duedate')) { -->

[JiraAdapter.cls:325](../../force-app/main/default/classes/JiraAdapter.cls#L325)

Jira sends a key with a null value when a field is empty, and leaves the key out when the field was
not sent. The adapter carries a date only when its key is present (`containsKey`, not a null
check), so a present null clears the date in Salesforce and an absent key leaves it alone.

A value that is present but is not a real YYYY-MM-DD day is not carried at all, and a log row names
the field and what it said. `IsoDate` is strict on purpose: `Date.valueOf` accepts a date-time and
rolls an impossible day forward. The start date's Jira field id comes from configuration, because
custom field ids differ between Jira sites (`customfield_10015` is this one's).

**Failure mode.** Treating an unreadable date as "none" would clear a date Salesforce holds on the
strength of a value nobody could read.

**Pattern: Absent is not empty.** The same two states the `InboundChange` type keeps apart are
read apart here, at the source.

## 4. Why is an unknown priority left alone instead of cleared?

<!-- at: force-app/main/default/classes/JiraAdapter.cls | Three outcomes, and the difference between the last two is the point: -->

[JiraAdapter.cls:409](../../force-app/main/default/classes/JiraAdapter.cls#L409)

Priority is mapped by id, with three outcomes decided before the processor sees anything. A mapped
id is carried as its value. Jira's en dash - the stand-in a Jira issue needs, since it cannot be
without a priority - or an explicit null is carried as blank and clears the field. An id no row
maps is not carried: `Priority__c` keeps what it holds, and a log row names the id.

**Failure mode.** Clearing on an unknown id would read as somebody removing the priority. Failing
would cost the delivery the rest of its change, a status move included.

**Pattern: Name every case.** "Unknown" and "none" look alike from far away and lead to opposite
writes, so the comment lists all three outcomes before the code handles them.

## 5. Why does the Asana adapter call out while parsing?

<!-- at: force-app/main/default/classes/AsanaAdapter.cls | The difference from Jira that shapes this class -->

[AsanaAdapter.cls:9](../../force-app/main/default/classes/AsanaAdapter.cls#L9)

Asana's events name a resource and an action and carry nothing else - not the title, not the
section, not whether the task is finished. So `parseInbound` hydrates: it collects the distinct task
gids a batch mentions and fetches them through Asana's batch endpoint, ten tasks per request.

This is why the interface takes a batch. Two events about one task are one fetch, and fifty tasks
are five callouts rather than fifty. A task the fetch did not reach - the callout budget ran out, or
one slice failed - comes back with no change, which the processor reads as "leave it staged" for a
later run. An event about anything but a task comes back with nothing too, and the sweeper retires
it. The tracked projects are read before the first callout: a query is not DML, and it is the only
way to know which of a task's memberships to read.

**Pattern: Design to the limit.** Deduplicate, then batch, then stop cleanly at the budget and leave
the rest for the next run.

## 6. Why pair events and gids by position instead of a map?

<!-- at: force-app/main/default/classes/AsanaAdapter.cls | Parallel lists rather than a map keyed on Webhook_Event__c.Id. -->

[AsanaAdapter.cls:151](../../force-app/main/default/classes/AsanaAdapter.cls#L151)

Events and the task gids read from them are kept in two parallel lists, not a map keyed on the
event's Id. An unsaved row has no Id, and a map keyed on null answers every event with the same
task.

**Failure mode.** That is how an unreadable delivery once came back carrying another task's change.

**Pattern: Key on what doesn't change.** A record's Id does change - from nothing to something, when
it is inserted - so it is not a key until then. Position is the key that always exists here.

## 7. Why map sections by gid and never by name?

<!-- at: force-app/main/default/classes/AsanaAdapter.cls | Keyed on the gid and never on the section name -->

[AsanaAdapter.cls:113](../../force-app/main/default/classes/AsanaAdapter.cls#L113)

Status comes from the section's gid, type from the chosen option's gid on the project's Format
field, and priority from the Priority field - found by the field's own gid - and then its option's
gid. Names are kept only where a person reads them: in log rows, and in `Source_Type__c`.

**Failure mode.** A mapping keyed on a name silently stops matching the day somebody retitles a
column, and nothing notices until the board is wrong.

**Pattern: Key on what doesn't change.** A gid survives a rename. An unmapped gid lands on
Unspecified, with a log row saying which gid to map.

## 8. Why does the completion checkbox beat the section?

<!-- at: force-app/main/default/classes/AsanaAdapter.cls | The completion flag overrides the section -->

[AsanaAdapter.cls:196](../../force-app/main/default/classes/AsanaAdapter.cls#L196)

A completed task is Done whatever section it sits in. Asana's checkbox is independent of sections
and is the easiest way to finish something in its UI: it strikes the task through without moving
the card. On the way out, a status change writes both - the section move and the completion flag -
so Salesforce never authors the contradiction itself.

The same care applies to projects: a task can sit in several projects with a different section in
each, so the adapter reads only the membership for a project this org tracks.

**Failure mode.** Without the rule, ticking the box finishes a task in Asana while the board keeps
showing it In Progress, and nothing says why.

**Pattern: Vendor at the edge.** Asana's two representations of "done" are reconciled here, and
everything above the adapter sees one status.

## 9. Why must a mock be as strict as the API?

<!-- at: force-app/main/default/classes/AsanaAdapter.cls | it refuses it as a 400 INSIDE an otherwise 200 response -->

[AsanaAdapter.cls:41](../../force-app/main/default/classes/AsanaAdapter.cls#L41)

Asana's batch endpoint refuses a query string inside an action's path, and refuses it as a 400
inside an otherwise 200 response. So the fields go in each action's `options.fields`, and
`readBatch` checks every action's own status code rather than the envelope's.

**Failure mode.** The test mock read the gid out of the path and answered happily whatever else was
in it, so the suite passed while every task in every live batch failed. It was found against the
live API.

**Pattern: Test the path production takes.** A mock that accepts what the real service refuses
proves the code agrees with the mock, not with the service.

## 10. Where do mappings live?

<!-- at: force-app/main/default/classes/FieldMappingService.cls | Vendor value mappings, read in both directions from one table. -->

[FieldMappingService.cls:2](../../force-app/main/default/classes/FieldMappingService.cls#L2)

In `Field_Mapping__mdt`, read in both directions through this class: an Asana section gid to a
`Status__c` on the way in, the `Status__c` back to the gid on the way out. Four mapping types:
Status, Type, Field (which vendor field holds a Salesforce field, such as Jira's start date), and
Priority, where a `Maps_To_Blank__c` row stands for a vendor's "none".

`normalizedFor` returns null rather than a fallback, because what an unmapped value should become
differs by field and is the caller's decision; `isMapped` tells "maps to blank" from "maps to
nothing". The records deploy with the code - since build 08 every custom metadata record is in
source except the secrets.

**Concept.** A custom metadata type is a table of configuration records that deploys with the code,
as metadata rather than data, so the same rows reach every org the source reaches - and a test
cannot insert one.

**Failure mode.** Two tables drift, and drift shows as a task that moves on the board and then moves
back.

**Pattern: Configuration, not code.** Gids and custom field ids differ between workspaces and sites,
so they are rows, not constants.

**Pattern: One home for each fact.** One table, both directions.

<!-- nav:start -->

---

[← 3 · Inbound: a webhook becomes a record](03-inbound.md) · [All tours](README.md) · [5 · The public boundary →](05-public-boundary.md)

<!-- nav:end -->
