/**
 * The secret reader must fail closed. Every one of these asserts that an org which is not
 * properly configured accepts nothing, rather than quietly waving traffic through.
 */
@IsTest
private class IntegrationSecretServiceTest {
    @IsTest
    static void anAbsentRecordYieldsNoSecret() {
        // Exercises the real custom metadata lookup, and does so deterministically: no record can
        // exist under this name. Asserting against JIRA_WEBHOOK here would make the result depend
        // on whether the org happens to be configured - which the suite must not care about in
        // either direction.
        String absent = 'No_Such_Secret_Should_Ever_Exist';
        Assert.isNull(IntegrationSecretService.activeSecret(absent), 'A name with no record yields no secret.');
        Assert.isFalse(IntegrationSecretService.isConfigured(absent), 'And reports itself unconfigured.');
    }

    @IsTest
    static void aSimulatedMissingRecordYieldsNoSecret() {
        // The freshly deployed org case, simulated rather than assumed.
        IntegrationSecretService.injectNoRecord();
        Assert.isNull(
            IntegrationSecretService.activeSecret(IntegrationSecretService.JIRA_WEBHOOK),
            'An org with no secret record must yield no secret.'
        );
        Assert.isFalse(
            IntegrationSecretService.isConfigured(IntegrationSecretService.JIRA_WEBHOOK),
            'An unconfigured org must report itself unconfigured.'
        );
    }

    @IsTest
    static void inactiveRecordYieldsNoSecret() {
        IntegrationSecretService.inject(JiraWebhookPayloadFactory.randomSecret(), false);
        Assert.isNull(
            IntegrationSecretService.activeSecret(IntegrationSecretService.JIRA_WEBHOOK),
            'Is_Active__c = false is a kill switch, not a suggestion.'
        );
    }

    @IsTest
    static void blankValueYieldsNoSecret() {
        for (String blank : new List<String>{ null, '', '    ' }) {
            IntegrationSecretService.inject(blank, true);
            Assert.isNull(
                IntegrationSecretService.activeSecret(IntegrationSecretService.JIRA_WEBHOOK),
                'A blank secret must never be treated as "skip validation". Value: "' + blank + '"'
            );
        }
    }

    @IsTest
    static void blankDeveloperNameYieldsNoSecret() {
        Assert.isNull(IntegrationSecretService.activeSecret(null), 'A null key cannot resolve to a secret.');
        Assert.isNull(IntegrationSecretService.activeSecret('   '), 'A blank key cannot resolve to a secret.');
    }

    @IsTest
    static void configuredRecordYieldsItsSecret() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        IntegrationSecretService.inject(secret, true);

        Assert.areEqual(
            secret,
            IntegrationSecretService.activeSecret(IntegrationSecretService.JIRA_WEBHOOK),
            'An active, populated record should yield its value.'
        );
        Assert.isTrue(IntegrationSecretService.isConfigured(IntegrationSecretService.JIRA_WEBHOOK), 'Configured.');
    }

    @IsTest
    static void developerNameIsPinnedToTheRecordCreatedByHand() {
        // The record never enters source control, so this constant is the only thing keeping the
        // code and the hand-created record in agreement. If it changes, the org stops working.
        Assert.areEqual('Jira_Webhook', IntegrationSecretService.JIRA_WEBHOOK, 'Pinned DeveloperName changed.');
    }
}
