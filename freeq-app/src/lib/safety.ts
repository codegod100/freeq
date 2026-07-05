import { useStore } from '../store';

/** Fixed report reasons — kept in sync with the iOS client. */
export const REPORT_REASONS = [
  'Spam',
  'Harassment',
  'Sexual content',
  'Violence',
  'Impersonation',
  'Other',
] as const;

export type ReportReason = (typeof REPORT_REASONS)[number];

/** Report a user: logs the report locally and blocks them immediately.
 *  Client-side safety layer — the log line is the audit trail until a
 *  server-side report endpoint exists. Escalation: abuse@freeq.at. */
export function reportUser(
  nick: string,
  did: string | undefined,
  reason: ReportReason,
  context?: { channel?: string; msgid?: string },
) {
  console.warn('[report]', {
    nick,
    did: did ?? null,
    reason,
    channel: context?.channel ?? null,
    msgid: context?.msgid ?? null,
    at: new Date().toISOString(),
  });
  useStore.getState().blockUser(nick, did);
}
