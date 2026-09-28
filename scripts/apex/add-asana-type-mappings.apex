/**
 * Deploy the Asana Format -> Type__c mappings.
 *
 *   sf apex run --file scripts/apex/add-asana-type-mappings.apex --target-org MyScratchOrg
 *
 * Keyed on the ENUM OPTION GID, not the option name, for the same reason status mappings are
 * keyed on section gids: a gid survives a rename and a name does not, and a mapping that
 * silently stopped matching because somebody retitled "Online course" would be invisible until
 * the board went wrong.
 *
 * Get the gids for a project's Format field with:
 *   GET /projects/<project_gid>/custom_field_settings
 *       ?opt_fields=custom_field.name,custom_field.enum_options.name
 *
 * An option with no row here lands on Unspecified with Source_Type__c keeping the raw name -
 * which is the promotion path working, not a failure. Query it grouped to decide what to add:
 *   SELECT Source_Type__c, COUNT(Id) FROM Work_Item__c
 *   WHERE Type__c = 'Unspecified' GROUP BY Source_Type__c
 *
 * Writes no Work_Item__c field, so WorkItemTrigger stages nothing and enqueues nothing.
 * Safe to re-run.
 */

// enum option gid => the Type__c value it means. Labels are what Asana calls the option.
Map<String, String> normalizedByOptionGid = new Map<String, String>{
  '1218523733859542' => 'Book', // Asana: "Book"
  '1218523733859543' => 'Online Course', // Asana: "Online course"
  '1218523733859545' => 'Video' // Asana: "Video series"
};
Map<String, String> labelByOptionGid = new Map<String, String>{
  '1218523733859542' => 'Book',
  '1218523733859543' => 'Online course',
  '1218523733859545' => 'Video series'
};

Metadata.DeployContainer container = new Metadata.DeployContainer();
List<String> planned = new List<String>();

for (String optionGid : normalizedByOptionGid.keySet()) {
  Metadata.CustomMetadata record = new Metadata.CustomMetadata();
  record.fullName = 'Field_Mapping__mdt.Asana_Type_' + optionGid;
  record.label = Strings.truncate(
    'Asana ' + labelByOptionGid.get(optionGid),
    40
  );

  Map<String, Object> values = new Map<String, Object>{
    'External_System__c' => ExternalSystem.ASANA,
    'Mapping_Type__c' => FieldMappingService.TYPE,
    'External_Value__c' => optionGid,
    'External_Label__c' => labelByOptionGid.get(optionGid),
    'Normalized_Value__c' => normalizedByOptionGid.get(optionGid),
    'Is_Active__c' => true
  };
  for (String field : values.keySet()) {
    Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
    value.field = field;
    value.value = values.get(field);
    record.values.add(value);
  }

  container.addMetadata(record);
  planned.add(
    labelByOptionGid.get(optionGid) +
      ' (' +
      optionGid +
      ') -> ' +
      normalizedByOptionGid.get(optionGid)
  );
}

Id jobId = Metadata.Operations.enqueueDeployment(container, null);
for (String line : planned) {
  System.debug(LoggingLevel.INFO, '>>> DEPLOYING ' + line);
}
System.debug(LoggingLevel.INFO, '>>> Deployment job: ' + jobId);
System.debug(
  LoggingLevel.INFO,
  '>>> Not mapped yet, because the option does not exist in Asana: Tutorial, Trailhead, ' +
    'Superbadge. "Article / paper" exists and is deliberately unmapped - it lands on ' +
    'Unspecified with Source_Type__c keeping the name, which is the evidence trail working.'
);
