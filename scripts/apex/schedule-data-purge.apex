/**
 * Schedule IntegrationDataPurge nightly at 23:00.
 *
 *   sf apex run --file scripts/apex/schedule-data-purge.apex --target-org MyScratchOrg
 *
 * THE CRON RUNS IN THE SCHEDULING USER'S TIME ZONE, not the org's and not UTC. The scratch org
 * admin is America/Los_Angeles, so '0 0 23 * * ?' is 11pm Pacific and follows daylight saving on
 * its own - no PDT/PST arithmetic and nothing to correct twice a year. Schedule it as a user in
 * another zone and it will fire at 11pm in THAT zone; the script prints whose it used.
 *
 * One job, not four: this is daily, so a single hour value is all the cron needs. The sweeper
 * needs four only because Salesforce refuses a list in the minutes field.
 *
 * Safe to re-run: an existing job with this name is aborted first. Deleting rows is all this
 * does, so re-running costs nothing but a replaced schedule.
 *
 * MUST be unscheduled before IntegrationDataPurge can be redeployed - same rule as the sweeper.
 * See docs/handoff.md section 3.
 */

final String JOB_NAME = 'Integration Data Purge';
final String CRON = '0 0 23 * * ?';

for (CronTrigger job : [
  SELECT Id, CronJobDetail.Name
  FROM CronTrigger
  WHERE CronJobDetail.Name = :JOB_NAME
]) {
  System.abortJob(job.Id);
  System.debug(
    LoggingLevel.INFO,
    '>>> Aborted the existing schedule ' + job.Id
  );
}

Id jobId = System.schedule(JOB_NAME, CRON, new IntegrationDataPurge());

System.debug(LoggingLevel.INFO, '>>> Scheduled ' + JOB_NAME + ' as ' + jobId);
System.debug(
  LoggingLevel.INFO,
  '>>> Runs 23:00 in the time zone of ' +
    UserInfo.getUserName() +
    ', which is ' +
    [SELECT TimeZoneSidKey FROM User WHERE Id = :UserInfo.getUserId()]
    .TimeZoneSidKey
);
