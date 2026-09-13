/**
 * Transaction-scoped switch that stops inbound processing from bouncing straight back out.
 *
 * Scope is the important caveat: a static lives for one transaction only. The outbound trigger
 * must therefore consult this BEFORE it enqueues anything - the flag does not survive into an
 * async job, so checking it inside a Queueable would be checking a fresh, empty context.
 *
 * A depth counter rather than a boolean, so nested suppression unwinds correctly: an inner
 * resume must not lift an outer block.
 */
public class SyncContext {
    private static Integer suppressionDepth = 0;

    /** Begin a region whose DML must not trigger an outbound push. Always pair with resume. */
    public static void suppressOutbound() {
        suppressionDepth++;
    }

    /** End one suppression region. Safe to call more often than suppress; will not go negative. */
    public static void resumeOutbound() {
        if (suppressionDepth > 0) {
            suppressionDepth--;
        }
    }

    public static Boolean isOutboundSuppressed() {
        return suppressionDepth > 0;
    }

    @TestVisible
    private static void reset() {
        suppressionDepth = 0;
    }
}