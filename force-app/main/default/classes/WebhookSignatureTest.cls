@IsTest
private class WebhookSignatureTest {
    @IsTest
    static void acceptsAGenuineSignature() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        Blob body = Blob.valueOf('{"webhookEvent":"jira:issue_updated"}');

        Assert.isTrue(
            WebhookSignature.isValid(body, WebhookSignature.sign(body, secret), secret),
            'A signature produced with the secret must verify against it.'
        );
    }

    @IsTest
    static void acceptsASignatureWithoutThePrefix() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        Blob body = Blob.valueOf('{"a":1}');
        String bare = WebhookSignature.sign(body, secret).substringAfter('sha256=');

        Assert.isTrue(WebhookSignature.isValid(body, bare, secret), 'A bare hex digest should also verify.');
    }

    @IsTest
    static void rejectsAPayloadAlteredAfterSigning() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        Blob original = Blob.valueOf('{"status":"To Do"}');
        String signature = WebhookSignature.sign(original, secret);

        // One character different is a different body.
        Assert.isFalse(
            WebhookSignature.isValid(Blob.valueOf('{"status":"Done"}'), signature, secret),
            'A tampered body must not verify against the original signature.'
        );
    }

    @IsTest
    static void rejectsASignatureFromADifferentSecret() {
        Blob body = Blob.valueOf('{"a":1}');
        String signature = WebhookSignature.sign(body, JiraWebhookPayloadFactory.randomSecret());

        Assert.isFalse(
            WebhookSignature.isValid(body, signature, JiraWebhookPayloadFactory.randomSecret()),
            'Holding a different secret must not be enough.'
        );
    }

    @IsTest
    static void rejectsEveryMissingInput() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        Blob body = Blob.valueOf('{"a":1}');
        String signature = WebhookSignature.sign(body, secret);

        Assert.isFalse(WebhookSignature.isValid(null, signature, secret), 'No body.');
        Assert.isFalse(WebhookSignature.isValid(body, null, secret), 'No signature header.');
        Assert.isFalse(WebhookSignature.isValid(body, '   ', secret), 'Blank signature header.');
        Assert.isFalse(WebhookSignature.isValid(body, 'sha256=', secret), 'Prefix with no digest.');
        // The one that matters most: an unconfigured org must reject, never bypass.
        Assert.isFalse(WebhookSignature.isValid(body, signature, null), 'No secret.');
        Assert.isFalse(WebhookSignature.isValid(body, signature, ''), 'Blank secret.');
    }

    @IsTest
    static void rejectsMalformedHexWithoutThrowing() {
        String secret = JiraWebhookPayloadFactory.randomSecret();
        Blob body = Blob.valueOf('{"a":1}');

        for (String junk : new List<String>{ 'sha256=zzzz', 'sha256=abc', 'not hex at all', '=' }) {
            Assert.isFalse(
                WebhookSignature.isValid(body, junk, secret),
                'Garbage must be a quiet rejection, not an exception: ' + junk
            );
        }
    }

    @IsTest
    static void headerLookupIgnoresCase() {
        Map<String, String> headers = new Map<String, String>{ 'x-hub-signature' => 'sha256=abcd' };

        // HTTP header names are case-insensitive and Apex preserves whatever the sender used,
        // so an exact-key get would be a signature that mysteriously fails in production.
        Assert.areEqual('sha256=abcd', WebhookSignature.header(headers, 'X-Hub-Signature'), 'Lowercase key.');
        Assert.areEqual('sha256=abcd', WebhookSignature.header(headers, 'x-HUB-signature'), 'Mixed case.');
        Assert.isNull(WebhookSignature.header(headers, 'X-Other'), 'Unrelated header.');
        Assert.isNull(WebhookSignature.header(null, 'X-Hub-Signature'), 'Null map.');
        Assert.isNull(WebhookSignature.header(headers, null), 'Null name.');
    }
}
