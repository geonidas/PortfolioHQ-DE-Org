/**
 * Backfill Work_Item__c.Title__c from Jira for records that predate the field.
 *
 * Run once per org after deploying Title__c: sf apex run -f scripts/apex/backfill-work-item-titles.apex
 * Records synced before the field existed have no title and fall back to showing their external
 * key as the card heading. The webhook fills Title__c in going forward, but only when an issue
 * next changes, which for a finished item may be never.
 *
 * Every callout happens before any DML - Apex refuses a callout once DML is pending, and there
 * is no second chance in an anonymous block. Only records with no title are touched, so a rerun
 * is cheap and a title already synced by a webhook is never overwritten.
 */
List<Work_Item__c> items = [
    SELECT Id, Name, External_Id__c, External_Key__c, Title__c
    FROM Work_Item__c
    WHERE External_System__c = 'Jira' AND External_Id__c != null AND Title__c = null
    ORDER BY Name ASC
    LIMIT 100
];
System.debug('BACKFILL candidates=' + items.size());

Map<Id, String> titleById = new Map<Id, String>();
List<String> skipped = new List<String>();

for (Work_Item__c item : items) {
    String issueId = ExternalIdUtil.rawIdOf(item.External_Id__c);
    if (String.isBlank(issueId)) {
        skipped.add(item.Name + ' (' + item.External_Key__c + '): no raw id in ' + item.External_Id__c);
        continue;
    }
    HttpRequest req = new HttpRequest();
    req.setMethod('GET');
    req.setEndpoint('callout:Jira_Classic/rest/api/3/issue/' + issueId + '?fields=summary');
    req.setHeader('Accept', 'application/json');
    req.setTimeout(10000);

    HttpResponse res;
    try {
        res = new Http().send(req);
    } catch (Exception e) {
        skipped.add(item.Name + ' (' + item.External_Key__c + '): callout failed - ' + e.getMessage());
        continue;
    }
    if (res.getStatusCode() != 200) {
        // 404 means the issue is gone from Jira; anything else is a real failure. Either way
        // the record keeps its key fallback rather than acquiring a wrong title.
        skipped.add(item.Name + ' (' + item.External_Key__c + '): HTTP ' + res.getStatusCode());
        continue;
    }

    Map<String, Object> payload = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    Object fieldsRaw = payload.get('fields');
    Map<String, Object> fields = fieldsRaw instanceof Map<String, Object>
        ? (Map<String, Object>) fieldsRaw
        : null;
    String summary = fields == null ? null : (String) fields.get('summary');
    if (String.isBlank(summary)) {
        skipped.add(item.Name + ' (' + item.External_Key__c + '): issue has no summary');
        continue;
    }
    // Same 255 ceiling the webhook path applies, for the same reason.
    titleById.put(item.Id, summary.length() > 255 ? summary.left(252) + '...' : summary);
}

// Callouts are done. DML from here down.
List<Work_Item__c> updates = new List<Work_Item__c>();
for (Id workItemId : titleById.keySet()) {
    updates.add(new Work_Item__c(Id = workItemId, Title__c = titleById.get(workItemId)));
}

Integer updated = 0;
if (!updates.isEmpty()) {
    // A title-only update produces no Status__c delta, so the trigger would not push anyway.
    // Suppressing is the cheap way to be certain a backfill never writes back to Jira.
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

System.debug('BACKFILL updated=' + updated + ' skipped=' + skipped.size());
for (String note : skipped) {
    System.debug('BACKFILL skip ' + note);
}
