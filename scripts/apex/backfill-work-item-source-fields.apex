/**
 * Backfill the fields inbound sync fills, for records that predate them.
 *
 *   sf apex run --file scripts/apex/backfill-work-item-source-fields.apex --target-org MyScratchOrg
 *
 * Was backfill-work-item-titles.apex, which filled Title__c from Jira for records that predated
 * the field. Build 08 added Source_Created__c, Start_Date__c, Due_Date__c and inbound
 * descriptions, and a webhook only fills them when an item next changes - which for a finished
 * item may be never. Extended rather than joined by a second script, so there is one backfill.
 *
 * It does not read payloads itself. Each record is fetched from its source and handed to that
 * source's own adapter, exactly as a webhook delivery would be, so a backfilled value is the value
 * the live sync would have written - the configured Jira start date field, the carried-or-empty
 * date rule, the plain-text description. Only then are the new fields copied across:
 *
 *   Title__c            only when blank, as before - a title synced by a webhook is never replaced
 *   Source_Created__c   whenever the source says
 *   Start/Due/Description  whenever carried, INCLUDING clearing them
 *
 * Never Status__c, and never anything else. A status write on a record carrying External_Id__c
 * would transition the live issue, and seeding data is not a request to move work.
 *
 * Every callout happens before any DML, because Apex refuses a callout once DML is pending and
 * there is no second chance in an anonymous block. Jira is fetched through REST v2, whose
 * description is the same plain string a webhook carries; v3 would return a document tree.
 * Asana is hydrated by AsanaAdapter itself, ten tasks per batch call.
 *
 * Run it as a user holding both external credential grants (Jira_Token and Asana_Token-PAT1).
 * Safe to rerun: it writes what the sources say, so a second run changes nothing.
 */
final Integer JIRA_LIMIT = 80; // one callout each; leaves room under 100 for Asana's batches

List<Work_Item__c> items = [
    SELECT Id, Name, External_Id__c, External_System__c, Title__c
    FROM Work_Item__c
    WHERE External_Id__c != null
    ORDER BY Name ASC
    LIMIT 200
];
Map<String, Work_Item__c> itemByExternalId = new Map<String, Work_Item__c>();
List<Webhook_Event__c> jiraRows = new List<Webhook_Event__c>();
List<Webhook_Event__c> asanaRows = new List<Webhook_Event__c>();
List<String> skipped = new List<String>();

String startField = FieldMappingService.externalValueFor(
    ExternalSystem.JIRA,
    FieldMappingService.FIELD,
    String.valueOf(Work_Item__c.Start_Date__c)
);
String jiraFields = 'summary,created,updated,status,duedate,description' +
    (startField == null ? '' : ',' + startField);

for (Work_Item__c item : items) {
    itemByExternalId.put(item.External_Id__c, item);
    String namespace = ExternalIdUtil.namespaceOf(item.External_Id__c);
    String rawId = ExternalIdUtil.rawIdOf(item.External_Id__c);

    if (namespace == ExternalSystem.ASANA_NAMESPACE) {
        // The shape of a real Asana event: a gid and nothing else. The adapter fetches the rest.
        asanaRows.add(new Webhook_Event__c(
            Source_System__c = ExternalSystem.ASANA,
            Raw_Payload__c = '{"action":"changed","resource":{"gid":"' + rawId + '","resource_type":"task"}}'
        ));
        continue;
    }
    if (namespace != ExternalSystem.JIRA_NAMESPACE) {
        skipped.add(item.Name + ': no backfill for ' + item.External_Id__c);
        continue;
    }
    if (jiraRows.size() >= JIRA_LIMIT) {
        skipped.add(item.Name + ': over this run\'s Jira limit; run the script again');
        continue;
    }

    HttpRequest req = new HttpRequest();
    req.setMethod('GET');
    req.setEndpoint('callout:Jira_Classic/rest/api/2/issue/' + rawId + '?fields=' + jiraFields);
    req.setHeader('Accept', 'application/json');
    req.setTimeout(10000);
    HttpResponse res;
    try {
        res = new Http().send(req);
    } catch (Exception e) {
        skipped.add(item.Name + ': callout failed - ' + e.getMessage());
        continue;
    }
    if (res.getStatusCode() != 200) {
        // 404 means the issue is gone from Jira. Either way nothing is written for it.
        skipped.add(item.Name + ': HTTP ' + res.getStatusCode());
        continue;
    }
    // GET /issue returns the issue object; a webhook wraps the same object in { issue: ... }.
    jiraRows.add(new Webhook_Event__c(
        Source_System__c = ExternalSystem.JIRA,
        Raw_Payload__c = '{"webhookEvent":"backfill","issue":' + res.getBody() + '}'
    ));
}

