/**
 * WebRTC audio for AV sessions.
 *
 * Uses peer-to-peer WebRTC with the freeq server as signaling relay.
 * Signaling messages (SDP offer/answer, ICE candidates) flow through
 * IRC TAGMSG with +freeq.at/av-signal tags.
 */

// WebRTC audio module — no store dependency (signals go through client.ts)

const ICE_SERVERS = [
  { urls: 'stun:stun.l.google.com:19302' },
  { urls: 'stun:stun1.l.google.com:19302' },
];

interface PeerState {
  pc: RTCPeerConnection;
  remoteNick: string;
  audioEl: HTMLAudioElement;
  pendingIce: RTCIceCandidateInit[]; // buffered until remote description is set
}

let localStream: MediaStream | null = null;
let peers: Map<string, PeerState> = new Map();
let onSignalOut: ((target: string, data: string) => void) | null = null;

/** Start capturing local audio. */
export async function startLocalAudio(): Promise<MediaStream> {
  if (localStream) {
    console.log('[webrtc] Local audio already active');
    return localStream;
  }
  console.log('[webrtc] Requesting microphone...');
  localStream = await navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
    },
    video: false,
  });
  console.log('[webrtc] Microphone captured, tracks:', localStream.getAudioTracks().length);
  return localStream;
}

/** Stop capturing local audio. */
export function stopLocalAudio() {
  if (localStream) {
    localStream.getTracks().forEach((t) => t.stop());
    localStream = null;
  }
  for (const [, peer] of peers) {
    peer.pc.close();
    peer.audioEl.remove();
  }
  peers.clear();
}

/** Set the callback for outgoing signaling messages. */
export function setSignalCallback(cb: (target: string, data: string) => void) {
  onSignalOut = cb;
}

/** Create a peer connection to a remote participant and send an offer. */
export async function connectToPeer(remoteNick: string) {
  if (peers.has(remoteNick)) {
    console.log(`[webrtc] Already connected to ${remoteNick}`);
    return;
  }
  if (!localStream) {
    console.log(`[webrtc] No local stream — calling startLocalAudio first`);
    await startLocalAudio();
  }

  console.log(`[webrtc] Connecting to ${remoteNick}...`);
  const peer = getOrCreatePeer(remoteNick);
  for (const track of localStream!.getTracks()) {
    peer.pc.addTrack(track, localStream!);
    console.log(`[webrtc] Added local track to ${remoteNick}: ${track.kind} enabled=${track.enabled}`);
  }

  const offer = await peer.pc.createOffer();
  await peer.pc.setLocalDescription(offer);
  console.log(`[webrtc] Sending offer to ${remoteNick}`);
  sendSignal(remoteNick, { type: 'offer', sdp: offer.sdp });
}

