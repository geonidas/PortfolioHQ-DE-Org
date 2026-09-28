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
  public static String issueUpdated(
    String issueId,
    String issueKey,
    String jiraStatus,
    Datetime updated
  ) {
    return issueUpdated(
      issueId,
      issueKey,
      jiraStatus,
      updated,
      'Seeded by JiraWebhookPayloadFactory'
    );
  }

  /**
   * The same payload with the summary under the caller's control. A null summary omits the
   * field entirely rather than sending an empty one - that is the shape of a Jira delivery
   * that carries no title, which the processor has to leave an existing Title__c alone for.
   */
  public static String issueUpdated(
    String issueId,
    String issueKey,
    String jiraStatus,
    Datetime updated,
    String summary
  ) {
    return issueUpdated(
      issueId,
      issueKey,
      jiraStatus,
      updated,
      summary,
      'Story',
      null
    );
  }

  /**
   * The same payload with the issue type and parent under the caller's control.
   *
   * A null issueTypeName omits the issuetype object entirely, and a null parentId omits the
   * parent object entirely - not an empty one. That is the shape of a real Jira status
   * transition, which carries neither, and it is exactly the case the processor must leave
   * existing values alone for. Sending an empty object instead would test nothing.
   */
  public static String issueUpdated(
    String issueId,
    String issueKey,
    String jiraStatus,
    Datetime updated,
    String summary,
    String issueTypeName,
    String parentId
  ) {
    return issueUpdated(
      issueId,
      issueKey,
      jiraStatus,
      updated,
      summary,
      issueTypeName,
      parentId,
      null
    );
  }

  /**
   * The same payload with the project under the caller's control. A null projectKey omits the
   * project object entirely. The default overloads send no project so that the many tests which
   * seed a project per work item are not surprised by the processor linking to it.
   */
  public static String issueUpdated(
    String issueId,
    String issueKey,
    String jiraStatus,
    Datetime updated,
    String summary,
    String issueTypeName,
    String parentId,
    String projectKey
  ) {
    String projectField = projectKey == null
      ? ''
      : '"project":{"id":"10000","key":"' +
        String.escapeSingleQuotes(projectKey) +
        '"},';
    String summaryField = summary == null
      ? ''
      : '"summary":"' + String.escapeSingleQuotes(summary) + '",';
    String typeField = issueTypeName == null
      ? ''
      : '"issuetype":{"name":"' +
        String.escapeSingleQuotes(issueTypeName) +
        '"},';
    String parentField = parentId == null
      ? ''
      : '"parent":{"id":"' +
        String.escapeSingleQuotes(parentId) +
        '","key":"DOPP-' +
        parentId +
        '"},';
    return '{' +
      '"timestamp":' +
      updated.getTime() +
      ',' +
      '"webhookEvent":"jira:issue_updated",' +
      '"issue_event_type_name":"issue_generic",' +
      '"user":{"accountId":"5f1e2d","displayName":"A Person"},' +
      '"issue":{' +
      '"id":"' +
      issueId +
      '",' +
      '"key":"' +
      issueKey +
      '",' +
      '"fields":{' +
      summaryField +
      '"updated":"' +
      jiraTimestamp(updated) +
      '",' +
      typeField +
      parentField +
      projectField +
      '"status":{"id":"3","name":"' +
      String.escapeSingleQuotes(jiraStatus) +
      '"}' +
      '}}}';
  }

  /**
   * A jira:issue_updated payload whose fields are built from a map, for fields the fixed
   * overloads do not cover - created, duedate, a start date custom field, description.
   *
   * A map value of null is sent as an explicit JSON null, which is how Jira says a field is
   * empty; a key left out of the map is absent from the payload, which is how a field is not
   * carried at all. The processor treats the two differently, and a factory that could only
   * produce one of them could not test that.
   */
  public static String issueUpdatedWithFields(
    String issueId,
    String issueKey,
    String jiraStatus,
    Datetime updated,
    Map<String, Object> extraFields
  ) {
    Map<String, Object> fields = new Map<String, Object>{
      'updated' => jiraTimestamp(updated),
      'status' => new Map<String, Object>{ 'id' => '3', 'name' => jiraStatus }
    };
    if (extraFields != null) {
      fields.putAll(extraFields);
    }
    return JSON.serialize(
      new Map<String, Object>{
        'timestamp' => updated.getTime(),
        'webhookEvent' => 'jira:issue_updated',
        'issue' => new Map<String, Object>{
          'id' => issueId,
          'key' => issueKey,
          'fields' => fields
        }
      }
    );
  }

  /** Build 09: DOPP's priority rows - three values, and the en dash (10000), which means none. */
  public static List<Field_Mapping__mdt> priorityMappings() {
    return new List<Field_Mapping__mdt>{
      priorityRow('2', 'High', 'High', false),
      priorityRow('3', 'Medium', 'Medium', false),
      priorityRow('4', 'Low', 'Low', false),
      priorityRow('10000', '\u2013', null, true)
    };
  }

  private static Field_Mapping__mdt priorityRow(
    String id,
    String label,
    String normalized,
    Boolean mapsToBlank
  ) {
    return new Field_Mapping__mdt(
      External_System__c = ExternalSystem.JIRA,
      Mapping_Type__c = FieldMappingService.PRIORITY,
      External_Value__c = id,
      External_Label__c = label,
      Normalized_Value__c = normalized,
      Maps_To_Blank__c = mapsToBlank,
      Is_Active__c = true
    );
  }

  /** fields.priority as Jira sends it: an object with an id and a name, among other things. */
  public static Map<String, Object> priority(String id, String name) {
    return new Map<String, Object>{
      'self' => 'https://example.atlassian.net/rest/api/2/priority/' + id,
      'id' => id,
      'name' => name
    };
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
