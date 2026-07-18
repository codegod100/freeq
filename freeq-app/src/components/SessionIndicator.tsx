import { useEffect } from 'react';
import { useStore } from '../store';
import { joinAvSession, leaveAvSession, endAvSession, startAvSession, getNick } from '../irc/client';
import type { AvSession, AvParticipant } from '../store';

/** Shows active AV session status in the channel header.
 *  Polls the REST API to discover sessions. One-click to start/join + connect audio. */
export function SessionIndicator({ channel }: { channel: string }) {
  const avSessions = useStore((s) => s.avSessions);
  const activeAvSession = useStore((s) => s.activeAvSession);
  const avAudioActive = useStore((s) => s.avAudioActive);
  const authDid = useStore((s) => s.authDid);
  const connectionState = useStore((s) => s.connectionState);

  const isConnected = connectionState === 'connected';

  // Poll REST API for active session on this channel
  useEffect(() => {
    if (!isConnected || !channel.startsWith('#')) return;
    let cancelled = false;

    async function poll() {
      try {
        const resp = await fetch(`/api/v1/channels/${encodeURIComponent(channel)}/sessions`);
        if (!resp.ok || cancelled) return;
        const data = await resp.json();
        if (cancelled) return;

        if (data.active) {
          const store = useStore.getState();
          const existing = store.avSessions.get(data.active.id);
          if (!existing) {
            const participants = new Map<string, AvParticipant>();
            for (const p of data.active.participants || []) {
              participants.set(p.nick, {
                did: p.did || '',
                nick: p.nick,
                role: p.role || 'speaker',
                joinedAt: new Date(p.joined_at * 1000),
              });
            }
            const session: AvSession = {
              id: data.active.id,
              channel: data.active.channel,
              createdBy: data.active.created_by || '',
              createdByNick: data.active.created_by_nick || '',
              title: data.active.title || undefined,
              participants,
              state: 'active',
              startedAt: new Date(data.active.created_at * 1000),
              irohTicket: data.active.iroh_ticket || undefined,
            };
            store.updateAvSession(session);
          }
        }
      } catch {
        // Ignore fetch errors
      }
    }

    poll();
    const timer = setInterval(poll, 5000);
    return () => { cancelled = true; clearInterval(timer); };
  }, [channel, isConnected]);

  const session = [...avSessions.values()].find(
    (s) => s.channel?.toLowerCase() === channel.toLowerCase() && s.state === 'active'
  );

  // No session — show speaker icon to start one
  if (!session) {
    if (!authDid) return null;
    return (
      <button
        onClick={() => startAvSession(channel)}
        disabled={!isConnected}
        className={`p-1.5 rounded-lg ${
          isConnected
            ? 'text-fg-dim hover:text-accent hover:bg-bg-tertiary'
            : 'text-fg-dim/40 cursor-not-allowed'
        }`}
        title={isConnected ? 'Start voice/video session' : 'Not connected'}
      >
        <SpeakerIcon size={16} />
      </button>
    );
  }

  const isInSession = activeAvSession === session.id && avAudioActive;
  const participantCount = session.participants.size;
  const myNick = getNick();
  const isHost = session.createdByNick.toLowerCase() === myNick.toLowerCase();

  // One-click join: joins session + connects audio immediately
  const handleJoin = () => {
    joinAvSession(channel, session.id);
    useStore.getState().setAvAudioActive(true);
  };

  const handleLeave = () => {
    useStore.getState().setAvAudioActive(false);
    useStore.getState().setAvCameraOn(false);
    leaveAvSession(channel, session.id);
  };

  const handleEnd = () => {
    useStore.getState().setAvAudioActive(false);
    useStore.getState().setAvCameraOn(false);
    endAvSession(channel, session.id);
  };

  return (
    <div className="flex items-center gap-2">
      <div className={`flex items-center gap-1.5 px-2.5 py-1 rounded-lg text-xs font-medium ${
        isInSession ? 'bg-success/15 text-success' : 'bg-accent/10 text-accent'
      }`}>
        <SpeakerIcon size={12} />
        <span>{session.title || 'Voice'}</span>
        <span className="opacity-60">({participantCount})</span>
      </div>

      {!isInSession && (
        <button
          onClick={handleJoin}
          className="text-xs px-2.5 py-1 rounded-lg bg-accent text-white hover:bg-accent/90 font-medium"
        >
          Join
        </button>
      )}

      {isInSession && (
        <div className="flex items-center gap-1">
          <button
            onClick={handleLeave}
            className="text-xs px-2 py-1 rounded-lg bg-danger/10 text-danger hover:bg-danger/20 font-medium"
          >
            Leave
          </button>
          {isHost && (
            <button
              onClick={handleEnd}
              className="text-xs px-2 py-1 rounded-lg text-danger hover:bg-danger/10"
              title="End session for everyone"
            >
              End
            </button>
          )}
        </div>
      )}
    </div>
  );
}

export function SpeakerIcon({ size = 14 }: { size?: number }) {
  return (
    <svg width={size} height={size} viewBox="0 0 16 16" fill="currentColor">
      <path d="M11.536 14.01A8.473 8.473 0 0 0 14.026 8a8.473 8.473 0 0 0-2.49-6.01l-.708.707A7.476 7.476 0 0 1 13.025 8c0 2.071-.84 3.946-2.197 5.303l.708.707z"/>
      <path d="M10.121 12.596A6.48 6.48 0 0 0 12.025 8a6.48 6.48 0 0 0-1.904-4.596l-.707.707A5.483 5.483 0 0 1 11.025 8a5.483 5.483 0 0 1-1.61 3.89l.706.706z"/>
      <path d="M8.707 11.182A4.486 4.486 0 0 0 10.025 8a4.486 4.486 0 0 0-1.318-3.182L8 5.525A3.489 3.489 0 0 1 9.025 8 3.49 3.49 0 0 1 8 10.475l.707.707zM6.717 3.55A.5.5 0 0 1 7 4v8a.5.5 0 0 1-.812.39L3.825 10.5H1.5A.5.5 0 0 1 1 10V6a.5.5 0 0 1 .5-.5h2.325l2.363-1.89a.5.5 0 0 1 .529-.06z"/>
    </svg>
  );
}
