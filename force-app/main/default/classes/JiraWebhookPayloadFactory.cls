/**
 * Builds Jira webhook payloads and signing material for tests.
 *
 * Secrets are generated per run rather than hardcoded. A literal test secret would be a secret
 * value living in source control, which is exactly what this build forbids - and a random one
 * also proves the code never depends on a particular value.
 */
@IsTest
public class JiraWebhookPayloadFactory {
    /** A fresh, throwaway signing secret. Never written down anywhere. */
    public static String randomSecret() {
        return EncodingUtil.convertToHex(Crypto.generateAesKey(128));
    }

    /** Jira's wire format for a timestamp: ISO-8601 with a four digit offset. */
    public static String jiraTimestamp(Datetime value) {
        return value.formatGMT('yyyy-MM-dd\'T\'HH:mm:ss.SSS') + '+0000';
    }

    /**
     * A jira:issue_updated payload. The transition's own vocabulary is deliberately Jira's, not
     * ours - 'In Progress', 'Resolved' and so on - so tests exercise the real normalization.
     */
    public static String issueUpdated(String issueId, String issueKey, String jiraStatus, Datetime updated) {
        return '{' +
            '"timestamp":' + updated.getTime() + ',' +
            '"webhookEvent":"jira:issue_updated",' +
            '"issue_event_type_name":"issue_generic",' +
            '"user":{"accountId":"5f1e2d","displayName":"A Person"},' +
            '"issue":{' +
            '"id":"' + issueId + '",' +
            '"key":"' + issueKey + '",' +
            '"fields":{' +
            '"summary":"Seeded by JiraWebhookPayloadFactory",' +
            '"updated":"' + jiraTimestamp(updated) + '",' +
            '"issuetype":{"name":"Story"},' +
            '"status":{"id":"3","name":"' + String.escapeSingleQuotes(jiraStatus) + '"}' +
            '}}}';
    }

    /** Inserts a delivery the way the endpoint would have, ready for the processor. */
    public static Webhook_Event__c delivery(String payload) {
        return new Webhook_Event__c(
            Source_System__c = 'Jira',
            Received_At__c = System.now(),
            Signature_Valid__c = true,
            Processing_Status__c = 'Pending',
            Raw_Payload__c = payload
        );
    }
}
