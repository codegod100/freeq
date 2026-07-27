//! Hidden Erlang dist node: EPMD registration + connection loop.
//!
//! **Outbound UI events reuse the live peer link** that BEAM opened when it
//! connected to us. A reverse client connect to a BEAM node that already has
//! our name in its node table fails with EOF — so we never open a second
//! connection while a server-side channel for that peer is open.

use std::collections::HashMap;
use std::sync::mpsc::{self, Receiver, Sender as StdSender};
use std::sync::{Arc, Mutex};
use std::thread::JoinHandle;
use std::time::Duration;

use erl_dist::epmd::{EpmdClient, NodeEntry, DEFAULT_EPMD_PORT};
use erl_dist::handshake::{ClientSideHandshake, HandshakeStatus, ServerSideHandshake};
use erl_dist::message::{self, Message};
use erl_dist::node::{Creation, LocalNode, NodeName};
use erl_dist::term::{Atom, Pid, Term};
use erl_dist::{DistributionFlags, LOWEST_DISTRIBUTION_PROTOCOL_VERSION};
use futures::future::{self, Either};
use futures::stream::StreamExt;
use smol::channel::{self as async_ch, Sender as AsyncSender};
use smol::net::{TcpListener, TcpStream};
use tracing::{info, warn};

use super::protocol::Inbound;

#[derive(Debug, Clone)]
pub struct DistOptions {
    pub local_node: NodeName,
    pub cookie: String,
    pub process_name: String,
    pub peer_node: Option<NodeName>,
    pub peer_process: String,
    pub published: bool,
}

#[derive(Debug, Clone)]
pub enum DistEvent {
    Ready {
        local_node: String,
        port: u16,
        process_name: String,
    },
    PeerConnected {
        peer: String,
    },
    PeerDisconnected {
        peer: String,
    },
    Inbound {
        peer: String,
        msg: Inbound,
    },
    Error(String),
}

#[derive(Debug, Clone)]
#[allow(dead_code)]
pub enum DistCommand {
    SendTerm {
        peer: Option<NodeName>,
        dest: Option<String>,
        term: Term,
    },
    SendToPid {
        peer: NodeName,
        to: Pid,
        term: Term,
    },
    Shutdown,
}

#[derive(Debug, Clone)]
enum PeerOut {
    RegSend { dest: String, term: Term },
    Send { to: Pid, term: Term },
}

type PeerMap = Arc<Mutex<HashMap<String, AsyncSender<PeerOut>>>>;

pub struct DistHandle {
    pub cmd_tx: StdSender<DistCommand>,
    _thread: JoinHandle<()>,
}

pub fn spawn_dist_node(
    opts: DistOptions,
    event_tx: StdSender<DistEvent>,
) -> Result<DistHandle, String> {
    let (cmd_tx, cmd_rx) = mpsc::channel::<DistCommand>();
    let thread = std::thread::Builder::new()
        .name("freeq-erl-dist".into())
        .spawn(move || {
            if let Err(e) = smol::block_on(run_node(opts, event_tx.clone(), cmd_rx)) {
                let _ = event_tx.send(DistEvent::Error(format!("dist node stopped: {e}")));
            }
        })
        .map_err(|e| format!("spawn dist thread: {e}"))?;

    Ok(DistHandle {
        cmd_tx,
        _thread: thread,
    })
}

