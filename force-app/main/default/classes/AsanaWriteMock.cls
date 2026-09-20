/**
 * Captures the writes an outbound push sends to Asana.
 *
 * A status change is two writes - a section move and a completion flag - and the thing worth
 * asserting is that both went, in that order, carrying the right gids. A mock that only scripted
 * responses would prove the result handling works and say nothing about what Salesforce sent.
 */
@IsTest
public class AsanaWriteMock implements HttpCalloutMock {
  public class CapturedRequest {
    public String method;
    public String endpoint;
    public String body;
  }

  public final List<CapturedRequest> captured = new List<CapturedRequest>();
  /** One code per call, in order. The last one repeats if more calls arrive than codes. */
  private final List<Integer> statusCodes;

  public AsanaWriteMock(Integer statusCode) {
    this.statusCodes = new List<Integer>{ statusCode };
  }

  /** For the case that matters most: the section move lands and the completion flag does not. */
  public AsanaWriteMock(List<Integer> statusCodes) {
    this.statusCodes = statusCodes == null || statusCodes.isEmpty()
      ? new List<Integer>{ 200 }
      : statusCodes;
  }

  public Integer callCount() {
    return captured.size();
  }

  public HttpResponse respond(HttpRequest request) {
    CapturedRequest snapshot = new CapturedRequest();
    snapshot.method = request.getMethod();
    snapshot.endpoint = request.getEndpoint();
    snapshot.body = request.getBody();
    captured.add(snapshot);

    Integer code = statusCodes[
      Math.min(captured.size() - 1, statusCodes.size() - 1)
    ];
    HttpResponse response = new HttpResponse();
    response.setHeader('Content-Type', 'application/json');
    response.setStatusCode(code);
    response.setStatus(code == 200 ? 'OK' : 'Error');
    response.setBody(
      code == 200
        ? '{"data":{"gid":"1210000000000042"}}'
        : '{"errors":[{"message":"Refused"}]}'
    );
    return response;
  }
}
