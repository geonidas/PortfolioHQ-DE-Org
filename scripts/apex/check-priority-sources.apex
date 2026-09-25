/**
 * Read-only check that Jira and Asana still offer the priorities build 09 maps.
 *
 *   sf apex run --file scripts/apex/check-priority-sources.apex --target-org MyScratchOrg | grep '>>>'
 *
 * Makes callouts only, through the adapters' own named credentials, and writes nothing. Prints:
 *
 * - Jira: DOPP's priority scheme - its default and each priority id and name, in order.
 * - Asana: the Priority custom field on the synced project, and each option gid.
 *
 * Compare the ids with docs/adr/build-09-priority-and-sort.md.
 *
 * It deliberately does not read Jira's editmeta. DOPP is team-managed, and there editmeta lists
 * priority on Story only while the API accepts it on every issue type - a real change landed on a
 * Task, an Epic, a Subtask and a Bug at build 09 step 0. Only a write proves writability, and this
 * script writes nothing.
 */
String jira(String path) {
  HttpRequest r = new HttpRequest();
  r.setMethod('GET');
  r.setHeader('Accept', 'application/json');
  r.setEndpoint('callout:Jira_Classic' + path);
  return new Http().send(r).getBody();
}
String asana(String path) {
  HttpRequest r = new HttpRequest();
  r.setMethod('GET');
  r.setHeader('Accept', 'application/json');
  r.setEndpoint('callout:Asana_Personal' + path);
  return new Http().send(r).getBody();
}

Map<String, Object> project = (Map<String, Object>) JSON.deserializeUntyped(jira('/rest/api/3/project/DOPP'));
System.debug('>>> Jira DOPP id=' + project.get('id') + ' style=' + project.get('style'));

Map<String, Object> schemes = (Map<String, Object>) JSON.deserializeUntyped(
  jira('/rest/api/3/priorityscheme?projectId=' + project.get('id') + '&expand=priorities')
);
for (Object s : (List<Object>) schemes.get('values')) {
  Map<String, Object> scheme = (Map<String, Object>) s;
  List<String> priorities = new List<String>();
  for (Object p : (List<Object>) ((Map<String, Object>) scheme.get('priorities')).get('values')) {
    Map<String, Object> priority = (Map<String, Object>) p;
    priorities.add(priority.get('id') + '=' + priority.get('name'));
  }
  System.debug('>>> Jira scheme ' + scheme.get('name') + ' default=' + scheme.get('defaultPriorityId') + ' priorities=' + priorities);
}

Project__c asanaProject = [SELECT External_Project_Key__c FROM Project__c WHERE External_System__c = 'Asana' LIMIT 1];
Map<String, Object> settings = (Map<String, Object>) JSON.deserializeUntyped(
  asana('/projects/' + asanaProject.External_Project_Key__c + '/custom_field_settings?opt_fields=custom_field.name,custom_field.enum_options.name,custom_field.enum_options.enabled')
);
for (Object s : (List<Object>) settings.get('data')) {
  Map<String, Object> field = (Map<String, Object>) ((Map<String, Object>) s).get('custom_field');
  List<String> options = new List<String>();
  if (field.get('enum_options') != null) {
    for (Object o : (List<Object>) field.get('enum_options')) {
      Map<String, Object> option = (Map<String, Object>) o;
      options.add(option.get('gid') + '=' + option.get('name') + (option.get('enabled') == true ? '' : ' (disabled)'));
    }
  }
  System.debug('>>> Asana project ' + asanaProject.External_Project_Key__c + ' field ' + field.get('gid') + '=' + field.get('name') + ' options=' + options);
}
