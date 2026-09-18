/*
 * Flags one project and a handful of its work items public, so the guest board has something to
 * render. Every rebuilt org starts with nothing flagged, and an empty board is indistinguishable
 * from a permissions failure - which is the whole reason this script lives in the repo.
 *
 * Safe to re-run: it sets flags rather than creating records.
 *
 * Deliberately partial. Some work items are left private so that "no non-public record appears in
 * the payload" is something you can actually check rather than assume. One of those is a child of
 * a public parent, which proves a private child is excluded even when its parent is visible.
 *
 * Build 06 adds the inverse case: a PUBLIC work item under a PRIVATE project. Sharing criteria
 * cannot reference Project__r.Is_Public__c, so PublicBoardController's WHERE clause is the only
 * thing anywhere in the system enforcing the parent project flag. Until now nothing in the org
 * exercised it, which meant the one unguarded path was also the one untested path.
 *
 * Build 06 also shapes the data into a hierarchy, because the board now has two views and a flat
 * set of orphans renders the epic view empty on a freshly seeded org.
 *
 * Writing Is_Public__c does not touch Status__c, so WorkItemTrigger stages nothing and no outbound
 * push is queued. Flagging data public never talks to Jira.
 */

final List<String> COLUMNS = new List<String>{ 'To Do', 'In Progress', 'Done' };
final Integer PER_COLUMN = 2;

// ---- the project ----
List<Project__c> projects = [SELECT Id, Name, Short_Name__c, Is_Public__c FROM Project__c ORDER BY CreatedDate LIMIT 1];
if (projects.isEmpty()) {
    throw new IllegalArgumentException('No Project__c exists to flag. Sync from Jira first.');
}
Project__c project = projects[0];
project.Is_Public__c = true;
if (String.isBlank(project.Short_Name__c)) {
    // The guest DTO publishes Short_Name__c and deliberately does not fall back to Name, so a
    // blank short name means every public card renders with no project label at all.
    project.Short_Name__c = 'PHQ';
}
update project;
System.debug('>>> PROJECT ' + project.Name + ' is public, short name ' + project.Short_Name__c);

// ---- pick the work items ----
List<Work_Item__c> all = [
    SELECT Id, Name, External_Key__c, Status__c, Type__c, Parent_Work_Item__c, Is_Public__c
    FROM Work_Item__c
    WHERE Project__c = :project.Id
    ORDER BY Name ASC
];

Map<Id, Work_Item__c> byId = new Map<Id, Work_Item__c>(all);
Map<String, Integer> takenPerColumn = new Map<String, Integer>();
for (String column : COLUMNS) {
    takenPerColumn.put(column, 0);
}

Set<Id> toPublish = new Set<Id>();
for (Work_Item__c item : all) {
    Integer taken = takenPerColumn.get(item.Status__c);
    if (taken != null && taken < PER_COLUMN) {
        toPublish.add(item.Id);
        takenPerColumn.put(item.Status__c, taken + 1);
    }
}

// A child with a withheld parent loses its nesting, because the guest DTO only resolves a parent
// that is itself public. Pull those parents in so the hierarchy actually renders.
for (Id itemId : new Set<Id>(toPublish)) {
    Id parentId = byId.get(itemId).Parent_Work_Item__c;
    if (parentId != null && byId.containsKey(parentId)) {
        toPublish.add(parentId);
    }
}

// ---- apply ----
List<Work_Item__c> updates = new List<Work_Item__c>();
for (Work_Item__c item : all) {
    Boolean shouldBePublic = toPublish.contains(item.Id);
    if (item.Is_Public__c != shouldBePublic) {
        updates.add(new Work_Item__c(Id = item.Id, Is_Public__c = shouldBePublic));
    }
}
if (!updates.isEmpty()) {
    update updates;
}

// ---- ownership ----
// Guest sharing rules do not share records owned by the Automated Process user, and the inbound
// webhook subscriber owns everything it creates. Measured directly: a public record owned by
// Automated Process is not readable by the guest; reassigning it makes it readable immediately.
// JiraWebhookProcessor now sets the owner on creation, but records synced before that change
// still carry the old owner, so this reassigns the ones being published.
Id newOwner = UserInfo.getUserId();
List<Work_Item__c> reassign = new List<Work_Item__c>();
// Comparing OwnerId directly: Owner is a polymorphic lookup, so Owner.UserType is not filterable.
for (Work_Item__c item : [SELECT Id, OwnerId FROM Work_Item__c WHERE Id IN :toPublish]) {
    if (item.OwnerId != newOwner) {
        reassign.add(new Work_Item__c(Id = item.Id, OwnerId = newOwner));
    }
}
if (!reassign.isEmpty()) {
    update reassign;
}
System.debug('>>> REASSIGNED ' + reassign.size() + ' public work items to ' + UserInfo.getName());

// ---- the inverse case: a public work item under a private project ----
// Carried over from build 05. This record is flagged public and is owned by a real user, so
// sharing grants the guest access to the ROW - and it must still be absent from the board,
// because the query demands Project__r.Is_Public__c too. If it ever shows up, the only
// enforcement of the parent project flag has gone.
List<Project__c> hidden = [SELECT Id, Name, Is_Public__c FROM Project__c WHERE Is_Public__c = false ORDER BY CreatedDate LIMIT 1];
Project__c privateProject;
if (hidden.isEmpty()) {
    privateProject = new Project__c(Name = 'Internal Only (seed)', Short_Name__c = 'INT', Is_Public__c = false);
    insert privateProject;
} else {
    privateProject = hidden[0];
}

