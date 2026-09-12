/**
 * Jira Cloud implementation of IWorkItemAdapter.
 *
 * Everything Jira-shaped is confined here: the named credential, the /rest/api/3 paths, the
 * response envelope, and the mapping between Jira's workflow status names and our normalized
 * Work_Item__c.Status__c values.
 *
 * A status change is two callouts, not one. Jira will not accept a target status directly - you
 * ask which transitions are legal from the issue's current state, then post the id of the one
 * whose TARGET status matches. Transition ids are per-workflow and are never hardcoded.
 *
 * Callout budget: 2 calls per item, against a limit of 100 callouts and 120 seconds of cumulative
 * callout time per transaction. The 120 seconds is the tighter constraint in practice - see
 * WorkItemSyncService for how work is chunked.
 */
public with sharing class JiraAdapter implements IWorkItemAdapter {
    @TestVisible
    private static final String NAMED_CREDENTIAL = 'Jira_Classic';
    @TestVisible
    private static final String SYSTEM_NAMESPACE = 'jira';
    private static final String API_BASE = '/rest/api/3';
    private static final Integer TIMEOUT_MS = 10000;
    private static final Integer ENDPOINT_MAX = 255;
    private static final Integer BODY_MAX = 32768;

    /**
     * Jira workflow status names that count as each of our normalized statuses.
     *
     * Hardcoded on purpose for this build: Field_Mapping__mdt is out of scope, and this is the
     * table it will replace. Names are compared normalized - lowercased, whitespace collapsed.
     */
    private static final Map<String, Set<String>> STATUS_ALIASES = new Map<String, Set<String>>{
        'To Do' => new Set<String>{ 'to do', 'todo', 'open', 'backlog', 'new', 'reopened' },
        'In Progress' => new Set<String>{ 'in progress', 'inprogress', 'in development', 'started' },
        'In Review' => new Set<String>{ 'in review', 'review', 'code review', 'in qa', 'qa' },
        'Done' => new Set<String>{ 'done', 'closed', 'resolved', 'complete', 'completed' }
    };

    private final List<Integration_Log__c> pendingLogs = new List<Integration_Log__c>();

    public List<Integration_Log__c> drainLogs() {
        List<Integration_Log__c> drained = new List<Integration_Log__c>(pendingLogs);
        pendingLogs.clear();
        return drained;
    }

    public SyncResult updateStatus(Work_Item__c item, String targetStatus) {
        SyncResult rejection = validate(item, targetStatus);
        if (rejection != null) {
            return rejection;
        }

        String externalId = item.External_Id__c;
        String rawId = ExternalIdUtil.rawIdOf(externalId);

        // Skip both callouts only when Salesforce already believes the remote agrees: the status
        // matches AND the last sync succeeded. Matching status alone is not enough - the service
        // pushes item.Status__c as its own target, so that test would always pass and nothing
        // would ever sync. Sync_Status__c is what makes the belief credible.
        if (normalize(item.Status__c) == normalize(targetStatus) && item.Sync_Status__c == 'Synced') {
            SyncResult result = SyncResult.alreadyInTargetStatus(targetStatus);
            result.workItemId = item.Id;
            result.externalId = externalId;
            return result;
        }

        HttpResponse listing;
        try {
            listing = send('GET', transitionsPath(rawId), null, item.Id);
        } catch (Exception e) {
            return stamp(
                SyncResult.failure(SyncResult.Outcome.CALLOUT_FAILED, describe(e), 0),
                item,
                externalId
            );
        }
        if (listing.getStatusCode() < 200 || listing.getStatusCode() >= 300) {
            return stamp(toFailure(listing, 'listing transitions'), item, externalId);
        }

        List<TransitionOption> options;
        try {
            options = parseTransitions(listing.getBody());
        } catch (Exception e) {
            return stamp(
                SyncResult.failure(
                    SyncResult.Outcome.REMOTE_ERROR,
                    'Could not parse the transitions response: ' + describe(e),
                    listing.getStatusCode()
                ),
                item,
                externalId
            );
        }

        TransitionOption chosen = match(options, targetStatus);
        if (chosen == null) {
            // Expected answer, not a fault: Jira workflows genuinely forbid some moves.
            return stamp(
                SyncResult.failure(
                    SyncResult.Outcome.NO_TRANSITION_AVAILABLE,
                    'No transition to "' + targetStatus + '" is available from the current state. Available: ' +
                    describeOptions(options),
                    listing.getStatusCode()
                ),
                item,
                externalId
            );
        }

        HttpResponse applied;
        try {
            applied = send('POST', transitionsPath(rawId), transitionPayload(chosen.id), item.Id);
        } catch (Exception e) {
            return stamp(
                SyncResult.failure(SyncResult.Outcome.CALLOUT_FAILED, describe(e), 0),
                item,
                externalId
            );
        }
        if (applied.getStatusCode() < 200 || applied.getStatusCode() >= 300) {
            return stamp(toFailure(applied, 'applying transition ' + chosen.id), item, externalId);
        }

        return stamp(SyncResult.success(targetStatus, applied.getStatusCode()), item, externalId);
    }

    public List<TransitionOption> fetchAvailableTransitions(String externalId) {
        if (!ExternalIdUtil.belongsTo(externalId, SYSTEM_NAMESPACE)) {
            throw new AdapterException('Not a Jira external id: ' + externalId);
        }

        HttpResponse response;
        try {
            response = send('GET', transitionsPath(ExternalIdUtil.rawIdOf(externalId)), null, null);
        } catch (Exception e) {
            throw new AdapterException('Could not reach Jira: ' + describe(e), e);
        }
        if (response.getStatusCode() < 200 || response.getStatusCode() >= 300) {
            throw new AdapterException(
                'Jira returned ' + response.getStatusCode() + ' listing transitions for ' + externalId
            );
        }
        return parseTransitions(response.getBody());
    }

    // ---------- Jira specifics ----------

    private String transitionsPath(String rawId) {
        return API_BASE + '/issue/' + EncodingUtil.urlEncode(rawId, 'UTF-8') + '/transitions';
    }

    private String transitionPayload(String transitionId) {
        return JSON.serialize(
            new Map<String, Object>{ 'transition' => new Map<String, Object>{ 'id' => transitionId } }
        );
    }

    /**
     * Reads Jira's transitions envelope. Matching is on to.name - the status the issue LANDS in -
     * not on the transition's own name, which is a button label like "Start Progress".
     */
    private List<TransitionOption> parseTransitions(String body) {
        List<TransitionOption> options = new List<TransitionOption>();
        if (String.isBlank(body)) {
            return options;
        }
        Map<String, Object> envelope = (Map<String, Object>) JSON.deserializeUntyped(body);
        Object raw = envelope.get('transitions');
        if (!(raw instanceof List<Object>)) {
            return options;
        }
        for (Object entry : (List<Object>) raw) {
            Map<String, Object> transition = (Map<String, Object>) entry;
            Object target = transition.get('to');
            if (!(target instanceof Map<String, Object>)) {
                continue;
            }
            String targetName = (String) ((Map<String, Object>) target).get('name');
            Object rawTransitionId = transition.get('id');
            // String.valueOf(null) is the literal 'null', which would sail past a blank check.
            String transitionId = rawTransitionId == null ? null : String.valueOf(rawTransitionId);
            if (String.isNotBlank(transitionId) && String.isNotBlank(targetName)) {
                options.add(new TransitionOption(transitionId, targetName));
            }
        }
        return options;
    }

    /**
     * Picks the transition landing in targetStatus: exact name match first, then the alias table.
     */
    private TransitionOption match(List<TransitionOption> options, String targetStatus) {
        String wanted = normalize(targetStatus);
        for (TransitionOption option : options) {
            if (normalize(option.targetStatus) == wanted) {
                return option;
            }
        }
        Set<String> aliases = STATUS_ALIASES.get(targetStatus);
        if (aliases != null) {
            for (TransitionOption option : options) {
                if (aliases.contains(normalize(option.targetStatus))) {
                    return option;
                }
            }
        }
        return null;
    }

    // ---------- HTTP + logging ----------

    /**
     * Issues one callout and buffers exactly one Integration_Log__c row for it, success or
     * failure. The row is buffered rather than inserted: DML here would break the next callout
     * in the same transaction.
     */
    private HttpResponse send(String method, String path, String body, Id workItemId) {
        HttpRequest request = new HttpRequest();
        request.setEndpoint('callout:' + NAMED_CREDENTIAL + path);
        request.setMethod(method);
        request.setTimeout(TIMEOUT_MS);
        request.setHeader('Accept', 'application/json');
        if (body != null) {
            request.setHeader('Content-Type', 'application/json');
            request.setBody(body);
        }

        Long startedAt = System.currentTimeMillis();
        try {
            HttpResponse response = new Http().send(request);
            log(method, path, body, workItemId, startedAt, response, null);
            return response;
        } catch (Exception e) {
            log(method, path, body, workItemId, startedAt, null, e);
            throw e;
        }
    }

    private void log(
        String method,
        String path,
        String body,
        Id workItemId,
        Long startedAt,
        HttpResponse response,
        Exception error
    ) {
        Integer status = response == null ? 0 : response.getStatusCode();
        pendingLogs.add(
            new Integration_Log__c(
                Direction__c = 'Outbound',
                Endpoint__c = truncate('callout:' + NAMED_CREDENTIAL + path, ENDPOINT_MAX),
                HTTP_Method__c = method,
                Status_Code__c = status,
                Duration_ms__c = System.currentTimeMillis() - startedAt,
                Request_Body__c = truncate(body, BODY_MAX),
                Response_Body__c = response == null ? null : truncate(response.getBody(), BODY_MAX),
                Error_Message__c = error == null ? null : truncate(describe(error), BODY_MAX),
                Work_Item__c = workItemId,
                Is_Success__c = status >= 200 && status < 300
            )
        );
    }

    // ---------- helpers ----------

    private SyncResult validate(Work_Item__c item, String targetStatus) {
        if (item == null) {
            return SyncResult.failure(SyncResult.Outcome.BAD_REQUEST, 'No work item supplied.', null);
        }
        if (String.isBlank(targetStatus)) {
            return stamp(
                SyncResult.failure(SyncResult.Outcome.BAD_REQUEST, 'No target status supplied.', null),
                item,
                item.External_Id__c
            );
        }
        if (targetStatus == 'Unspecified') {
            return stamp(
                SyncResult.failure(
                    SyncResult.Outcome.BAD_REQUEST,
                    'Unspecified is a placeholder for an unmapped status and cannot be a transition target.',
                    null
                ),
                item,
                item.External_Id__c
            );
        }
        if (!STATUS_ALIASES.containsKey(targetStatus)) {
            return stamp(
                SyncResult.failure(
                    SyncResult.Outcome.BAD_REQUEST,
                    'Not a recognised Status__c value: ' + targetStatus,
                    null
                ),
                item,
                item.External_Id__c
            );
        }
        if (!ExternalIdUtil.belongsTo(item.External_Id__c, SYSTEM_NAMESPACE)) {
            return stamp(
                SyncResult.failure(
                    SyncResult.Outcome.BAD_REQUEST,
                    'Work item has no usable Jira external id: ' + item.External_Id__c,
                    null
                ),
                item,
                item.External_Id__c
            );
        }
        return null;
    }

    private SyncResult toFailure(HttpResponse response, String phase) {
        Integer status = response.getStatusCode();
        SyncResult.Outcome outcome;
        if (status == 401 || status == 403) {
            outcome = SyncResult.Outcome.UNAUTHORIZED;
        } else if (status == 429) {
            outcome = SyncResult.Outcome.RATE_LIMITED;
        } else {
            outcome = SyncResult.Outcome.REMOTE_ERROR;
        }
        return SyncResult.failure(
            outcome,
            'Jira returned ' + status + ' ' + response.getStatus() + ' while ' + phase + '.',
            status
        );
    }

    private SyncResult stamp(SyncResult result, Work_Item__c item, String externalId) {
        result.workItemId = item == null ? null : item.Id;
        result.externalId = externalId;
        return result;
    }

    private String describeOptions(List<TransitionOption> options) {
        if (options.isEmpty()) {
            return 'none';
        }
        List<String> names = new List<String>();
        for (TransitionOption option : options) {
            names.add(option.targetStatus + ' (id ' + option.id + ')');
        }
        return String.join(names, ', ');
    }

    private static String describe(Exception e) {
        return e.getTypeName() + ': ' + e.getMessage();
    }

    private static String normalize(String value) {
        return value == null ? '' : value.trim().toLowerCase().replaceAll('\\s+', ' ');
    }

    private static String truncate(String value, Integer maxLength) {
        if (value == null || value.length() <= maxLength) {
            return value;
        }
        return value.substring(0, maxLength - 3) + '...';
    }
}