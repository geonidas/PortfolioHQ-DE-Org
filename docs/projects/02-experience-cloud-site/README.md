# 02 · Experience Cloud site

**Status: built, with a portfolio home page in progress.** The site and its guest security are
built and serve [project 01](../01-workflow-board/README.md)'s public board. The portfolio home page
is on branch `portfolioSite`, staged on the scratch org with placeholder content; it is not on the
Developer Edition org yet.

The public face of [Portfolio HQ](../../../README.md): the site anyone can visit without logging in,
which will grow into a hub of projects, case studies and an Agentforce tour guide.

## What is built

- **An LWR site, source-controlled as a DigitalExperienceBundle**
  (`force-app/main/default/digitalExperiences/site/Test_Professional_Site1`), hosting the public
  board at `/neoGeoTest/work-item-board`. The one-command org build deploys and publishes it like
  everything else ([docs/deploying-to-an-org.md](../../deploying-to-an-org.md)).
- **A second, Salesforce Sites host** (`Test_Professional_Site`, `/neoGeoTestvforcesite`) that
  serves only the Jira and Asana webhook endpoints. Both sites share one guest user.
- **Guest security**, as properties of the code rather than settings that have to stay right:
  - The guest holds custom-object permissions only: read on `Project__c` and `Work_Item__c` for the
    board, create on the webhook staging objects for the endpoints. `GuestAccessTest` pins that
    reach, standard objects and private work item fields included.
  - It reads through Apex that returns DTOs, never records or ids: `PublicBoardController` and
    `PublicWorkItemSelector`, whose WHERE clause is the only enforcement of a project's
    `Is_Public__c`.
  - The DTOs are a whitelist. `PublicBoardControllerTest` asserts their key sets exactly, so adding
    anything an anonymous visitor receives fails a test until it is made on purpose.
  - It is verified logged out. Tests run as the site guest, and `scripts/audit-public-board.mjs`
    checks the live board as an anonymous visitor: axe-core over the states a visitor can put it
    in, and a keyboard walkthrough, at desktop width and on a 375px phone.

The guest posture was built during project 01's builds 05-10, so its reasoning lives there:
[ADR build 05](../01-workflow-board/adr/build-05-guest-board.md) and the code tour's
[public boundary](../01-workflow-board/tour/05-public-boundary.md).

## In progress: the portfolio home page

A project showcase that replaces the site's stub Home page, for linking from a résumé and LinkedIn:
each project shown running, with a label for how far a visitor can go - interactive, view, video or
screenshots. The board stays where it is.

- **Pure front end.** `portfolio*` Lightning Web Components and one static resource: no Apex, no
  object, no guest permission. A Jest test fails if a portfolio bundle imports anything else, which
  is also why a demo is a link and not the board embedded in the page.
- **One content file.** Everything the page says is `lwc/portfolioContent/portfolioContent.js`, and
  a content test guards it: safe links only, every picture present with real alt text, and no live
  label without a demo link.
- **Where it stands.** Committed step by step on `portfolioSite` and staged on the scratch org with
  placeholder content. Next: the real content; the page's title, favicon and link-preview tags;
  then the Developer Edition org.

Org state, invariants and traps for the page are in [the handoff](../../handoff.md), section 7; the
two sites and their shared guest user are in section 1.

## Next

The site is meant to grow past its home page, into more about each project and, later, a guide that
answers visitors' questions. Each step gets its own plan when it starts.

## In this folder

This overview, so far. The portfolio page's ADR and build summary go in `adr/` and
`build-summaries/` here when its build closes, and a code tour, if it gets one, in `tour/`.
