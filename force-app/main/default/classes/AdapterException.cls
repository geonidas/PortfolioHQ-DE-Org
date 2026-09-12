/**
 * Technical failure inside an adapter: the remote system could not be reached, refused the
 * credentials, or answered with something unusable.
 *
 * Business outcomes do NOT use this. "No transition available from the current state" is an
 * expected answer, not a fault, and comes back as a SyncResult outcome instead.
 */
public class AdapterException extends Exception {
}