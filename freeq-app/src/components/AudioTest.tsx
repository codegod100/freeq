import { useEffect, useRef, useState, useCallback } from 'react';

/**
 * Zoom-style local speaker + microphone test. Deliberately does NOT touch the
 * MoQ/SFU call path — it exercises the browser's own audio hardware directly
 * (Web Audio tone out, getUserMedia + AnalyserNode in), so it works and is
 * meaningful even when a call itself wouldn't connect.
 *
 * - Test Speaker: loops a gentle chime through the selected output device (via
 *   an <audio> element's setSinkId) with a live output level bar, so you can
 *   confirm playback even before you hear it.
 * - Test Microphone: shows a live input level meter from the selected mic, and
 *   can record a few seconds and play it back through the selected speaker.
 */

type Device = { deviceId: string; label: string };

// Widely-supported output-device routing: setSinkId lives on HTMLMediaElement.
type SinkAudio = HTMLAudioElement & { setSinkId?: (id: string) => Promise<void> };

const BAR_COUNT = 16;

export function AudioTest() {
  const [inputs, setInputs] = useState<Device[]>([]);
  const [outputs, setOutputs] = useState<Device[]>([]);
  const [selectedMic, setSelectedMic] = useState('');
  const [selectedSpeaker, setSelectedSpeaker] = useState('');
  const [sinkSupported, setSinkSupported] = useState(true);

  const [speakerPlaying, setSpeakerPlaying] = useState(false);
  const [speakerLevel, setSpeakerLevel] = useState(0);

  const [micTesting, setMicTesting] = useState(false);
  const [micLevel, setMicLevel] = useState(0);
  const [micError, setMicError] = useState<string | null>(null);

  const [recording, setRecording] = useState(false);
  const [playbackUrl, setPlaybackUrl] = useState<string | null>(null);

  // ── Device enumeration ──────────────────────────────────────
  const refreshDevices = useCallback(async () => {
    try {
      const all = await navigator.mediaDevices.enumerateDevices();
      setInputs(all.filter((d) => d.kind === 'audioinput' && d.deviceId)
        .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `Microphone ${i + 1}` })));
      setOutputs(all.filter((d) => d.kind === 'audiooutput' && d.deviceId)
        .map((d, i) => ({ deviceId: d.deviceId, label: d.label || `Speaker ${i + 1}` })));
    } catch { /* enumeration can fail before permission; that's fine */ }
  }, []);

  useEffect(() => {
    setSinkSupported(typeof (document.createElement('audio') as SinkAudio).setSinkId === 'function');
    refreshDevices();
    navigator.mediaDevices?.addEventListener('devicechange', refreshDevices);
    return () => navigator.mediaDevices?.removeEventListener('devicechange', refreshDevices);
  }, [refreshDevices]);

  // ── Speaker test ────────────────────────────────────────────
  const speakerCtx = useRef<AudioContext | null>(null);
  const speakerAudioEl = useRef<SinkAudio | null>(null);
  const speakerRAF = useRef<number | null>(null);
  const speakerLoop = useRef<number | null>(null);

  const stopSpeaker = useCallback(() => {
    if (speakerLoop.current) { clearInterval(speakerLoop.current); speakerLoop.current = null; }
    if (speakerRAF.current) { cancelAnimationFrame(speakerRAF.current); speakerRAF.current = null; }
    speakerAudioEl.current?.pause();
    speakerAudioEl.current = null;
    speakerCtx.current?.close().catch(() => {});
    speakerCtx.current = null;
    setSpeakerPlaying(false);
    setSpeakerLevel(0);
  }, []);

  const startSpeaker = useCallback(async () => {
    const ctx = new AudioContext();
    speakerCtx.current = ctx;
    const dest = ctx.createMediaStreamDestination();
    const analyser = ctx.createAnalyser();
    analyser.fftSize = 256;
    analyser.connect(dest);

    // Route the tone through an <audio> element so we can setSinkId to the
    // chosen output device (broader support than AudioContext.setSinkId).
    const el = document.createElement('audio') as SinkAudio;
    el.srcObject = dest.stream;
    if (selectedSpeaker && el.setSinkId) { try { await el.setSinkId(selectedSpeaker); } catch { /* keep default */ } }
    el.play().catch(() => {});
    speakerAudioEl.current = el;

    // A warm three-note arpeggio (C5–E5–G5) that repeats — clearly audible,
    // not a harsh beep.
    const notes = [523.25, 659.25, 783.99];
    const chime = () => {
      const t = ctx.currentTime;
      notes.forEach((freq, i) => {
        const osc = ctx.createOscillator();
        const gain = ctx.createGain();
        osc.type = 'sine';
        osc.frequency.value = freq;
        osc.connect(gain);
        gain.connect(analyser);
        const start = t + i * 0.14;
        gain.gain.setValueAtTime(0, start);
        gain.gain.linearRampToValueAtTime(0.18, start + 0.02);
        gain.gain.exponentialRampToValueAtTime(0.0008, start + 0.55);
        osc.start(start);
        osc.stop(start + 0.6);
      });
    };
    chime();
    speakerLoop.current = window.setInterval(chime, 1300);

    // Live output level from the analyser.
    const buf = new Uint8Array(analyser.frequencyBinCount);
    const tick = () => {
      analyser.getByteFrequencyData(buf);
      let sum = 0;
      for (const v of buf) sum += v;
      setSpeakerLevel(Math.min(1, (sum / buf.length) / 90));
      speakerRAF.current = requestAnimationFrame(tick);
    };
    tick();
    setSpeakerPlaying(true);
  }, [selectedSpeaker]);

  // ── Microphone test ─────────────────────────────────────────
  const micStream = useRef<MediaStream | null>(null);
  const micCtx = useRef<AudioContext | null>(null);
  const micRAF = useRef<number | null>(null);
  const recorder = useRef<MediaRecorder | null>(null);
  const chunks = useRef<Blob[]>([]);

  const stopMic = useCallback(() => {
    if (micRAF.current) { cancelAnimationFrame(micRAF.current); micRAF.current = null; }
    micStream.current?.getTracks().forEach((t) => t.stop());
    micStream.current = null;
    micCtx.current?.close().catch(() => {});
    micCtx.current = null;
    setMicTesting(false);
    setMicLevel(0);
  }, []);

  const startMic = useCallback(async () => {
    setMicError(null);
    try {
      const stream = await navigator.mediaDevices.getUserMedia({
        audio: selectedMic ? { deviceId: { exact: selectedMic } } : true,
      });
      micStream.current = stream;
      // Labels populate after permission — refresh so the pickers show names.
      refreshDevices();

      const ctx = new AudioContext();
      micCtx.current = ctx;
      const source = ctx.createMediaStreamSource(stream);
      const analyser = ctx.createAnalyser();
      analyser.fftSize = 1024;
      source.connect(analyser);

      const buf = new Float32Array(analyser.fftSize);
      const tick = () => {
        analyser.getFloatTimeDomainData(buf);
        let sum = 0;
        for (const v of buf) sum += v * v;
        const rms = Math.sqrt(sum / buf.length);
        // Gentle non-linear scaling so normal speech fills most of the meter.
        setMicLevel(Math.min(1, rms * 4.2));
        micRAF.current = requestAnimationFrame(tick);
      };
      tick();
      setMicTesting(true);
    } catch (e) {
      const err = e as { name?: string };
      setMicError(err.name === 'NotAllowedError' ? 'Microphone permission denied.'
        : err.name === 'NotFoundError' ? 'No microphone found.'
        : 'Could not open the microphone.');
    }
  }, [selectedMic, refreshDevices]);

  const startRecording = useCallback(() => {
    if (!micStream.current) return;
    chunks.current = [];
    if (playbackUrl) { URL.revokeObjectURL(playbackUrl); setPlaybackUrl(null); }
    const rec = new MediaRecorder(micStream.current);
    rec.ondataavailable = (e) => { if (e.data.size) chunks.current.push(e.data); };
    rec.onstop = () => {
      const blob = new Blob(chunks.current, { type: rec.mimeType || 'audio/webm' });
      setPlaybackUrl(URL.createObjectURL(blob));
      setRecording(false);
    };
    rec.start();
    recorder.current = rec;
    setRecording(true);
    // Cap at 5s.
    window.setTimeout(() => { if (rec.state === 'recording') rec.stop(); }, 5000);
  }, [playbackUrl]);

  const playBack = useCallback(async () => {
    if (!playbackUrl) return;
    const el = document.createElement('audio') as SinkAudio;
    el.src = playbackUrl;
    if (selectedSpeaker && el.setSinkId) { try { await el.setSinkId(selectedSpeaker); } catch { /* default */ } }
    el.play().catch(() => {});
  }, [playbackUrl, selectedSpeaker]);

  // Cleanup everything on unmount.
  useEffect(() => () => { stopSpeaker(); stopMic(); if (playbackUrl) URL.revokeObjectURL(playbackUrl); },
    // eslint-disable-next-line react-hooks/exhaustive-deps
    []);

  return (
    <div className="space-y-6">
      {/* ── Speaker ── */}
      <div className="space-y-3">
        <div className="flex items-center gap-2">
          <span className="text-lg">🔊</span>
          <span className="font-medium">Test speaker</span>
        </div>
        <select
          value={selectedSpeaker}
          onChange={(e) => setSelectedSpeaker(e.target.value)}
          disabled={!sinkSupported}
          className="w-full bg-bg-tertiary text-fg rounded px-2 py-1.5 text-sm"
        >
          <option value="">{sinkSupported ? 'System default output' : 'Default output (device switching not supported here)'}</option>
          {outputs.map((d) => <option key={d.deviceId} value={d.deviceId}>{d.label}</option>)}
        </select>
        <Meter level={speakerLevel} active={speakerPlaying} tint="accent" />
        <div className="flex items-center gap-3">
          <button
            onClick={speakerPlaying ? stopSpeaker : startSpeaker}
            className={`px-3 py-1.5 rounded text-sm font-medium ${speakerPlaying ? 'bg-red-500/20 text-red-300' : 'bg-accent/20 text-accent'}`}
          >
            {speakerPlaying ? 'Stop' : 'Play test sound'}
          </button>
          {speakerPlaying && <span className="text-xs text-fg-dim">Hear the chime? Your speaker works.</span>}
        </div>
      </div>

      {/* ── Microphone ── */}
      <div className="space-y-3">
        <div className="flex items-center gap-2">
          <span className="text-lg">🎤</span>
          <span className="font-medium">Test microphone</span>
        </div>
        <select
          value={selectedMic}
          onChange={(e) => setSelectedMic(e.target.value)}
          className="w-full bg-bg-tertiary text-fg rounded px-2 py-1.5 text-sm"
        >
          <option value="">System default microphone</option>
          {inputs.map((d) => <option key={d.deviceId} value={d.deviceId}>{d.label}</option>)}
        </select>
        <Meter level={micLevel} active={micTesting} tint="green" />
        {micError && <div className="text-xs text-red-400">{micError}</div>}
        <div className="flex flex-wrap items-center gap-3">
          <button
            onClick={micTesting ? stopMic : startMic}
            className={`px-3 py-1.5 rounded text-sm font-medium ${micTesting ? 'bg-red-500/20 text-red-300' : 'bg-accent/20 text-accent'}`}
          >
            {micTesting ? 'Stop' : 'Test microphone'}
          </button>
          {micTesting && !recording && (
            <button onClick={startRecording} className="px-3 py-1.5 rounded text-sm font-medium bg-bg-tertiary text-fg">
              Record & play back
            </button>
          )}
          {recording && <span className="text-xs text-red-300 animate-pulse">● Recording…</span>}
          {playbackUrl && !recording && (
            <button onClick={playBack} className="px-3 py-1.5 rounded text-sm font-medium bg-bg-tertiary text-fg">
              ▶ Play recording
            </button>
          )}
          {micTesting && !recording && !playbackUrl && (
            <span className="text-xs text-fg-dim">Speak — the bars should move.</span>
          )}
        </div>
      </div>
    </div>
  );
}

/** A segmented level meter that fills with the current audio level. */
function Meter({ level, active, tint }: { level: number; active: boolean; tint: 'accent' | 'green' }) {
  const lit = Math.round(level * BAR_COUNT);
  return (
    <div className="flex items-center gap-[3px] h-6" aria-hidden>
      {Array.from({ length: BAR_COUNT }).map((_, i) => {
        const on = active && i < lit;
        const hot = i > BAR_COUNT * 0.8;
        const color = !on ? 'bg-fg-dim/15'
          : hot ? 'bg-red-400'
          : tint === 'green' ? 'bg-green-400' : 'bg-accent';
        return (
          <div
            key={i}
            className={`flex-1 rounded-sm transition-all duration-75 ${color}`}
            style={{ height: on ? '100%' : '35%' }}
          />
        );
      })}
    </div>
  );
}
