/*
 * Features no epic on the public board: the internal board's Remove button, from a terminal.
 * Open public boards stop showing the featured epic's tasks on their next poll, within about 30
 * seconds, and the next visit opens on Epics (ADR build-10, decisions 7 and 9).
 *
 *   sf apex run --file scripts/apex/clear-featured-epic.apex --target-org MyScratchOrg
 *
 * Writes the Featured_Epic__c setting and nothing else. Safe to re-run: with nothing featured it
 * changes nothing and says so.
 */
FeaturedEpicService.Result result = FeaturedEpicService.clear();
System.debug('>>> ' + (result.saved ? 'SAVED: ' : 'NOT SAVED: ') + result.message);
System.debug('>>> Featured now: ' + (FeaturedEpicService.read() == null ? 'none' : String.valueOf(FeaturedEpicService.read())));
