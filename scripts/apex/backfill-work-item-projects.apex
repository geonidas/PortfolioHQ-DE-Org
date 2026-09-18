/**
 * Link Work_Item__c records that have no Project__c to the project their external key names.
 *
 * Run once per org after the refactor pass that added project linkage to the inbound path:
 *   sf apex run --file scripts/apex/backfill-work-item-projects.apex --target-org MyScratchOrg
 *
 * Records synced before that pass, or created by hand, carry External_Key__c (e.g. DOPP-15) but
 * no project. The inbound processor now links a record on its next delivery, but a finished
 * issue may never be delivered again, so this does the same resolution once, in bulk.
 *
 * Same rules as the processor: match the key prefix against External_Project_Key__c with the
 * same External_System__c; a key that matches no project, or more than one, is left alone and
 * reported. Only Project__c is written, so WorkItemTrigger stages nothing and enqueues nothing -
 * no callout to Jira. Safe to re-run: it only touches records still unlinked.
 */

// ---- projects by system + key ----
Map<String, Id> projectByLookup = new Map<String, Id>();
Set<String> ambiguous = new Set<String>();
for (Project__c project : [
    SELECT Id, External_Project_Key__c, External_System__c
    FROM Project__c
    WHERE External_Project_Key__c != null AND External_System__c != null
]) {
    String lookup = project.External_System__c.toLowerCase() + '|' + project.External_Project_Key__c.toLowerCase();
    if (projectByLookup.containsKey(lookup)) {
        ambiguous.add(lookup);
    } else {
        projectByLookup.put(lookup, project.Id);
    }
}
for (String lookup : ambiguous) {
    projectByLookup.remove(lookup);
}
System.debug('BACKFILL projects keyed=' + projectByLookup.size() + ' ambiguous=' + ambiguous.size());

// ---- unlinked work items ----
List<Work_Item__c> unlinked = [
    SELECT Id, Name, External_Key__c, External_System__c
    FROM Work_Item__c
    WHERE Project__c = null AND External_Key__c != null AND External_System__c != null
    ORDER BY Name ASC
];
System.debug('BACKFILL candidates=' + unlinked.size());

List<Work_Item__c> updates = new List<Work_Item__c>();
List<String> skipped = new List<String>();
for (Work_Item__c item : unlinked) {
    // Jira keys are PROJECT-NUMBER. Everything before the last hyphen is the project key.
    Integer boundary = item.External_Key__c.lastIndexOf('-');
    if (boundary <= 0) {
        skipped.add(item.Name + ' (' + item.External_Key__c + '): key has no project prefix');
        continue;
    }
    String lookup = item.External_System__c.toLowerCase() + '|' + item.External_Key__c.substring(0, boundary).toLowerCase();
    Id projectId = projectByLookup.get(lookup);
    if (projectId == null) {
        skipped.add(item.Name + ' (' + item.External_Key__c + '): no single project for ' + lookup);
        continue;
    }
    updates.add(new Work_Item__c(Id = item.Id, Project__c = projectId));
}

// ---- apply ----
Integer linked = 0;
if (!updates.isEmpty()) {
    // Project__c is not Status__c, so the trigger would not push anyway. Suppressing costs
    // nothing and makes "never talks to Jira" a property of the script rather than of the trigger.
    SyncContext.suppressOutbound();
    List<Database.SaveResult> results;
    try {
        results = Database.update(updates, false);
    } finally {
        SyncContext.resumeOutbound();
    }
    for (Integer i = 0; i < results.size(); i++) {
        if (results[i].isSuccess()) {
            linked++;
        } else {
            List<String> messages = new List<String>();
            for (Database.Error error : results[i].getErrors()) {
                messages.add(String.valueOf(error.getStatusCode()) + ': ' + error.getMessage());
            }
            skipped.add(updates[i].Id + ': ' + String.join(messages, ' | '));
        }
    }
}

System.debug('BACKFILL linked=' + linked + ' skipped=' + skipped.size());
for (String note : skipped) {
    System.debug('BACKFILL skip ' + note);
}
