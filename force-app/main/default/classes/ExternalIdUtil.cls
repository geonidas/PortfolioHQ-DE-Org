/**
 * Namespacing for external record ids.
 *
 * Work_Item__c.External_Id__c is unique per field, not per external system, so a Jira issue id
 * and an Asana GID that happen to share digits would collide. Ids are therefore stored qualified
 * - jira:10023 - and stripped back to the raw id before they go into a vendor REST path.
 *
 * Deliberately vendor-neutral: it knows about the shape of a qualified id, not about Jira.
 */
public with sharing class ExternalIdUtil {
    private static final String SEPARATOR = ':';

    public class MalformedExternalIdException extends Exception {
    }

    /**
     * @return the raw id qualified with its system, e.g. qualify('jira', '10023') -> 'jira:10023'
     */
    public static String qualify(String systemNamespace, String rawId) {
        if (String.isBlank(systemNamespace) || String.isBlank(rawId)) {
            throw new MalformedExternalIdException('Both a system namespace and a raw id are required.');
        }
        if (systemNamespace.contains(SEPARATOR)) {
            throw new MalformedExternalIdException('System namespace cannot contain "' + SEPARATOR + '": ' + systemNamespace);
        }
        return systemNamespace.trim().toLowerCase() + SEPARATOR + rawId.trim();
    }

    /**
     * @return the system portion, lowercased, e.g. 'jira' from 'jira:10023'
     */
    public static String namespaceOf(String externalId) {
        return split(externalId)[0];
    }

    /**
     * @return the vendor's own id, e.g. '10023' from 'jira:10023'. This is what goes in a REST path.
     */
    public static String rawIdOf(String externalId) {
        return split(externalId)[1];
    }

    /**
     * @return true when externalId is well formed and belongs to the given system
     */
    public static Boolean belongsTo(String externalId, String systemNamespace) {
        if (String.isBlank(externalId) || String.isBlank(systemNamespace)) {
            return false;
        }
        try {
            return namespaceOf(externalId) == systemNamespace.trim().toLowerCase();
        } catch (MalformedExternalIdException e) {
            return false;
        }
    }

    // Splits on the FIRST separator only, so a raw id containing a colon survives intact.
    private static List<String> split(String externalId) {
        if (String.isBlank(externalId)) {
            throw new MalformedExternalIdException('External id is blank.');
        }
        String trimmed = externalId.trim();
        Integer boundary = trimmed.indexOf(SEPARATOR);
        if (boundary <= 0 || boundary == trimmed.length() - 1) {
            throw new MalformedExternalIdException(
                'External id must be qualified as <system>' + SEPARATOR + '<id>, got: ' + externalId
            );
        }
        return new List<String>{ trimmed.substring(0, boundary).toLowerCase(), trimmed.substring(boundary + 1) };
    }
}