async fn run_node(
    opts: DistOptions,
    event_tx: StdSender<DistEvent>,
    cmd_rx: Receiver<DistCommand>,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let listener = TcpListener::bind("0.0.0.0:0").await?;
    let listening_port = listener.local_addr()?.port();
    info!(port = listening_port, "dist listening");

    let entry = if opts.published {
        NodeEntry::new(opts.local_node.name(), listening_port)
    } else {
        NodeEntry::new_hidden(opts.local_node.name(), listening_port)
    };

    let epmd_addr = (opts.local_node.host(), DEFAULT_EPMD_PORT);
    let stream = TcpStream::connect(epmd_addr).await.map_err(|e| {
        format!(
            "connect epmd {}:{}: {e} (is epmd running?)",
            opts.local_node.host(),
            DEFAULT_EPMD_PORT
        )
    })?;
    let epmd_client = EpmdClient::new(stream);
    let (keepalive_connection, creation) = epmd_client.register(entry).await?;
    info!(?creation, node = %opts.local_node, "registered with epmd");

    let _ = event_tx.send(DistEvent::Ready {
        local_node: opts.local_node.to_string(),
        port: listening_port,
        process_name: opts.process_name.clone(),
    });

    let peers: PeerMap = Arc::new(Mutex::new(HashMap::new()));

    let accept_opts = opts.clone();
    let accept_tx = event_tx.clone();
    let accept_peers = peers.clone();
    let accept_task = smol::spawn(async move {
        let mut incoming = listener.incoming();
        while let Ok(Some(stream)) = incoming.next().await.transpose() {
            let mut local = LocalNode::new(accept_opts.local_node.clone(), creation);
            if accept_opts.published {
                local.flags |= DistributionFlags::PUBLISHED;
            }
            let cookie = accept_opts.cookie.clone();
            let event_tx = accept_tx.clone();
            let peers = accept_peers.clone();
            smol::spawn(async move {
                if let Err(e) =
                    handle_inbound_connection(local, cookie, stream, event_tx, peers).await
                {
                    warn!("connection handler: {e}");
                }
            })
            .detach();
        }
    });

    loop {
        match cmd_rx.recv_timeout(Duration::from_millis(50)) {
            Ok(DistCommand::Shutdown) => break,
            Ok(DistCommand::SendTerm { peer, dest, term }) => {
                let peer = peer.or_else(|| opts.peer_node.clone());
                let Some(peer) = peer else {
                    let _ = event_tx.send(DistEvent::Error(
                        "no peer (set --peer web4@localhost)".into(),
                    ));
                    continue;
                };
                let dest = dest.unwrap_or_else(|| opts.peer_process.clone());
                let peer_key = peer.to_string();
                if let Err(e) = send_via_live_or_connect(
                    &peers,
                    &opts.local_node,
                    &opts.cookie,
                    creation,
                    &peer,
                    &peer_key,
                    PeerOut::RegSend { dest, term },
                )
                .await
                {
                    let _ = event_tx.send(DistEvent::Error(format!("send to {peer}: {e}")));
                }
            }
            Ok(DistCommand::SendToPid { peer, to, term }) => {
                let peer_key = peer.to_string();
                if let Err(e) = send_via_live_or_connect(
                    &peers,
                    &opts.local_node,
                    &opts.cookie,
                    creation,
                    &peer,
                    &peer_key,
                    PeerOut::Send { to, term },
                )
                .await
                {
                    let _ = event_tx.send(DistEvent::Error(format!("send_to_pid {peer}: {e}")));
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
    }

    drop(keepalive_connection);
    accept_task.cancel().await;
    Ok(())
}

async fn send_via_live_or_connect(
    peers: &PeerMap,
    local_name: &NodeName,
    cookie: &str,
    creation: Creation,
    peer: &NodeName,
    peer_key: &str,
    out: PeerOut,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    // Prefer live BEAM→us channel.
    if let Some(tx) = find_live_tx(peers, peer_key) {
        tx.send(out)
            .await
            .map_err(|_| "live peer channel closed".to_string())?;
        return Ok(());
    }

    warn!(peer = %peer_key, "no live link; reverse client connect (often fails)");
    reverse_send(local_name, cookie, creation, peer, out).await
}

fn find_live_tx(peers: &PeerMap, peer_key: &str) -> Option<AsyncSender<PeerOut>> {
    let g = peers.lock().ok()?;
    if let Some(tx) = g.get(peer_key) {
        return Some(tx.clone());
    }
    // Match short name / @localhost variants.
    for (k, tx) in g.iter() {
        if peer_keys_match(k, peer_key) {
            return Some(tx.clone());
        }
    }
    None
}

fn peer_keys_match(a: &str, b: &str) -> bool {
    if a == b {
        return true;
    }
    let an = a.split('@').next().unwrap_or(a);
    let bn = b.split('@').next().unwrap_or(b);
    an.eq_ignore_ascii_case(bn)
}

async fn reverse_send(
    local_name: &NodeName,
    cookie: &str,
    creation: Creation,
    peer: &NodeName,
    out: PeerOut,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let peer_info = {
        let addr = (peer.host(), DEFAULT_EPMD_PORT);
        let stream = TcpStream::connect(addr).await?;
        let epmd = EpmdClient::new(stream);
        epmd.get_node(peer.name())
            .await?
            .ok_or_else(|| format!("peer {} not found in epmd", peer.name()))?
    };

    let stream = TcpStream::connect((peer.host(), peer_info.port)).await?;
    let local_node = LocalNode::new(local_name.clone(), creation);
    let mut handshake = ClientSideHandshake::new(stream, local_node.clone(), cookie);
    let _status = handshake
        .execute_send_name(LOWEST_DISTRIBUTION_PROTOCOL_VERSION)
        .await?;
    let (connection, peer_node) = handshake.execute_rest(true).await?;

    let (mut tx, _rx) = message::channel(connection, local_node.flags & peer_node.flags);
    let msg = peer_out_to_message(&local_node, out);
    tx.send(msg).await?;
    smol::Timer::after(Duration::from_millis(50)).await;
    Ok(())
}

fn peer_out_to_message(local_node: &LocalNode, out: PeerOut) -> Message {
    let pid = Pid::new(
        local_node.name.to_string(),
        0,
        0,
        local_node.creation.get(),
    );
    match out {
        PeerOut::RegSend { dest, term } => Message::reg_send(pid, Atom::from(dest), term),
        PeerOut::Send { to, term } => Message::Send(message::Send {
            to_pid: to,
            message: term,
        }),
    }
}

async fn handle_inbound_connection(
    local_node: LocalNode,
    cookie: String,
    stream: TcpStream,
    event_tx: StdSender<DistEvent>,
    peers: PeerMap,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let mut handshake = ServerSideHandshake::new(stream, local_node.clone(), &cookie);
    let status = if handshake.execute_recv_name().await?.is_some() {
        HandshakeStatus::Ok
    } else {
        HandshakeStatus::Named {
            name: "generated_name".to_owned(),
            creation: Creation::random(),
        }
    };
    let (stream, peer_node) = handshake.execute_rest(status).await?;
    let peer_name = peer_node.name.to_string();
    info!(peer = %peer_name, "peer connected (live link for outbound)");
    let _ = event_tx.send(DistEvent::PeerConnected {
        peer: peer_name.clone(),
    });

    let (mut tx, rx) = message::channel(stream, local_node.flags & peer_node.flags);
    let (out_tx, out_rx) = async_ch::unbounded::<PeerOut>();
    if let Ok(mut g) = peers.lock() {
        g.insert(peer_name.clone(), out_tx);
    }

    let mut tick = smol::Timer::after(Duration::from_secs(30));
    let mut msg_fut = Box::pin(rx.recv_owned());
    let mut out_fut = Box::pin(out_rx.recv());

    let result: Result<(), Box<dyn std::error::Error + Send + Sync>> = loop {
        match future::select(msg_fut, out_fut).await {
            Either::Left((in_res, still_out)) => {
                out_fut = still_out;
                match in_res {
                    Ok((msg, rx)) => {
                        match msg {
                            Message::Tick => {}
                            Message::RegSend(m) => {
                                tracing::info!(
                                    peer = %peer_name,
                                    to = %m.to_name.name,
                                    "reg_send"
                                );
                                deliver_inbound(&event_tx, &peer_name, m.message);
                            }
                            Message::RegSendTt(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::Send(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::SendTt(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::SendSender(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::SendSenderTt(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::AliasSend(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            Message::AliasSendTt(m) => {
                                deliver_inbound(&event_tx, &peer_name, m.message)
                            }
                            other => tracing::debug!(?other, "ignored dist control"),
                        }
                        msg_fut = Box::pin(rx.recv_owned());
                    }
                    Err(e) => break Err(e.into()),
                }
            }
            Either::Right((out_res, still_in)) => {
                msg_fut = still_in;
                match out_res {
                    Ok(out) => {
                        let msg = peer_out_to_message(&local_node, out);
                        if let Err(e) = tx.send(msg).await {
                            break Err(e.into());
                        }
                        tracing::info!(peer = %peer_name, "sent on live link");
                        out_fut = Box::pin(out_rx.recv());
                    }
                    Err(_) => break Ok(()),
                }
            }
        }

        // Keepalive tick when due.
        if smol::future::poll_once(&mut tick).await.is_some() {
            if let Err(e) = tx.send(Message::Tick).await {
                break Err(e.into());
            }
            tick.set_after(Duration::from_secs(30));
        }
    };

    if let Ok(mut g) = peers.lock() {
        g.remove(&peer_name);
    }
    let _ = event_tx.send(DistEvent::PeerDisconnected {
        peer: peer_name.clone(),
    });
    info!(peer = %peer_name, "peer disconnected");
    result
}

fn deliver_inbound(event_tx: &StdSender<DistEvent>, peer: &str, term: Term) {
    let msg = Inbound::from_term(&term);
    match &msg {
        Inbound::View(v) => {
            tracing::info!(
                peer,
                title = %v.title,
                subtitle = %v.subtitle,
                "decoded view"
            );
        }
        Inbound::DecodeError(e) => {
            tracing::warn!(peer, error = %e, "view decode failed");
        }
    }
    let _ = event_tx.send(DistEvent::Inbound {
        peer: peer.to_string(),
        msg,
    });
}
