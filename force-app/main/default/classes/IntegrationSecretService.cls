/**
 * Reads signing secrets from the protected Integration_Secret__mdt type.
 *
 * Protected custom metadata is the right home for this: Apex in this org can read it, but it
 * cannot be queried out of the org by a user, which is what lets guest-reachable code use a
 * secret the guest itself must never see.
 *
 * Fails closed, always. A missing record, an inactive one and a blank value are deliberately
 * indistinguishable to callers - all three return null, and null means reject. There is no code
 * path where "not configured" degrades into "skip validation".
 */
public with sharing class IntegrationSecretService {
    /**
     * DeveloperName of the record holding the Jira webhook signing secret. Pinned as a literal
     * because the record is created by hand in Setup and never lives in source control, so this
     * constant is the only thing keeping the two in agreement.
     */
    public static final String JIRA_WEBHOOK = 'Jira_Webhook';

    // Custom metadata records cannot be created by DML, so a test can never stand one up. The
    // only way to exercise the accepted-signature path is to inject. Test context only.
    @TestVisible
    private static Boolean injectionEnabled = false;
    @TestVisible
    private static String injectedSecret;
    @TestVisible
    private static Boolean injectedIsActive = true;

    /**
     * @param developerName DeveloperName of the Integration_Secret__mdt record
     * @return              the usable secret, or null when there is none to use
     */
    public static String activeSecret(String developerName) {
        if (injectionEnabled) {
            return (injectedIsActive == true && String.isNotBlank(injectedSecret)) ? injectedSecret : null;
        }
        if (String.isBlank(developerName)) {
            return null;
        }
        Integration_Secret__mdt record = Integration_Secret__mdt.getInstance(developerName);
        if (record == null || record.Is_Active__c != true || String.isBlank(record.Secret_Value__c)) {
            return null;
        }
        return record.Secret_Value__c;
    }

    /** True when this org has a usable secret configured. Never reveals the value. */
    public static Boolean isConfigured(String developerName) {
        return activeSecret(developerName) != null;
    }

    @TestVisible
    private static void inject(String secret, Boolean isActive) {
        injectionEnabled = true;
        injectedSecret = secret;
        injectedIsActive = isActive;
    }

    @TestVisible
    private static void injectNoRecord() {
        injectionEnabled = true;
        injectedSecret = null;
        injectedIsActive = false;
    }
}