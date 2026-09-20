/**
 * Asana webhook events and hydrated task objects, for tests.
 *
 * Two shapes, because Asana uses two. An EVENT is what the webhook delivers: a resource gid, an
 * action, and nothing else - no name, no section, no completion flag. A TASK is what the API
 * returns when that gid is fetched. Keeping them apart in the factory keeps the tests honest
 * about which half they are exercising.
 */
@IsTest
public class AsanaPayloadFactory {
  // String values go through JSON.serialize, never String.escapeSingleQuotes. The latter is a
  // SOQL helper: it emits a backslash before an apostrophe, which is not a valid JSON escape, so
  // a section called "Someone else's column" produced a body the adapter could not parse - and
  // the test read that as the membership rule failing.
  /** Section gids for the learning project, as the mapping table would carry them. */
  public static final String PROJECT_GID = '1209900000000001';
  public static final String OTHER_PROJECT_GID = '1209900000000999';
  public static final String SECTION_UP_NEXT = '1209911111111111';
  public static final String SECTION_IN_PROGRESS = '1209922222222222';
  public static final String SECTION_COMPLETED = '1209933333333333';
  public static final String SECTION_UNMAPPED = '1209944444444444';

  /** One element of the events array, as AsanaWebhookResource stages it. */
  public static String taskEvent(String taskGid) {
    return taskEvent(taskGid, 'changed');
  }

  public static String taskEvent(String taskGid, String action) {
    return '{"action":"' +
      action +
      '","resource":{"gid":"' +
      taskGid +
      '","resource_type":"task"},' +
      '"created_at":"2026-09-19T10:00:00.000Z","user":{"gid":"77","resource_type":"user"}}';
  }

  /** An event about something that is not a task - Asana sends these on the same webhook. */
  public static String sectionEvent(String sectionGid) {
    return '{"action":"changed","resource":{"gid":"' +
      sectionGid +
      '","resource_type":"section"},"created_at":"2026-09-19T10:00:00.000Z"}';
  }

  /** A delivery row, as the endpoint would have staged it. Not inserted - DML before a callout
   * throws, and the adapter calls out. */
  public static Webhook_Event__c delivery(String payload) {
    return new Webhook_Event__c(
      Source_System__c = ExternalSystem.ASANA,
      Received_At__c = System.now(),
      Signature_Valid__c = true,
      Processing_Status__c = DeliveryStatus.PENDING,
      Raw_Payload__c = payload
    );
  }

  /** A hydrated task in one project and one section. */
  public static String task(
    String gid,
    String name,
    String sectionGid,
    String sectionName,
    Boolean completed,
    Datetime modifiedAt
  ) {
    return task(
      gid,
      name,
      new List<String>{ PROJECT_GID },
      new List<String>{ sectionGid },
      new List<String>{ sectionName },
      completed,
      modifiedAt,
      null
    );
  }

  /** A hydrated task with a Type custom field. */
  public static String typedTask(
    String gid,
    String name,
    String sectionGid,
    String typeValue,
    Datetime modifiedAt
  ) {
    return task(
      gid,
      name,
      new List<String>{ PROJECT_GID },
      new List<String>{ sectionGid },
      new List<String>{ 'A section' },
      false,
      modifiedAt,
      typeValue
    );
  }

  /**
   * The general shape. A task sits in several projects with a DIFFERENT SECTION IN EACH, which
   * is why memberships is an array of pairs and why task.section does not exist - reading the
   * first entry would take whichever Asana happened to list first.
   */
  public static String task(
    String gid,
    String name,
    List<String> projectGids,
    List<String> sectionGids,
    List<String> sectionNames,
    Boolean completed,
    Datetime modifiedAt,
    String typeValue
  ) {
    List<String> memberships = new List<String>();
    for (Integer i = 0; i < projectGids.size(); i++) {
      memberships.add(
        '{"project":{"gid":"' +
          projectGids[i] +
          '","name":"Project ' +
          i +
          '"},"section":{"gid":"' +
          sectionGids[i] +
          '","name":' +
          JSON.serialize(sectionNames[i]) +
          '}}'
      );
    }
    String customFields = typeValue == null
      ? '[]'
      : '[{"gid":"55","name":"Type","display_value":' +
        JSON.serialize(typeValue) +
        '}]';
    return '{"gid":"' +
      gid +
      '","resource_type":"task","resource_subtype":"default_task",' +
      '"name":' +
      JSON.serialize(name) +
      ',' +
      '"completed":' +
      (completed ? 'true' : 'false') +
      ',' +
      '"modified_at":"' +
      modifiedAt.formatGmt('yyyy-MM-dd\'T\'HH:mm:ss.SSS') +
      'Z",' +
      '"memberships":[' +
      String.join(memberships, ',') +
      '],' +
      '"custom_fields":' +
      customFields +
      '}';
  }

  /** The Status mappings the learning project needs, as Field_Mapping__mdt rows. */
  public static List<Field_Mapping__mdt> statusMappings() {
    return new List<Field_Mapping__mdt>{
      mapping(
        FieldMappingService.STATUS,
        SECTION_UP_NEXT,
        'Up Next',
        WorkItemStatus.TO_DO
      ),
      mapping(
        FieldMappingService.STATUS,
        SECTION_IN_PROGRESS,
        'In Progress',
        WorkItemStatus.IN_PROGRESS
      ),
      mapping(
        FieldMappingService.STATUS,
        SECTION_COMPLETED,
        'Completed',
        WorkItemStatus.DONE
      )
    };
  }

  public static Field_Mapping__mdt mapping(
    String mappingType,
    String externalValue,
    String externalLabel,
    String normalized
  ) {
    return new Field_Mapping__mdt(
      External_System__c = ExternalSystem.ASANA,
      Mapping_Type__c = mappingType,
      External_Value__c = externalValue,
      External_Label__c = externalLabel,
      Normalized_Value__c = normalized,
      Is_Active__c = true
    );
  }
}
