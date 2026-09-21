/**
 * Deploy the three Asana section -> Status__c mappings.
 *
 * Filled in for the 'Reading and learning tracker' project (1218523643929429). For another
 * project, replace the gids below. Then:
 *   sf apex run --file scripts/apex/add-asana-status-mappings.apex --target-org MyScratchOrg
 *
 * Custom metadata records cannot be created by DML, so this goes through the Metadata API the
 * same way promote-webhook-secret.apex does. Deployment is asynchronous; check Setup >
 * Deployment Status, or re-query Field_Mapping__mdt a minute later.
 *
 * Keyed on the SECTION GID, never the section name. A gid survives a rename and a name does not,
 * and a mapping that silently stopped matching because somebody retitled a column would be
 * invisible until the board went wrong.
 *
 * There is deliberately no In Review row. Asana has no such column, and that asymmetry is
 * correct - inventing a section for it would be a lie about the board.
 *
 * Writes no Work_Item__c field, so WorkItemTrigger stages nothing and enqueues nothing.
 * Safe to re-run: a mapping already deployed is deployed again with the same values.
 */

// ---- fill these in from your Asana project ----
Map<String, String> sectionGidByStatus = new Map<String, String>{
  WorkItemStatus.TO_DO => '1218523823051428',
  WorkItemStatus.IN_PROGRESS => '1218523823051431',
  WorkItemStatus.DONE => '1218523823051434'
};
Map<String, String> labelByStatus = new Map<String, String>{
  WorkItemStatus.TO_DO => 'Up next',
  WorkItemStatus.IN_PROGRESS => 'In progress',
  WorkItemStatus.DONE => 'Completed'
};

Metadata.DeployContainer container = new Metadata.DeployContainer();
List<String> planned = new List<String>();
Boolean unfilled = false;

for (String status : sectionGidByStatus.keySet()) {
  String gid = sectionGidByStatus.get(status);
  if (String.isBlank(gid) || gid.startsWith('PASTE_')) {
    System.debug(LoggingLevel.ERROR, '>>> Not filled in: ' + status);
    unfilled = true;
    continue;
  }

  Metadata.CustomMetadata record = new Metadata.CustomMetadata();
  record.fullName = 'Field_Mapping__mdt.Asana_Status_' + gid;
  record.label = Strings.truncate('Asana ' + labelByStatus.get(status), 40);

  Map<String, Object> values = new Map<String, Object>{
    'External_System__c' => ExternalSystem.ASANA,
    'Mapping_Type__c' => FieldMappingService.STATUS,
    'External_Value__c' => gid,
    'External_Label__c' => labelByStatus.get(status),
    'Normalized_Value__c' => status,
    'Is_Active__c' => true
  };
  for (String field : values.keySet()) {
    Metadata.CustomMetadataValue value = new Metadata.CustomMetadataValue();
    value.field = field;
    value.value = values.get(field);
    record.values.add(value);
  }

  container.addMetadata(record);
  planned.add(labelByStatus.get(status) + ' (' + gid + ') -> ' + status);
}

if (unfilled) {
  System.debug(
    LoggingLevel.ERROR,
    '>>> Fill in every section gid before running this. Nothing was deployed.'
  );
} else {
  Id jobId = Metadata.Operations.enqueueDeployment(container, null);
  for (String line : planned) {
    System.debug(LoggingLevel.INFO, '>>> DEPLOYING ' + line);
  }
  System.debug(LoggingLevel.INFO, '>>> Deployment job: ' + jobId);
  System.debug(
    LoggingLevel.INFO,
    '>>> Asynchronous. Confirm with: sf data query -o MyScratchOrg ' +
    '-q "SELECT DeveloperName, External_Value__c, Normalized_Value__c FROM Field_Mapping__mdt"'
  );
}
