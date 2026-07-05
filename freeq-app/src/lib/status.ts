/** Parse an AWAY reason into display text.
 *
 *  freeq clients may set structured away state as JSON (e.g.
 *  `{"status":"lunch","state":"idle"}`); plain IRC clients send free text.
 *  Returns the human-readable status string, or null when there's nothing
 *  to show (not away / empty reason).
 */
export function parseAwayStatus(away: string | null | undefined): string | null {
  if (away == null || away === '') return null;
  try {
    const j = JSON.parse(away);
    return j.status || j.state || away;
  } catch {
    return away;
  }
}
