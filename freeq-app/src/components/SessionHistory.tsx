import { useState, useEffect } from 'react';

interface SessionSummary {
  id: string;
  created_by: string;
  created_at: number;
  state: { Active: null } | { Ended: { ended_at: number; ended_by: string | null } };
  title: string | null;
}

interface Artifact {
  id: string;
  session_id: string;
  kind: string;
  created_at: number;
  created_by: string | null;
  content_ref: string;
  content_type: string;
  visibility: string;
  title: string | null;
}

/** Panel showing past AV sessions for the current channel. */
export function SessionHistory({ channel }: { channel: string }) {
  const [sessions, setSessions] = useState<SessionSummary[]>([]);
  const [expanded, setExpanded] = useState<string | null>(null);
  const [artifacts, setArtifacts] = useState<Record<string, Artifact[]>>({});
  const [loading, setLoading] = useState(false);

  useEffect(() => {
    let cancelled = false;
    setLoading(true);
    fetch(`/api/v1/channels/${encodeURIComponent(channel)}/sessions`)
      .then((r) => r.json())
      .then((data) => {
        if (!cancelled) {
          setSessions(data.recent || []);
          setLoading(false);
        }
      })
      .catch(() => { if (!cancelled) setLoading(false); });
    return () => { cancelled = true; };
  }, [channel]);

  const loadArtifacts = (sessionId: string) => {
    if (artifacts[sessionId]) {
      setExpanded(expanded === sessionId ? null : sessionId);
      return;
    }
    fetch(`/api/v1/sessions/${sessionId}/artifacts`)
      .then((r) => r.json())
      .then((data) => {
        setArtifacts((prev) => ({ ...prev, [sessionId]: data.artifacts || [] }));
        setExpanded(sessionId);
      });
  };

  if (loading) {
    return <div className="p-4 text-fg-dim text-sm">Loading session history...</div>;
  }

  if (sessions.length === 0) {
    return <div className="p-4 text-fg-dim text-sm">No past sessions in this channel.</div>;
  }

  return (
    <div className="p-3 space-y-2">
      <h3 className="text-xs uppercase tracking-wider text-fg-dim font-bold px-1 mb-2">
        Session History
      </h3>
      {sessions.map((s) => {
        const isExpanded = expanded === s.id;
        const ended = typeof s.state === 'object' && 'Ended' in s.state;
        const endedAt = ended ? (s.state as any).Ended.ended_at : null;
        const duration = endedAt ? Math.round((endedAt - s.created_at) / 60) : null;
        const startDate = new Date(s.created_at * 1000);

        return (
          <div key={s.id} className="bg-bg-tertiary rounded-lg overflow-hidden">
            <button
              onClick={() => loadArtifacts(s.id)}
              className="w-full text-left px-3 py-2 hover:bg-surface transition-colors"
            >
              <div className="flex items-center justify-between">
                <div className="flex items-center gap-2 min-w-0">
                  <span className="text-accent text-xs">
                    {ended ? '●' : '◉'}
                  </span>
                  <span className="text-sm text-fg truncate">
                    {s.title || 'Voice session'}
                  </span>
                </div>
                <div className="flex items-center gap-2 text-xs text-fg-dim shrink-0">
                  {duration != null && <span>{duration}m</span>}
                  <span>{formatDate(startDate)}</span>
                  <svg className={`w-3 h-3 transition-transform ${isExpanded ? 'rotate-180' : ''}`} viewBox="0 0 16 16" fill="currentColor">
                    <path d="M4 6l4 4 4-4" stroke="currentColor" strokeWidth="2" fill="none" strokeLinecap="round" strokeLinejoin="round"/>
                  </svg>
                </div>
              </div>
            </button>

            {isExpanded && (
              <div className="px-3 pb-3 pt-1 border-t border-border animate-fadeIn">
                <ArtifactList artifacts={artifacts[s.id] || []} />
              </div>
            )}
          </div>
        );
      })}
    </div>
  );
}

function ArtifactList({ artifacts }: { artifacts: Artifact[] }) {
  if (artifacts.length === 0) {
    return <div className="text-xs text-fg-dim py-1">No artifacts yet.</div>;
  }

  return (
    <div className="space-y-1.5">
      {artifacts.map((a) => (
        <ArtifactCard key={a.id} artifact={a} />
      ))}
    </div>
  );
}

function ArtifactCard({ artifact }: { artifact: Artifact }) {
  const [expanded, setExpanded] = useState(false);

  const icon = {
    transcript: '📝',
    summary: '📋',
    recording: '🎙',
    decisions: '✅',
    tasks: '📌',
  }[artifact.kind] || '📎';

  const isInline = artifact.content_ref.startsWith('inline:');
  const content = isInline ? artifact.content_ref.slice(7) : null;

  return (
    <div className="bg-surface rounded-lg px-2.5 py-2">
      <button
        onClick={() => content && setExpanded(!expanded)}
        className="w-full text-left flex items-center gap-2"
      >
        <span className="text-sm">{icon}</span>
        <span className="text-sm text-fg flex-1 truncate">
          {artifact.title || artifact.kind}
        </span>
        <span className="text-[10px] text-fg-dim uppercase">{artifact.kind}</span>
      </button>
      {expanded && content && (
        <div className="mt-2 pt-2 border-t border-border text-sm text-fg-muted whitespace-pre-wrap">
          {content}
        </div>
      )}
      {!isInline && (
        <a
          href={artifact.content_ref}
          target="_blank"
          rel="noopener noreferrer"
          className="text-xs text-accent hover:underline mt-1 block"
        >
          View artifact
        </a>
      )}
    </div>
  );
}

function formatDate(d: Date): string {
  const now = new Date();
  const diff = now.getTime() - d.getTime();
  if (diff < 86400000) return d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  if (diff < 604800000) return d.toLocaleDateString([], { weekday: 'short' });
  return d.toLocaleDateString([], { month: 'short', day: 'numeric' });
}
