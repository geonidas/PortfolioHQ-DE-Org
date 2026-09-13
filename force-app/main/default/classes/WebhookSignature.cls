/**
 * HMAC verification for inbound webhooks.
 *
 * The MAC is computed over the raw request bytes. Deserialising and re-serialising a payload
 * changes whitespace and key order, which changes the digest, which breaks every signature - so
 * this class only ever sees a Blob and never a parsed object.
 *
 * Comparison goes through Crypto.verifyHMac rather than a String equality check: the platform
 * method is built for this and avoids leaking information through comparison timing.
 */
public with sharing class WebhookSignature {
    private static final String ALGORITHM = 'hmacSHA256';
    private static final String SHA256_PREFIX = 'sha256=';

    /**
     * Case-insensitive header lookup. Apex hands back whatever casing the sender used, and HTTP
     * header names are case-insensitive by specification, so an exact-key get is a latent bug.
     */
    public static String header(Map<String, String> headers, String name) {
        if (headers == null || String.isBlank(name)) {
            return null;
        }
        for (String key : headers.keySet()) {
            if (key != null && key.equalsIgnoreCase(name)) {
                return headers.get(key);
            }
        }
        return null;
    }

    /**
     * @param rawBody         request body exactly as received, never re-serialised
     * @param signatureHeader header value, with or without the sha256= prefix
     * @param secret          shared signing secret; null or blank always fails
     * @return                true only when the payload verifiably came from the holder of the secret
     */
    public static Boolean isValid(Blob rawBody, String signatureHeader, String secret) {
        // Every missing input is a rejection, not a bypass.
        if (rawBody == null || String.isBlank(signatureHeader) || String.isBlank(secret)) {
            return false;
        }

        String hex = signatureHeader.trim();
        if (hex.toLowerCase().startsWith(SHA256_PREFIX)) {
            hex = hex.substring(SHA256_PREFIX.length());
        }
        if (String.isBlank(hex)) {
            return false;
        }

        Blob provided;
        try {
            provided = EncodingUtil.convertFromHex(hex);
        } catch (Exception e) {
            // Malformed hex is a failed signature, not an error worth surfacing to the caller.
            return false;
        }

        try {
            return Crypto.verifyHMac(ALGORITHM, rawBody, Blob.valueOf(secret), provided);
        } catch (Exception e) {
            return false;
        }
    }

    /**
     * Signature for a body and secret, in the wire format Jira sends. Used by tests to build a
     * genuinely valid request rather than asserting against a hardcoded digest.
     */
    @TestVisible
    private static String sign(Blob rawBody, String secret) {
        Blob mac = Crypto.generateMac(ALGORITHM, rawBody, Blob.valueOf(secret));
        return SHA256_PREFIX + EncodingUtil.convertToHex(mac);
    }
}