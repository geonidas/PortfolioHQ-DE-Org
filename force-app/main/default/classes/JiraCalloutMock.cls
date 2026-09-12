/**
 * Scripted Jira responses, plus a record of what was actually sent.
 *
 * The captured requests are the point: asserting only on how a response is handled proves the
 * parser works and says nothing about whether Salesforce sent a well-formed call. Tests check the
 * method, path, headers and body that went out.
 */
@IsTest
public class JiraCalloutMock implements HttpCalloutMock {
    public enum Scenario {
        TRANSITION_OK, // GET lists transitions, POST accepts
        ALIAS_ONLY, // GET offers 'Resolved', which is an alias of our 'Done'
        NO_MATCHING_TRANSITION, // GET succeeds but the workflow offers nothing suitable
        NO_TRANSITIONS_AT_ALL, // GET succeeds with an empty list - terminal issue
        UNAUTHORIZED, // 401 on the first call
        RATE_LIMITED, // 429 on the first call
        SERVER_ERROR, // 500 on the first call
        POST_FAILS, // GET fine, POST 500 - failure on the second leg
        MALFORMED_BODY // 200 with a body that is not the expected envelope
    }

    /** Snapshot of one outbound call, taken at send time. */
    public class CapturedRequest {
        public String method;
        public String endpoint;
        public String body;
        public String accept;
        public String contentType;
    }

    public final List<CapturedRequest> captured = new List<CapturedRequest>();
    private final Scenario scenario;

    public JiraCalloutMock(Scenario scenario) {
        this.scenario = scenario;
    }

    public Integer callCount() {
        return captured.size();
    }

    public CapturedRequest firstCall() {
        return captured.isEmpty() ? null : captured[0];
    }

    public CapturedRequest lastCall() {
        return captured.isEmpty() ? null : captured[captured.size() - 1];
    }

    public HttpResponse respond(HttpRequest request) {
        CapturedRequest snapshot = new CapturedRequest();
        snapshot.method = request.getMethod();
        snapshot.endpoint = request.getEndpoint();
        snapshot.body = request.getBody();
        snapshot.accept = request.getHeader('Accept');
        snapshot.contentType = request.getHeader('Content-Type');
        captured.add(snapshot);

        Boolean isPost = request.getMethod() == 'POST';

        switch on scenario {
            when UNAUTHORIZED {
                return response(401, 'Unauthorized', '{"errorMessages":["Client must be authenticated."],"errors":{}}');
            }
            when RATE_LIMITED {
                return response(429, 'Too Many Requests', '{"errorMessages":["Rate limit exceeded."],"errors":{}}');
            }
            when SERVER_ERROR {
                return response(500, 'Internal Server Error', '{"errorMessages":["Something went wrong."],"errors":{}}');
            }
            when MALFORMED_BODY {
                return response(200, 'OK', 'this is not json at all');
            }
            when POST_FAILS {
                return isPost
                    ? response(500, 'Internal Server Error', '{"errorMessages":["Transition failed."],"errors":{}}')
                    : response(200, 'OK', standardTransitions());
            }
            when NO_MATCHING_TRANSITION {
                return response(200, 'OK', doneOnlyTransitions());
            }
            when NO_TRANSITIONS_AT_ALL {
                return response(200, 'OK', '{"expand":"transitions","transitions":[]}');
            }
            when ALIAS_ONLY {
                return isPost ? response(204, 'No Content', '') : response(200, 'OK', aliasTransitions());
            }
            when else {
                return isPost ? response(204, 'No Content', '') : response(200, 'OK', standardTransitions());
            }
        }
    }

    /**
     * Note that each transition's own `name` differs from its `to.name`. That is what Jira really
     * looks like, and it is what proves the adapter matches on the destination status rather than
     * on the button label.
     */
    public static String standardTransitions() {
        return '{"expand":"transitions","transitions":[' +
            '{"id":"11","name":"Start Progress","to":{"id":"3","name":"In Progress"}},' +
            '{"id":"21","name":"Ready for Review","to":{"id":"4","name":"In Review"}},' +
            '{"id":"31","name":"Close Issue","to":{"id":"5","name":"Done"}}' +
            ']}';
    }

    /** Only a Done transition, so a request for In Progress has nowhere to go. */
    public static String doneOnlyTransitions() {
        return '{"expand":"transitions","transitions":[' +
            '{"id":"31","name":"Close Issue","to":{"id":"5","name":"Done"}}' +
            ']}';
    }

    /** Jira says 'Resolved'; our normalized vocabulary calls that 'Done'. */
    public static String aliasTransitions() {
        return '{"expand":"transitions","transitions":[' +
            '{"id":"41","name":"Resolve Issue","to":{"id":"6","name":"Resolved"}}' +
            ']}';
    }

    private static HttpResponse response(Integer statusCode, String status, String body) {
        HttpResponse res = new HttpResponse();
        res.setStatusCode(statusCode);
        res.setStatus(status);
        res.setHeader('Content-Type', 'application/json');
        res.setBody(body);
        return res;
    }
}