/** Handle an incoming signaling message from a remote peer. */
export async function handleSignal(fromNick: string, data: string) {
  let msg: any;
  try {
    msg = JSON.parse(data);
  } catch (e) {
    console.warn('[webrtc] Failed to parse signal from', fromNick, e);
    return;
  }

  console.log(`[webrtc] Signal from ${fromNick}: ${msg.type}`);

  if (msg.type === 'offer') {
    console.log(`[webrtc] Received offer from ${fromNick}`);
    // Capture mic FIRST, before creating peer (so ICE candidates don't race)
    if (!localStream) await startLocalAudio();

    const peer = getOrCreatePeer(fromNick);
    for (const track of localStream!.getTracks()) {
      peer.pc.addTrack(track, localStream!);
      console.log(`[webrtc] Added local track for answer to ${fromNick}: ${track.kind} enabled=${track.enabled}`);
    }
    await peer.pc.setRemoteDescription(new RTCSessionDescription({ type: 'offer', sdp: msg.sdp }));

    // Flush any buffered ICE candidates now that remote description is set
    if (peer.pendingIce.length > 0) {
      console.log(`[webrtc] Flushing ${peer.pendingIce.length} buffered ICE candidates for ${fromNick}`);
      for (const candidate of peer.pendingIce) {
        try { await peer.pc.addIceCandidate(new RTCIceCandidate(candidate)); } catch {}
      }
      peer.pendingIce = [];
    }

    const answer = await peer.pc.createAnswer();
    await peer.pc.setLocalDescription(answer);
    console.log(`[webrtc] Sending answer to ${fromNick}`);
    sendSignal(fromNick, { type: 'answer', sdp: answer.sdp });

  } else if (msg.type === 'answer') {
    console.log(`[webrtc] Received answer from ${fromNick}`);
    const peer = peers.get(fromNick);
    if (peer) {
      await peer.pc.setRemoteDescription(new RTCSessionDescription({ type: 'answer', sdp: msg.sdp }));
      // Flush buffered ICE
      if (peer.pendingIce.length > 0) {
        console.log(`[webrtc] Flushing ${peer.pendingIce.length} buffered ICE candidates for ${fromNick}`);
        for (const candidate of peer.pendingIce) {
          try { await peer.pc.addIceCandidate(new RTCIceCandidate(candidate)); } catch {}
        }
        peer.pendingIce = [];
      }
    } else {
      console.warn(`[webrtc] No peer for answer from ${fromNick}`);
    }

  } else if (msg.type === 'ice') {
    const peer = peers.get(fromNick);
    if (peer) {
      if (peer.pc.remoteDescription) {
        try {
          await peer.pc.addIceCandidate(new RTCIceCandidate(msg.candidate));
        } catch (e: any) {
          console.warn(`[webrtc] Failed to add ICE candidate from ${fromNick}:`, e.message);
        }
      } else {
        // Buffer ICE until remote description is set
        peer.pendingIce.push(msg.candidate);
        console.log(`[webrtc] Buffered ICE candidate from ${fromNick} (no remote desc yet, ${peer.pendingIce.length} buffered)`);
      }
    } else {
      // Create peer entry to buffer ICE even before offer arrives
      const newPeer = getOrCreatePeer(fromNick);
      newPeer.pendingIce.push(msg.candidate);
      console.log(`[webrtc] Buffered ICE candidate from ${fromNick} (peer created, ${newPeer.pendingIce.length} buffered)`);
    }
  }
}

/** Check if audio is currently active. */
export function isAudioActive(): boolean {
  return localStream !== null;
}

/** Get the number of connected peers. */
export function connectedPeerCount(): number {
  let count = 0;
  for (const peer of peers.values()) {
    if (peer.pc.connectionState === 'connected') count++;
  }
  return count;
}

/** Toggle mute on local audio. */
export function toggleMute(): boolean {
  if (!localStream) return true;
  const track = localStream.getAudioTracks()[0];
  if (track) {
    track.enabled = !track.enabled;
    return !track.enabled;
  }
  return true;
}

// ── Internal ──

function getOrCreatePeer(remoteNick: string): PeerState {
  const existing = peers.get(remoteNick);
  if (existing) return existing;

  const pc = new RTCPeerConnection({ iceServers: ICE_SERVERS });
  const audioEl = document.createElement('audio');
  audioEl.autoplay = true;

  const peer: PeerState = { pc, remoteNick, audioEl, pendingIce: [] };
  peers.set(remoteNick, peer);

  pc.onicecandidate = (e) => {
    if (e.candidate) {
      sendSignal(remoteNick, { type: 'ice', candidate: e.candidate.toJSON() });
    }
  };

  pc.ontrack = (e) => {
    const stream = e.streams[0] || new MediaStream([e.track]);
    audioEl.srcObject = stream;
    console.log(`[webrtc] Audio track from ${remoteNick}, kind=${e.track.kind}, enabled=${e.track.enabled}, muted=${e.track.muted}, readyState=${e.track.readyState}`);
    console.log(`[webrtc] Audio element: paused=${audioEl.paused}, muted=${audioEl.muted}, volume=${audioEl.volume}`);
    audioEl.play().then(() => {
      console.log(`[webrtc] Audio playback started for ${remoteNick}`);
    }).catch((err) => {
      console.warn(`[webrtc] Audio playback blocked for ${remoteNick}:`, err.message);
    });
  };

  pc.onconnectionstatechange = () => {
    console.log(`[webrtc] ${remoteNick}: ${pc.connectionState}`);
    if (pc.connectionState === 'failed' || pc.connectionState === 'disconnected') {
      peers.delete(remoteNick);
      pc.close();
      audioEl.remove();
    }
  };

  return peer;
}

function sendSignal(target: string, data: any) {
  if (onSignalOut) {
    const json = JSON.stringify(data);
    console.log(`[webrtc] sendSignal to ${target}: ${data.type} (${json.length} bytes)`);
    onSignalOut(target, json);
  } else {
    console.warn('[webrtc] sendSignal called but no callback set');
  }
}
