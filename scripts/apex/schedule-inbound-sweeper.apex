/**
 * Schedule WorkItemInboundSweeper to run every 15 minutes.
 *
 *   sf apex run --file scripts/apex/schedule-inbound-sweeper.apex --target-org MyScratchOrg
 *
 * RUN THIS AS A USER WHO HOLDS THE Asana_Token-PAT1 EXTERNAL CREDENTIAL GRANT. That is not a
 * convention, it is the mechanism. An async job runs as the user who started it and a Queueable
 * inherits the user of whatever enqueued it, so the Asana callout inside WorkItemInboundQueueable
 * is made as whoever ran this script. Schedule it as a user without the grant and every sweep
 * ends in "We couldn't access the credential(s)" - the same failure the platform event path hit
 * when it ran as Automated Process, which cannot be granted the principal at all.
 *
 * FOUR jobs, not one. Salesforce cron will not take a list in the seconds or minutes field:
 * '0 0,15,30,45 * * * ?' throws "Seconds and minutes must be specified as integers". Every
 * quarter hour therefore means four separate schedules. The org allows 100 scheduled Apex jobs,
 * so four is cheap - but it is four, and anything that counts them should expect that.
 *
 * The schedule is org state. It is not in source control, it does not survive a new scratch org,
 * and deploying the class does not create it. See docs/handoff.md section 1.
 *
 * Safe to re-run: existing jobs with these names are aborted first, so the schedule is replaced
 * rather than duplicated. Writes no Work_Item__c field, so nothing syncs to Jira or Asana.
 */

final String JOB_PREFIX = 'Work Item Inbound Sweeper';
final List<Integer> MINUTES = new List<Integer>{ 0, 15, 30, 45 };

List<CronTrigger> existing = [
  SELECT Id, CronJobDetail.Name
  FROM CronTrigger
  WHERE CronJobDetail.Name LIKE 'Work Item Inbound Sweeper%'
];
for (CronTrigger job : existing) {
  System.abortJob(job.Id);
  System.debug(
    LoggingLevel.INFO,
    '>>> Aborted ' +
      job.CronJobDetail.Name +
      ' (' +
      job.Id +
      ') so it can be replaced.'
  );
}

for (Integer minute : MINUTES) {
  String name = JOB_PREFIX + ' :' + (minute < 10 ? '0' + minute : '' + minute);
  Id jobId = System.schedule(
    name,
    '0 ' + minute + ' * * * ?',
    new WorkItemInboundSweeper()
  );
  System.debug(LoggingLevel.INFO, '>>> Scheduled ' + name + ' as ' + jobId);
}

System.debug(
  LoggingLevel.INFO,
  '>>> Running as ' +
    UserInfo.getUserName() +
    ' - every sweep calls Asana as this user.'
);
System.debug(
  LoggingLevel.INFO,
  '>>> Confirm with: sf data query -o MyScratchOrg -q "SELECT CronJobDetail.Name, State,' +
  ' NextFireTime FROM CronTrigger WHERE CronJobDetail.Name LIKE \'Work Item Inbound Sweeper%\'"'
);
System.debug(
  LoggingLevel.INFO,
  '>>> To stop it: System.abortJob on each of those four CronTrigger ids.'
);