List<Work_Item__c> canaries = [
    SELECT Id, Name, Is_Public__c, OwnerId
    FROM Work_Item__c
    WHERE Project__c = :privateProject.Id AND External_Key__c = 'SEED-CANARY'
];
Work_Item__c canary;
if (canaries.isEmpty()) {
    canary = new Work_Item__c(
        Title__c = 'Public row under a private project - must never render',
        External_Key__c = 'SEED-CANARY',
        // Deliberately no External_Id__c. WorkItemTriggerHandler only pushes a record that
        // has one, so this row can never reach Jira however its status is later edited.
        // It is identified on re-run by External_Key__c instead.
        External_System__c = 'Jira',
        Project__c = privateProject.Id,
        Status__c = 'In Progress',
        Sync_Status__c = 'Pending',
        Type__c = 'Story',
        Is_Public__c = true,
        OwnerId = UserInfo.getUserId()
    );
    insert canary;
} else {
    canary = canaries[0];
    canary.Is_Public__c = true;
    canary.OwnerId = UserInfo.getUserId();
    update canary;
}
// Re-queried because Name is an auto number: it is not populated on the in-memory record
// that insert returns, so reading canary.Name directly prints null.
canary = [SELECT Id, Name FROM Work_Item__c WHERE Id = :canary.Id];
System.debug('>>> CANARY ' + canary.Name + ' is public under PRIVATE project ' + privateProject.Name);
System.debug('>>>   it must NOT appear on the board. If it does, the WHERE clause is the only thing that was stopping it.');

// ---- hierarchy: the epic view needs epics, and the task view needs them parented ----
// Without this a freshly seeded org shows an empty epic view, which is indistinguishable from
// a broken one - the same reason this script exists at all.
List<Work_Item__c> published = [
    SELECT Id, Name, Status__c, Type__c, Parent_Work_Item__c, Title__c
    FROM Work_Item__c
    WHERE Id IN :toPublish
    ORDER BY Name ASC
];
// Epics are chosen from records that ALREADY hold the status each role needs, and this
// block never writes Status__c. That is not tidiness: WorkItemTriggerHandler enqueues a real
// outbound push on any status change to a record carrying an External_Id__c, so assigning a
// status here would transition live Jira issues as a side effect of seeding demo data. The
// original script's promise - flagging data public never talks to Jira - has to survive.
Work_Item__c liveEpic = null;
Work_Item__c doneEpic = null;
List<Work_Item__c> remainder = new List<Work_Item__c>();
for (Work_Item__c w : published) {
    if (liveEpic == null && w.Status__c != 'Done') {
        liveEpic = w;
    } else if (doneEpic == null && w.Status__c == 'Done') {
        doneEpic = w;
    } else {
        remainder.add(w);
    }
}

if (liveEpic != null) {
    liveEpic.Type__c = 'Epic';
    liveEpic.Parent_Work_Item__c = null;
    if (String.isBlank(liveEpic.Title__c)) {
        liveEpic.Title__c = 'Portfolio HQ delivery';
    }
    if (doneEpic != null) {
        doneEpic.Type__c = 'Epic';
        doneEpic.Parent_Work_Item__c = null;
        if (String.isBlank(doneEpic.Title__c)) {
            doneEpic.Title__c = 'Shipped work';
        }
    }

    // Everything else hangs off the live epic. One of them goes two hops down, so the
    // ancestor walk is exercised by the seed data rather than only by tests.
    List<Work_Item__c> reparent = new List<Work_Item__c>{ liveEpic };
    if (doneEpic != null) {
        reparent.add(doneEpic);
    }
    Id firstChildId = null;
    for (Integer i = 0; i < remainder.size(); i++) {
        Work_Item__c child = remainder[i];
        child.Type__c = (child.Type__c == 'Epic' || String.isBlank(child.Type__c) ||
            child.Type__c == 'Unspecified') ? 'Story' : child.Type__c;
        if (firstChildId == null) {
            child.Parent_Work_Item__c = liveEpic.Id;
            firstChildId = child.Id;
        } else if (i == 1) {
            // A subtask under a story under an epic: two hops to its epic.
            child.Type__c = 'Task';
            child.Parent_Work_Item__c = firstChildId;
        } else {
            child.Parent_Work_Item__c = liveEpic.Id;
        }
        reparent.add(child);
    }
    // Only Type__c and Parent_Work_Item__c are written. Neither is a status change, so
    // WorkItemTriggerHandler stages nothing and enqueues nothing - no callout to Jira.
    update reparent;
    System.debug('>>> HIERARCHY live epic ' + liveEpic.Name + ' (' + liveEpic.Status__c + ')' +
        (doneEpic == null ? ', no completed epic available' : ', done epic ' + doneEpic.Name) +
        ', ' + remainder.size() + ' items beneath');
} else {
    System.debug('>>> HIERARCHY SKIPPED - no unfinished public work item to act as the live epic');
}

// ---- report ----
System.debug('>>> PUBLIC ' + toPublish.size() + ' of ' + all.size() + ' work items');
for (Work_Item__c item : all) {
    String mark = toPublish.contains(item.Id) ? 'PUBLIC ' : 'private';
    String parent = item.Parent_Work_Item__c == null
        ? ''
        : ' (child of ' + byId.get(item.Parent_Work_Item__c).External_Key__c + ')';
    System.debug('>>>   ' + mark + '  ' + item.Name + '  ' + item.External_Key__c +
        '  ' + item.Status__c + '  type=' + item.Type__c + parent);
}
System.debug('>>> LEFT PRIVATE ' + (all.size() - toPublish.size()) + ' - these must never appear in the guest payload');
