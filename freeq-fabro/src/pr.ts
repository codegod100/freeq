// Find the PR a Fabro run opened. Fabro pushes each run to the branch
// `fabro/run/<run-id>` and opens the PR after run_complete fires, so the
// lookup polls briefly instead of assuming it exists yet.
//
// Uses GitHub's REST API directly: freeq-irc/freeq is public, so no token is
// needed (60 req/h unauthenticated is plenty for a few runs a night); set
// GITHUB_TOKEN to raise the limit or for a private repo.

export type Fetch = typeof fetch;

export interface FindPrOptions {
  /** owner/name */
  repo: string;
  token?: string;
  fetch?: Fetch;
  attempts?: number;
  delayMs?: number;
}

export async function findRunPr(runId: string, opts: FindPrOptions): Promise<string | undefined> {
  const doFetch = opts.fetch ?? fetch;
  const attempts = opts.attempts ?? 12;
  const delayMs = opts.delayMs ?? 15_000;
  const owner = opts.repo.split("/")[0];
  const url =
    `https://api.github.com/repos/${opts.repo}/pulls?state=all` +
    `&head=${encodeURIComponent(`${owner}:fabro/run/${runId}`)}`;
  const headers: Record<string, string> = { accept: "application/vnd.github+json" };
  if (opts.token) headers.authorization = `Bearer ${opts.token}`;

  for (let i = 0; i < attempts; i++) {
    try {
      const res = await doFetch(url, { headers });
      if (res.ok) {
        const pulls = (await res.json()) as Array<{ html_url?: string }>;
        if (pulls[0]?.html_url) return pulls[0].html_url;
      }
    } catch {
      // Transient network failure — keep polling, then give up.
    }
    if (i < attempts - 1) await new Promise((r) => setTimeout(r, delayMs));
  }
  return undefined;
}
