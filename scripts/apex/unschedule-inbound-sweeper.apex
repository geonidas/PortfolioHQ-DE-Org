/**
 * Abort every WorkItemInboundSweeper schedule.
 *
 *   sf apex run --file scripts/apex/unschedule-inbound-sweeper.apex --target-org MyScratchOrg
 *
 * RUN THIS BEFORE DEPLOYING WorkItemInboundSweeper. A schedulable class cannot be deployed while
 * it has scheduled jobs:
 *
 *   This schedulable class has jobs pending or in progress - CronTrigger IDs (...)
 *
 * The deploy fails whole, including any other class in the same command, and the message names
 * CronTrigger ids rather than saying "unschedule it first". So the loop for any change to that
 * class is: run this, deploy, then scripts/apex/schedule-inbound-sweeper.apex again.
 *
 * The alternative is the "Allow deployments of components when corresponding Apex jobs are
 * pending or in progress" checkbox in Setup > Deployment Settings, which trades this three-step
 * loop for an org-wide setting. Deliberately not enabled here: the four jobs are cheap to
 * recreate and the script that recreates them is the thing that records WHO they run as, which
 * matters more on this path than convenience does.
 */

List<CronTrigger> existing = [
  SELECT Id, CronJobDetail.Name
  FROM CronTrigger
  WHERE CronJobDetail.Name LIKE 'Work Item Inbound Sweeper%'
];

if (existing.isEmpty()) {
  System.debug(LoggingLevel.INFO, '>>> Nothing scheduled. Safe to deploy.');
} else {
  for (CronTrigger job : existing) {
    System.abortJob(job.Id);
    System.debug(
      LoggingLevel.INFO,
      '>>> Aborted ' + job.CronJobDetail.Name + ' (' + job.Id + ')'
    );
  }
  System.debug(
    LoggingLevel.INFO,
    '>>> Aborted ' +
      existing.size() +
      '. Deploy now, then re-run scripts/apex/schedule-inbound-sweeper.apex.'
  );
}
