# Deploying to an org

`scripts/build-org.mjs` builds this project into an org that has never held it, or brings one up to
date: the app, the Experience Cloud site, the guest's access, the scheduled jobs, and either a copy
of the scratch org's records or a fresh start. The scratch org itself is still built the scratch
way (`sf project deploy start`, see the README); this is for everything else.

```bash
# Plan: stage the build and say what each stage would do. Changes nothing.
node scripts/build-org.mjs <target>

# Validate: a check-only deploy of what the org can take today. Changes nothing.
node scripts/build-org.mjs <target> --validate

# Build it. Resume at any stage with --from=<stage>.
node scripts/build-org.mjs <target> --deploy
node scripts/build-org.mjs <target> --deploy --from=guest
```

## Targets

A target is a file in `build/targets/`, named on the command line without `.json`. **Targets are
not committed**: they name real orgs, Jira sites and projects, and a copy target pulls in records, so
`.gitignore` keeps every `build/targets/*.json` on the machine that runs it. Only the
`*.example.json` templates are shared. Start from `fresh.example.json`:

```bash
cp build/targets/fresh.example.json build/targets/my-org.json
```

A **fresh** target starts empty: no records, only the projects it lists, and its own webhooks and
tokens. A **copy** target imports the projects and work items of another org the CLI is connected
to, and syncs against the same Jira site and Asana workspace, so it keeps the repo's mapping rows:

```json
{
  "org": "<target alias>",
  "jiraBaseUrl": "https://<your-site>.atlassian.net",
  "siteEmailSender": null,
  "customMetadata": null,
  "data": { "mode": "copy", "from": "<source alias>" }
}
```

| Setting           | Meaning                                                                                                                                                                                         |
| ----------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `org`             | The CLI alias or username of the target.                                                                                                                                                        |
| `jiraBaseUrl`     | Written into `Jira_Classic`'s URL. Every Jira callout goes there.                                                                                                                               |
| `siteEmailSender` | The site's email sender. Null uses the deploying admin's email.                                                                                                                                 |
| `customMetadata`  | Null deploys the repo's mapping rows. A folder path replaces them: every `Field_Mapping` row in the repo is dropped when the folder holds any `Field_Mapping` row, and likewise `Board_Source`. |
| `data.mode`       | `copy` imports the projects and work items of `data.from`. `fresh` creates the projects listed in `data.projects` and nothing else.                                                             |

**A fresh target on another Jira site or Asana workspace needs its own mapping rows.** Section,
option, field and priority ids belong to one Jira site and one Asana workspace (handoff, section 6).
Copy the repo's `customMetadata/Field_Mapping.*` rows into the target's folder, change the ids to the
new systems', and point `customMetadata` at it. `scripts/apex/check-priority-sources.apex` reads the
live priority ids once the credentials work.

## Before the first deploy

1. **Enable Digital Experiences in the target**: Setup > Digital Experiences > Settings > Enable
   Digital Experiences, and save. It cannot be turned off again. A Developer Edition org's site
   domain is fixed (`<org>.develop.my.site.com`), so there is no domain to choose. The build stops
   at its preflight if this is not done.
2. **Connect the CLI** to the target (`sf org login web --alias <alias>`) and, for a copy, to the
   source org.

## What each stage does, and why it is where it is

| Stage     | What                                                                                                                               | Why here                                                                                                                     |
| --------- | ---------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------- |
| `core`    | Objects, Apex, components, permission sets, credentials, custom metadata, the subscriber config.                                   | Everything else names something in it.                                                                                       |
| `access`  | `Portfolio_HQ_Developer` to the deploying admin.                                                                                   | A deploy grants no field access, and the data import and the tests need it.                                                  |
| `site`    | The network, both sites, the LWR bundle, navigation, branding.                                                                     | Names Visualforce pages, Apex and components that `core` created.                                                            |
| `guest`   | The guest profile and guest sharing rules, then `Jira_Webhook_Guest` and `Portfolio_HQ_Guest` to the guest.                        | The guest user is created with the site. Its nickname is read from the org and written into the sharing rules.               |
| `data`    | `copy`: projects, then work items in record-number order, then parent links, then the featured epic. `fresh`: the listed projects. | Skipped when the target holds any project or work item, so a rerun never imports twice. Inserts never push to Jira or Asana. |
| `jobs`    | The inbound sweeper (four schedules) and the nightly purge.                                                                        | Scheduled as the deploying admin, who now holds the Asana credential grant the sweeper's callouts use (handoff, section 1).  |
| `publish` | Publishes the site.                                                                                                                | An LWR site serves the bundle it was last published with.                                                                    |
| `tests`   | `RunLocalTests`.                                                                                                                   | Last, once the admin has field access and the guest user exists.                                                             |

Deploys run with `NoTestRun`, which a Developer Edition or sandbox allows, and each stage is its own
small SFDX project under `build/.out/<target>/`. `force-app` is never edited: the values that bind
metadata to one org are rewritten in the staged copy, and each rewrite must match exactly what it
expects or the run stops.

| Rewritten in the staged copy                                                             | With                                                                                      |
| ---------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `sites/Test_Professional_Site`: site admin, guest record default owner                   | the deploying admin                                                                       |
| `PlatformEventSubscriberConfigs/Webhook_Event_Subscriber`: running user                  | the deploying admin                                                                       |
| `networks/Test Professional Site`: email sender                                          | `siteEmailSender`, or the admin's email                                                   |
| `namedCredentials/Jira_Classic`: URL                                                     | `jiraBaseUrl`                                                                             |
| `sharingRules/*`: guest user                                                             | the target's guest nickname                                                               |
| `profiles/Test Professional Site Profile`: Account field, layout and record type entries | removed: the Account customisations are not deployed, and the guest never reaches Account |

**Not deployed**, though in source: the scratch org template's leftovers (the B2B buyer profile,
partner reports, dashboards and report types, the report-export security policy, the `Developer`
role, the app menu), the early Account fields, record types and layouts, and the `Admin` profile,
whose field access `Portfolio_HQ_Developer` provides instead. `manifest/build-08/destructiveChangesPost.xml`
is not needed either: it removes card bundles an org only has if it held build 07.

## After the build

The build ends by writing `build/.out/<target>/checklist.md`, with the target's own URLs filled in.
None of it is metadata:

1. The Jira API token on `Jira_Token`'s **Personal Key** principal, and the Asana personal access
   token on `Asana_Token`'s **PAT1** principal.
2. The Jira webhook, pointed at the target's REST site, and its secret as an `Integration_Secret__mdt`
   record named `Jira_Webhook`.
3. The Asana webhook per tracked project, then `promote-webhook-secret.apex` against the target.
4. A round trip each way. If deliveries stay Pending, suspend and resume the subscription on the
   Webhook Event Received platform event: a subscriber config takes effect only when the subscriber
   restarts (handoff, section 3).
5. For a copy: the source org's webhooks still point at the source org. Disable the Jira one.

Tokens and webhook secrets are never copied, in either mode: each org gets its own.

## Known differences from the scratch org

- **Record numbers can change in a copy.** Work items are inserted in record-number order, so a
  source with no gaps keeps its numbers; the build prints any that moved. The audit and capture
  scripts name the scratch org and `WI-0000`: point `AUDIT_ORG` and `FEATURED` at the target's.
- **Owners.** Every copied record is owned by the deploying admin, which is what guest sharing needs.
- **Assignees** are users of the source org and are not copied.