List<InboundChange> changes = new List<InboundChange>();
List<Integration_Log__c> adapterNotes = new List<Integration_Log__c>();
if (!jiraRows.isEmpty()) {
    JiraAdapter jira = new JiraAdapter();
    changes.addAll(jira.parseInbound(jiraRows));
    adapterNotes.addAll(jira.drainLogs());
}
if (!asanaRows.isEmpty()) {
    AsanaAdapter asana = new AsanaAdapter(); // calls out: still before any DML
    changes.addAll(asana.parseInbound(asanaRows));
    adapterNotes.addAll(asana.drainLogs());
}

// Callouts are done. DML from here down.
List<Work_Item__c> updates = new List<Work_Item__c>();
Map<String, Integer> filled = new Map<String, Integer>{
    'title' => 0, 'created' => 0, 'start' => 0, 'due' => 0, 'description' => 0
};
for (InboundChange change : changes) {
    Work_Item__c item = change.externalId == null ? null : itemByExternalId.get(change.externalId);
    if (item == null || !change.isUsable()) {
        skipped.add((item == null ? String.valueOf(change.externalId) : item.Name) + ': ' + change.failure);
        continue;
    }
    Work_Item__c patch = new Work_Item__c(Id = item.Id);
    if (String.isBlank(item.Title__c) && String.isNotBlank(change.title)) {
        patch.Title__c = change.title;
        filled.put('title', filled.get('title') + 1);
    }
    if (change.sourceCreated != null) {
        patch.Source_Created__c = change.sourceCreated;
        filled.put('created', filled.get('created') + 1);
    }
    if (change.carriesStartDate) {
        patch.Start_Date__c = change.startDate;
        if (change.startDate != null) filled.put('start', filled.get('start') + 1);
    }
    if (change.carriesDueDate) {
        patch.Due_Date__c = change.dueDate;
        if (change.dueDate != null) filled.put('due', filled.get('due') + 1);
    }
    if (change.carriesDescription) {
        patch.Description__c = change.description;
        if (change.description != null) filled.put('description', filled.get('description') + 1);
    }
    updates.add(patch);
}

Integer updated = 0;
if (!updates.isEmpty()) {
    // None of these fields is Status__c, so the trigger has nothing to push today. From build 08
    // step 3 a start or due date change IS pushable, so suppression is what keeps a backfill from
    // writing the same dates straight back to the source.
    SyncContext.suppressOutbound();
    List<Database.SaveResult> results;
    try {
        results = Database.update(updates, false);
    } finally {
        SyncContext.resumeOutbound();
    }
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            updated++;
        } else {
            List<String> messages = new List<String>();
            for (Database.Error error : results[i].getErrors()) {
                messages.add(String.valueOf(error.getStatusCode()) + ': ' + error.getMessage());
            }
            skipped.add(updates[i].Id + ': ' + String.join(messages, ' | '));
        }
    }
}

System.debug('BACKFILL candidates=' + items.size() + ' jira=' + jiraRows.size() + ' asana=' + asanaRows.size()
    + ' updated=' + updated + ' filled=' + filled + ' skipped=' + skipped.size());
for (String note : skipped) {
    System.debug('BACKFILL skip ' + note);
}
// The adapters log every callout, successful ones included, and a success row carries no error
// message - printing it produced a bare "adapter null" on the first run. Only failures are news.
Integer calloutsLogged = 0;
for (Integration_Log__c note : adapterNotes) {
    if (note.Is_Success__c == true) {
        calloutsLogged++;
        continue;
    }
    System.debug('BACKFILL adapter ' + note.Error_Message__c);
}
System.debug('BACKFILL adapter callouts that succeeded: ' + calloutsLogged);
