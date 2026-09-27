/*
 * Features one epic on the public board: the internal board's button, from a terminal. For live
 * checks, and for the move to the Developer Edition org, where the featured epic is data and has
 * to be set again (ADR build-10, decision 1). Until it is, the public board opens on Epics.
 *
 *   sf apex run --file scripts/apex/set-featured-epic.apex --target-org MyScratchOrg
 *
 * Edit EPIC first: the epic's record number (WI-0000) or its source key (DOPP-1). Same service,
 * same rules as the button - an epic, public, under a public project - and a refusal says why.
 * Featuring another epic replaces the one featured. Writes the Featured_Epic__c setting and
 * nothing else: no work item is saved, so nothing is pushed to Jira or Asana.
 */
final String EPIC = 'WI-0000';

List<Work_Item__c> matches = [
    SELECT Id, Name, External_Key__c, Title__c
    FROM Work_Item__c
    WHERE Name = :EPIC OR External_Key__c = :EPIC
    WITH USER_MODE
];
if (matches.size() != 1) {
    System.debug('>>> ' + matches.size() + ' work items match ' + EPIC + '. Nothing was changed.');
} else {
    FeaturedEpicService.Result result = FeaturedEpicService.feature(matches[0].Id);
    System.debug('>>> ' + (result.saved ? 'SAVED: ' : 'NOT SAVED: ') + result.message);
}
Id featured = FeaturedEpicService.read();
System.debug('>>> Featured now: ' + (featured == null
    ? 'none'
    : [SELECT Name, Title__c FROM Work_Item__c WHERE Id = :featured].Name + ' (' + featured + ')'));
