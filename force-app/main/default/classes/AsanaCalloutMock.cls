/**
 * Scripted Asana batch responses, plus a record of what was actually sent.
 *
 * The captured requests are the point, as they are for JiraCalloutMock: asserting only on how a
 * response is handled proves the parser works and says nothing about whether Salesforce asked
 * for the right things. Tests check how many batch calls went out, how many actions each one
 * carried, and that every fetch asked for the opt_fields without which Asana returns a task with
 * no name, no section and no completion flag.
 */
@IsTest
public class AsanaCalloutMock implements HttpCalloutMock {
  public enum Scenario {
    BATCH_OK, // every requested task comes back 200
    TRANSPORT_FAILS, // the call itself throws
    HTTP_ERROR, // the batch call returns 500
    TASK_MISSING // the batch returns 200, one action inside it does not
  }

  public class CapturedRequest {
    public String method;
    public String endpoint;
    public String body;
    public List<String> requestedGids = new List<String>();
  }

  public final List<CapturedRequest> captured = new List<CapturedRequest>();

  /** gid -> the task object Asana would return, as JSON. */
  private final Map<String, String> tasksByGid;
  // Qualified at every use below as AsanaCalloutMock.Scenario.X. Apex identifiers are
  // case-insensitive, so this field shadows the enum type of the same name and an unqualified
  // Scenario.TRANSPORT_FAILS fails to compile with a message that does not say so.
  private final Scenario scenario;

  public AsanaCalloutMock(Scenario scenario, Map<String, String> tasksByGid) {
    this.scenario = scenario;
    this.tasksByGid = tasksByGid == null
      ? new Map<String, String>()
      : tasksByGid;
  }

  public Integer callCount() {
    return captured.size();
  }

  /** Every task gid this mock was ever asked for, across all calls. */
  public Set<String> allRequestedGids() {
    Set<String> all = new Set<String>();
    for (CapturedRequest request : captured) {
      all.addAll(request.requestedGids);
    }
    return all;
  }

  public HttpResponse respond(HttpRequest request) {
    CapturedRequest snapshot = new CapturedRequest();
    snapshot.method = request.getMethod();
    snapshot.endpoint = request.getEndpoint();
    snapshot.body = request.getBody();
    snapshot.requestedGids = gidsFrom(request.getBody());
    captured.add(snapshot);

    if (scenario == AsanaCalloutMock.Scenario.TRANSPORT_FAILS) {
      CalloutException boom = new CalloutException();
      boom.setMessage('Read timed out');
      throw boom;
    }

    HttpResponse response = new HttpResponse();
    response.setHeader('Content-Type', 'application/json');
    if (scenario == AsanaCalloutMock.Scenario.HTTP_ERROR) {
      response.setStatusCode(500);
      response.setStatus('Internal Server Error');
      response.setBody('{"errors":[{"message":"Server error"}]}');
      return response;
    }

    List<String> results = new List<String>();
    for (String gid : snapshot.requestedGids) {
      String task = tasksByGid.get(gid);
      if (task == null || scenario == AsanaCalloutMock.Scenario.TASK_MISSING) {
        // A per-action failure inside an otherwise fine batch. Normal, and costs one task.
        results.add(
          '{"status_code":404,"headers":{},"body":{"errors":[{"message":"Not a task"}]}}'
        );
        continue;
      }
      results.add(
        '{"status_code":200,"headers":{},"body":{"data":' + task + '}}'
      );
    }
    response.setStatusCode(200);
    response.setStatus('OK');
    response.setBody('{"data":[' + String.join(results, ',') + ']}');
    return response;
  }

  /** Reads the gids out of the batch body, in the order they were asked for. */
  private List<String> gidsFrom(String body) {
    List<String> gids = new List<String>();
    if (String.isBlank(body)) {
      return gids;
    }
    Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(
      body
    );
    Map<String, Object> data = (Map<String, Object>) envelope.get('data');
    for (Object entry : (List<Object>) data.get('actions')) {
      String path = (String) ((Map<String, Object>) entry).get('relative_path');
      // /tasks/<gid>?opt_fields=...
      String tail = path.substringAfter('/tasks/');
      gids.add(tail.substringBefore('?'));
    }
    return gids;
  }
}
