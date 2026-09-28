# The public boundary

Anyone with the link sees a board of the work flagged public. This tour is about why that visitor
can read only what was chosen for them and can do nothing else - as properties of the code, rather
than settings that have to stay right.

Concepts: Experience Cloud (LWR) sites and the guest user, Apex class access and `@AuraEnabled`,
`with sharing` and `USER_MODE`, guest sharing rules, DTOs, custom settings and custom permissions.

<!-- stops:start -->

1. [Why is there a second controller?](#1-why-is-there-a-second-controller)
2. [Why does the public read take no parameters?](#2-why-does-the-public-read-take-no-parameters)
3. [Where is `Is_Public__c` actually enforced?](#3-where-is-is_public__c-actually-enforced)
4. [Why do DTOs cross the wire instead of records?](#4-why-do-dtos-cross-the-wire-instead-of-records)
5. [Why assert the payload's key set exactly?](#5-why-assert-the-payloads-key-set-exactly)
6. [How is the guest's field access pinned?](#6-how-is-the-guests-field-access-pinned)
7. [Why does one query per visitor matter?](#7-why-does-one-query-per-visitor-matter)
8. [How does the visitor learn which epic is featured without an id?](#8-how-does-the-visitor-learn-which-epic-is-featured-without-an-id)
9. [Why is `Is_Public__c` a read gate and nothing else?](#9-why-is-is_public__c-a-read-gate-and-nothing-else)
10. [Why is the featured epic a setting and not a field?](#10-why-is-the-featured-epic-a-setting-and-not-a-field)
11. [Why is the setting written in system mode?](#11-why-is-the-setting-written-in-system-mode)

<!-- stops:end -->

## 1. Why is there a second controller?

<!-- at: force-app/main/default/classes/PublicBoardController.cls | Separate from WorkItemBoardController because Apex class access is granted per class -->

[PublicBoardController.cls:4](../../force-app/main/default/classes/PublicBoardController.cls#L4)

Apex class access is granted per class, not per method. Any user who can reach a class can call
every `@AuraEnabled` method on it from the browser, whatever the page renders - so a guest who
could reach `WorkItemBoardController` could call `changeStatus`. `PublicBoardController` has no
write method at all, which makes the public board read-only in its code rather than in a
permission. A test reads the guest permission set's class grants and requires exactly one: this
class.

**Concept.** An `@AuraEnabled` method is an endpoint. The components on a page decide what gets
called in normal use; they do not decide what can be called.

**Failure mode.** A single controller with a "read-only mode" is one mistaken grant, or one
forgotten check, away from letting an anonymous visitor move cards in Jira.

**Pattern: Safe by construction.** The write the guest must never make does not exist anywhere the
guest can reach.

## 2. Why does the public read take no parameters?

<!-- at: force-app/main/default/classes/PublicBoardController.cls | public static PublicBoardData getPublicBoardData() { -->

[PublicBoardController.cls:29](../../force-app/main/default/classes/PublicBoardController.cls#L29)

One method, no arguments: nothing a client sends can change what comes back, so there is nothing to
validate, widen or mis-default. Both views ship in the one call, and the board's view toggle,
source filter and sort only re-render what it already holds. An error becomes one fixed sentence,
so query and field names never reach a browser.

The internal selector shows why: it takes a project scope and treats a blank one as "everything" -
right on an internal page, fail-open on a public one. A test calls this method with no arguments,
so adding a parameter breaks it at compile time.

**Pattern: Safe by construction.** An argument that cannot be sent cannot be abused.

## 3. Where is `Is_Public__c` actually enforced?

<!-- at: force-app/main/default/classes/PublicWorkItemSelector.cls | WHERE Is_Public__c = TRUE AND Project__r.Is_Public__c = TRUE -->

[PublicWorkItemSelector.cls:58](../../force-app/main/default/classes/PublicWorkItemSelector.cls#L58)

In this WHERE clause: the item's flag and its project's flag, written into the query text rather
than composed from parameters. The guest sharing rules also gate on the item's own flag, but a
criteria-based sharing rule cannot reference a parent's field, so the project's flag is enforced
here and nowhere else. Any future guest-reachable class that reads `Work_Item__c` inherits that
duty.

`WITH USER_MODE` makes a missing guest grant throw instead of quietly returning more, and the field
list leaves out the description, assignee and URL, so no later change to a DTO can send them.

**Concept.** Sharing rules decide which records a user can see at all; a query's WHERE clause
narrows that further. Only the second can look at a related record's field.

**Failure mode.** Relying on the sharing rules alone would show a public item under a private
project. The seed data plants exactly such a record as a canary (tour 7).

**Pattern: Fail closed.** No code path produces an unfiltered result, and a missing permission is
an error rather than a wider answer.

## 4. Why do DTOs cross the wire instead of records?

<!-- at: force-app/main/default/classes/PublicBoardController.cls | public class PublicCard { -->

[PublicBoardController.cls:174](../../force-app/main/default/classes/PublicBoardController.cls#L174)

What an anonymous visitor receives is a class, not a record. An SObject carries every queried field
to the browser; a DTO carries only the properties it declares, so adding a field to the query
publishes nothing.

The same care runs through the mapping: no Salesforce ids, with the auto number as the key; the
project's short name with no fallback to its internal name; a parent named only when the parent is
itself public, because telling a visitor that a hidden record exists is a small leak with no upside;
and the Unspecified type sent as null, so the client never learns the sentinel.

**Pattern: Safe by construction.** Publishing a field takes a declared property, a line of mapping
and a test change - there is no way to do it by accident.

## 5. Why assert the payload's key set exactly?

<!-- at: force-app/main/default/classes/PublicBoardControllerTest.cls | static void theDtoCarriesExactlyTheAgreedFieldsAndNoOthers() { -->

[PublicBoardControllerTest.cls:461](../../force-app/main/default/classes/PublicBoardControllerTest.cls#L461)

The test serialises a card and compares its keys with an exact set - an allow-list, not a list of
banned fields. Adding a property fails it, so publishing something new to an anonymous visitor is a
decision somebody makes, with the test failing first and naming the new key. Each entry carries the
build and step that added it, and a removal is recorded the same way. A second test bans an `"Id"`
key and named private fields outright.

**Failure mode.** A block-list only catches the fields someone thought to list; the field nobody
thought about is the one that leaks.

**Pattern: Pin the contract exactly.** The set is the contract, so the test asserts the whole set.

**Pattern: Watch the test fail.** Every addition to the list was made after seeing this test fail
for it.

## 6. How is the guest's field access pinned?

<!-- at: force-app/main/default/classes/GuestAccessTest.cls | static void theBoardGuestReadsExactlyTheseFields() { -->

[GuestAccessTest.cls:87](../../force-app/main/default/classes/GuestAccessTest.cls#L87)

The same idea, one layer down. The test reads the guest permission set's field grants from the org
and compares them with an exact list, and requires that the guest can edit nothing. Granting the
guest a field now fails this test and the DTO key-set test together.

These tests read the grants rather than running as the guest, because a freshly built scratch org
may have no site and so no guest user; a runtime check runs as well when one exists.

**Failure mode.** Before build 08, the suite only forbade four named fields, so a new grant failed
nothing.

**Pattern: Pin the contract exactly.** What the guest may read is a set, asserted whole.

## 7. Why does one query per visitor matter?

<!-- at: force-app/main/default/classes/PublicBoardControllerTest.cls | static void twoHundredPublicRecordsCostOneQuery() { -->

[PublicBoardControllerTest.cls:654](../../force-app/main/default/classes/PublicBoardControllerTest.cls#L654)

Two hundred public records cost one SOQL query. The epic ancestry, child counts, the cap on
completed epics and the featured epic are all worked out in memory from the rows that one query
returned (`EpicRollup`). Per-source rules come from custom metadata through `getAll()`, the
priority order from a describe, and the featured epic from a cached custom setting - none of which
is a query.

**Failure mode.** A query per epic or per card puts the page one busy project away from the governor
limit, and a Developer Edition site has ten minutes of server time a day. The count was also checked
live, as the guest, with a trace flag - a run as the owner proves nothing about what the guest
costs (the recipe is in the handoff).

**Pattern: Design to the limit.** The budget is one query, and everything else is arranged to fit
in it.

**Pattern: Pin the contract exactly.** The query count is asserted as a number, so a change that
adds a second query fails.

## 8. How does the visitor learn which epic is featured without an id?

<!-- at: force-app/main/default/classes/PublicBoardController.cls | card.inFeaturedEpic = rollup.inFeaturedEpic(record.Id); -->

[PublicBoardController.cls:152](../../force-app/main/default/classes/PublicBoardController.cls#L152)

As answers. The featured epic's card says `isFeatured`, and every card says whether it rolls up
into an epic (`inEpic`) and whether that epic is the featured one (`inFeaturedEpic`). Apex works
these out against the rows the visitor's own query returned, so an epic the visitor cannot see is
treated as none, and the client never walks a hierarchy.

Publishing the featured epic's Salesforce Id was the first proposal, and it was declined at the
design step: no public DTO carries an id, and the key-set test bans one.

**Pattern: Send answers, not inputs.** The client gets the decision it needs to render, not the raw
data it would have to interpret - and raw data is exactly what should not reach an anonymous
browser.

## 9. Why is `Is_Public__c` a read gate and nothing else?

<!-- at: force-app/main/default/classes/WorkItemTriggerHandler.cls | Is_Public__c WAS A CONDITION ON PUSHING -->

[WorkItemTriggerHandler.cls:150](../../force-app/main/default/classes/WorkItemTriggerHandler.cls#L150)

The flag answers one question: may an anonymous visitor read this record. It says nothing about who
may write it; object and field permissions govern that.

**Failure mode.** In build 07 step 8, `item.Is_Public__c != true` was added to the push condition,
to make sync inbound-only for anything on public display. It silently made every item on the public
board read-only from the internal board - Jira's included, with no error anywhere - on exactly the
records the project exists to show. Step 9 removed it, and two tests now fail if it comes back.

**Pattern: One flag, one meaning.** The comment block stays in the class, in capitals, because the
change looked reasonable and the damage was invisible.

## 10. Why is the featured epic a setting and not a field?

<!-- at: force-app/main/default/classes/FeaturedEpicService.cls | A setting rather than a field on Work_Item__c -->

[FeaturedEpicService.cls:6](../../force-app/main/default/classes/FeaturedEpicService.cls#L6)

The featured epic is the org default of a hierarchy custom setting holding one Id - so there is one
by construction - rather than a flag on the work item. Featuring an epic is then never a work item
edit: the trigger does not run, nothing is staged, nothing is pushed to Jira. The setting is read
from the application cache, so both boards resolve it without a query.

What can be featured is one rule, applied when it is set and again when it is read: an epic that is
public, under a public project. One that stops qualifying reads as none rather than being cleared.
Who may set it is checked in the controller against a custom permission; the button being hidden is
presentation.

**Concept.** A custom setting is cached configuration data; a custom permission is a named
capability granted through permission sets and checked in code.

**Pattern: Attach the side effect to the change.** Seen from the other side: where the state lives
decides which side effects fire, so choosing a setting over a field is choosing that featuring an
epic pushes nothing.

**Pattern: The server holds the rule.** The controller refuses a user without the permission,
whatever the page shows them.

## 11. Why is the setting written in system mode?

<!-- at: force-app/main/default/classes/FeaturedEpicService.cls | Database.insert(setting, AccessLevel.SYSTEM_MODE); -->

[FeaturedEpicService.cls:253](../../force-app/main/default/classes/FeaturedEpicService.cls#L253)

Plain DML on a custom setting is checked against the running user, even in Apex, and refused for
anyone who cannot customise the application - from a `without sharing` class too, and with the
setting granted in a permission set. Only an explicit `AccessLevel.SYSTEM_MODE` writes it. The
authorisation is the custom permission the controller checks; no user is granted the setting itself.

**Failure mode.** Every test in the step that built the service ran as the admin, which passes
either way. The first test run as a Standard User holding the project's permission set found it.

**Pattern: Test as the real user.** A check made as the admin passed for the wrong reason.

**Pattern: Know who your code runs as.** Custom objects and custom settings answer the same DML
differently for the same user, and only the running user reveals it.

<!-- nav:start -->

---

[← 4 · Two adapters behind one interface](04-adapters.md) · [All tours](README.md) · [6 · Two boards, one set of parts →](06-boards.md)

<!-- nav:end -->
