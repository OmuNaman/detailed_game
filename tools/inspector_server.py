#!/usr/bin/env python3
"""DeepTown NPC Inspector — Real-time web dashboard for inspecting NPC cognitive state.

Run alongside the Godot game:
    python tools/inspector_server.py

Then open http://localhost:8080 in your browser.
The game writes inspector_state.json every 5 seconds; this server reads and serves it.
"""
import json
import os
import sys
from http.server import HTTPServer, SimpleHTTPRequestHandler
from pathlib import Path

# Locate the Godot user data directory
if sys.platform == "win32":
    APPDATA = os.environ.get("APPDATA", "")
    STATE_FILE = os.path.join(APPDATA, "Godot", "app_userdata", "DeepTown", "inspector_state.json")
else:
    STATE_FILE = os.path.expanduser("~/.local/share/godot/app_userdata/DeepTown/inspector_state.json")

PORT = 8080

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>DeepTown Inspector</title>
<style>
* { margin: 0; padding: 0; box-sizing: border-box; }
body { font-family: system-ui, -apple-system, sans-serif; background: #fff; color: #1a1a1a; display: flex; height: 100vh; }

/* Sidebar */
.sidebar { width: 260px; border-right: 1px solid #e5e7eb; display: flex; flex-direction: column; background: #fafafa; }
.sidebar-header { padding: 16px; border-bottom: 1px solid #e5e7eb; }
.sidebar-header h1 { font-size: 16px; font-weight: 600; color: #4f46e5; }
.sidebar-header .meta { font-size: 11px; color: #6b7280; margin-top: 4px; }
.search { width: 100%; padding: 8px 12px; border: 1px solid #d1d5db; border-radius: 6px; font-size: 13px; outline: none; margin-top: 8px; }
.search:focus { border-color: #4f46e5; box-shadow: 0 0 0 2px rgba(79,70,229,0.1); }
.npc-list { flex: 1; overflow-y: auto; padding: 4px 0; }
.npc-item { padding: 8px 16px; cursor: pointer; display: flex; align-items: center; gap: 8px; font-size: 13px; border-left: 3px solid transparent; }
.npc-item:hover { background: #f3f4f6; }
.npc-item.active { background: #eef2ff; border-left-color: #4f46e5; font-weight: 500; }
.dot { width: 8px; height: 8px; border-radius: 50%; flex-shrink: 0; }
.dot.active { background: #10b981; }
.dot.moving { background: #3b82f6; }
.dot.sleeping { background: #9ca3af; }
.dot.talking { background: #f59e0b; }
.npc-job { font-size: 11px; color: #6b7280; margin-left: auto; }

/* Main */
.main { flex: 1; display: flex; flex-direction: column; overflow: hidden; }
.header { padding: 16px 24px; border-bottom: 1px solid #e5e7eb; display: flex; align-items: center; gap: 16px; }
.header h2 { font-size: 20px; font-weight: 600; }
.header .badge { font-size: 12px; padding: 2px 8px; border-radius: 12px; background: #eef2ff; color: #4f46e5; }
.header .location { font-size: 13px; color: #6b7280; }
.mood-bar { width: 120px; height: 6px; background: #e5e7eb; border-radius: 3px; overflow: hidden; }
.mood-fill { height: 100%; border-radius: 3px; transition: width 0.5s; }

/* Tabs */
.tabs { display: flex; gap: 0; border-bottom: 1px solid #e5e7eb; padding: 0 24px; }
.tab { padding: 10px 16px; font-size: 13px; cursor: pointer; border-bottom: 2px solid transparent; color: #6b7280; }
.tab:hover { color: #1a1a1a; }
.tab.active { color: #4f46e5; border-bottom-color: #4f46e5; font-weight: 500; }

/* Content */
.content { flex: 1; overflow-y: auto; padding: 20px 24px; }

/* Cards */
.card { background: #fff; border: 1px solid #e5e7eb; border-radius: 8px; padding: 16px; margin-bottom: 12px; box-shadow: 0 1px 3px rgba(0,0,0,0.04); }
.card h3 { font-size: 13px; font-weight: 600; color: #374151; margin-bottom: 8px; text-transform: uppercase; letter-spacing: 0.5px; }

/* Needs */
.need-row { display: flex; align-items: center; gap: 8px; margin-bottom: 6px; }
.need-label { font-size: 12px; width: 50px; color: #6b7280; }
.need-bar { flex: 1; height: 8px; background: #f3f4f6; border-radius: 4px; overflow: hidden; }
.need-fill { height: 100%; border-radius: 4px; transition: width 0.5s; }
.need-val { font-size: 12px; width: 35px; text-align: right; color: #374151; font-weight: 500; }

/* Memories */
.mem-item { padding: 10px 0; border-bottom: 1px solid #f3f4f6; display: flex; gap: 10px; align-items: flex-start; }
.mem-item:last-child { border-bottom: none; }
.mem-badge { font-size: 10px; padding: 2px 6px; border-radius: 10px; white-space: nowrap; font-weight: 500; flex-shrink: 0; }
.mem-badge.observation { background: #dbeafe; color: #1e40af; }
.mem-badge.environment { background: #d1fae5; color: #065f46; }
.mem-badge.dialogue { background: #dcfce7; color: #166534; }
.mem-badge.player_dialogue { background: #fef3c7; color: #92400e; }
.mem-badge.reflection { background: #ede9fe; color: #5b21b6; }
.mem-badge.plan { background: #e0f2fe; color: #0369a1; }
.mem-badge.gossip { background: #fef3c7; color: #b45309; }
.mem-badge.episode_summary { background: #f3e8ff; color: #7c3aed; }
.mem-badge.period_summary { background: #fce7f3; color: #be185d; }
.mem-text { font-size: 13px; line-height: 1.5; flex: 1; }
.mem-meta { font-size: 11px; color: #9ca3af; margin-top: 2px; }
.mem-star { color: #f59e0b; }

/* Relationships */
.rel-item { display: flex; align-items: center; gap: 12px; padding: 8px 0; border-bottom: 1px solid #f3f4f6; }
.rel-name { font-size: 13px; font-weight: 500; width: 100px; }
.rel-bars { flex: 1; display: flex; flex-direction: column; gap: 3px; }
.rel-bar-row { display: flex; align-items: center; gap: 6px; }
.rel-bar-label { font-size: 10px; width: 55px; color: #6b7280; }
.rel-bar { flex: 1; height: 6px; background: #f3f4f6; border-radius: 3px; overflow: hidden; position: relative; }
.rel-fill { height: 100%; border-radius: 3px; position: absolute; top: 0; }
.rel-fill.positive { background: #10b981; left: 50%; }
.rel-fill.negative { background: #ef4444; right: 50%; }
.rel-val { font-size: 10px; width: 28px; text-align: right; color: #6b7280; }

/* Plan timeline */
.plan-block { display: flex; align-items: center; gap: 10px; padding: 8px 0; border-bottom: 1px solid #f3f4f6; }
.plan-time { font-size: 12px; font-weight: 600; color: #4f46e5; width: 75px; flex-shrink: 0; }
.plan-loc { font-size: 11px; padding: 2px 6px; border-radius: 4px; background: #f3f4f6; color: #374151; flex-shrink: 0; }
.plan-act { font-size: 13px; color: #374151; }
.plan-block.current { background: #eef2ff; border-radius: 6px; padding: 8px; }

/* Reflection cards */
.reflection-card { background: #fafafa; border-left: 3px solid #8b5cf6; padding: 12px 16px; margin-bottom: 10px; border-radius: 0 6px 6px 0; }
.reflection-card .text { font-size: 14px; line-height: 1.6; font-style: italic; color: #374151; }
.reflection-card .meta { font-size: 11px; color: #9ca3af; margin-top: 6px; }

/* Gossip */
.gossip-item { padding: 10px 0; border-bottom: 1px solid #f3f4f6; }
.gossip-source { font-size: 11px; color: #b45309; font-weight: 500; }
.gossip-text { font-size: 13px; color: #374151; margin-top: 2px; }
.gossip-hops { font-size: 10px; color: #9ca3af; }

/* Bottom bar */
.bottom-bar { padding: 8px 24px; border-top: 1px solid #e5e7eb; display: flex; gap: 20px; font-size: 11px; color: #6b7280; background: #fafafa; align-items: center; }
.stat { display: flex; align-items: center; gap: 4px; }
.stat .val { font-weight: 600; color: #374151; }
.auto-refresh { margin-left: auto; display: flex; align-items: center; gap: 4px; }
.auto-refresh input { accent-color: #4f46e5; }

/* Empty state */
.empty { text-align: center; padding: 60px 20px; color: #9ca3af; }
.empty h3 { font-size: 16px; margin-bottom: 8px; color: #6b7280; }

/* Core memory */
.core-field { margin-bottom: 10px; }
.core-label { font-size: 11px; font-weight: 600; color: #6b7280; text-transform: uppercase; letter-spacing: 0.5px; }
.core-value { font-size: 13px; color: #374151; margin-top: 2px; line-height: 1.5; }
.core-value.empty { color: #d1d5db; font-style: italic; }
.fact-chip { display: inline-block; padding: 2px 8px; background: #f3f4f6; border-radius: 12px; font-size: 12px; margin: 2px 4px 2px 0; }
.summary-entry { padding: 6px 0; border-bottom: 1px solid #f9fafb; font-size: 13px; }
.summary-name { font-weight: 500; color: #4f46e5; }
</style>
</head>
<body>

<div class="sidebar">
  <div class="sidebar-header">
    <h1>DeepTown Inspector</h1>
    <div class="meta" id="game-time">Waiting for game data...</div>
    <input class="search" id="search" placeholder="Search NPCs..." oninput="filterNPCs()">
  </div>
  <div class="npc-list" id="npc-list"></div>
</div>

<div class="main">
  <div class="header" id="header">
    <div class="empty"><h3>Select an NPC</h3><p>Click any NPC in the sidebar to inspect their cognitive state</p></div>
  </div>
  <div class="tabs" id="tabs" style="display:none">
    <div class="tab active" onclick="switchTab('overview')">Overview</div>
    <div class="tab" onclick="switchTab('memories')">Memories</div>
    <div class="tab" onclick="switchTab('relationships')">Relationships</div>
    <div class="tab" onclick="switchTab('plan')">Plan</div>
    <div class="tab" onclick="switchTab('reflections')">Reflections</div>
    <div class="tab" onclick="switchTab('gossip')">Gossip</div>
    <div class="tab" onclick="switchTab('events')">Events</div>
  </div>
  <div class="content" id="content"></div>
  <div class="bottom-bar" id="bottom-bar">
    <div class="stat">NPCs: <span class="val" id="stat-npcs">0</span></div>
    <div class="stat">API Requests: <span class="val" id="stat-requests">0</span></div>
    <div class="stat">Queue: <span class="val" id="stat-queue">0</span></div>
    <div class="stat">Active: <span class="val" id="stat-active">0</span></div>
    <div class="stat">Tokens In: <span class="val" id="stat-tokens-in">0</span></div>
    <div class="stat">Tokens Out: <span class="val" id="stat-tokens-out">0</span></div>
    <div class="auto-refresh">
      <input type="checkbox" id="auto-refresh" checked> Auto-refresh (5s)
    </div>
  </div>
</div>

<script>
let state = null;
let selectedNpc = null;
let currentTab = 'overview';

async function fetchState() {
  try {
    const resp = await fetch('/api/state');
    if (resp.ok) { state = await resp.json(); updateUI(); }
  } catch(e) { console.log('Fetch error:', e); }
}

function updateUI() {
  if (!state) return;
  const gt = state.game_time;
  document.getElementById('game-time').textContent =
    `Day ${gt.day} | ${String(gt.hour).padStart(2,'0')}:${String(gt.minute).padStart(2,'0')} | ${gt.time_scale}x`;

  const ws = state.world?.api_stats || {};
  document.getElementById('stat-npcs').textContent = Object.keys(state.npcs).length;
  document.getElementById('stat-requests').textContent = ws.total_requests || 0;
  document.getElementById('stat-queue').textContent = ws.queue_size || 0;
  document.getElementById('stat-active').textContent = ws.active_requests || 0;
  document.getElementById('stat-tokens-in').textContent = (ws.input_tokens || 0).toLocaleString();
  document.getElementById('stat-tokens-out').textContent = (ws.output_tokens || 0).toLocaleString();

  renderNpcList();
  if (selectedNpc && state.npcs[selectedNpc]) renderNpcDetail();
}

function filterNPCs() { renderNpcList(); }

function renderNpcList() {
  const list = document.getElementById('npc-list');
  const filter = document.getElementById('search').value.toLowerCase();
  let html = '';
  const names = Object.keys(state.npcs).sort();
  for (const name of names) {
    if (filter && !name.toLowerCase().includes(filter)) continue;
    const npc = state.npcs[name];
    const s = npc.state;
    let dotClass = 'active';
    if (s.in_conversation) dotClass = 'talking';
    else if (s.is_moving) dotClass = 'moving';
    else if (s.activity?.includes('sleeping')) dotClass = 'sleeping';
    const active = name === selectedNpc ? 'active' : '';
    html += `<div class="npc-item ${active}" onclick="selectNpc('${name}')">
      <div class="dot ${dotClass}"></div>
      <span>${name}</span>
      <span class="npc-job">${npc.identity.job}</span>
    </div>`;
  }
  list.innerHTML = html;
}

function selectNpc(name) {
  selectedNpc = name;
  document.getElementById('tabs').style.display = 'flex';
  renderNpcList();
  renderNpcDetail();
}

function switchTab(tab) {
  currentTab = tab;
  document.querySelectorAll('.tab').forEach(t => t.classList.toggle('active', t.textContent.toLowerCase() === tab));
  renderNpcDetail();
}

function moodColor(v) { return v > 70 ? '#10b981' : v > 40 ? '#f59e0b' : '#ef4444'; }
function needColor(v) { return v > 60 ? '#10b981' : v > 30 ? '#f59e0b' : '#ef4444'; }
function formatTime(mins) {
  if (!state) return '';
  const diff = state.game_time.total_minutes - mins;
  if (diff < 30) return 'just now';
  if (diff < 60) return `${diff}m ago`;
  if (diff < 1440) return `${Math.floor(diff/60)}h ago`;
  return `${Math.floor(diff/1440)}d ago`;
}
function stars(importance) { return importance >= 8 ? '&#9733;&#9733;' : importance >= 5 ? '&#9733;' : ''; }

function renderNpcDetail() {
  const npc = state.npcs[selectedNpc];
  if (!npc) return;
  const s = npc.state;
  const id = npc.identity;

  // Header
  document.getElementById('header').innerHTML = `
    <h2>${id.name}</h2>
    <span class="badge">${id.job}, ${id.age}y</span>
    <span class="location">${s.activity || 'idle'} @ ${s.location}</span>
    <div style="margin-left:auto;text-align:right">
      <div style="font-size:11px;color:#6b7280">Mood</div>
      <div class="mood-bar"><div class="mood-fill" style="width:${s.mood}%;background:${moodColor(s.mood)}"></div></div>
    </div>`;

  const content = document.getElementById('content');
  if (currentTab === 'overview') content.innerHTML = renderOverview(npc);
  else if (currentTab === 'memories') content.innerHTML = renderMemories(npc);
  else if (currentTab === 'relationships') content.innerHTML = renderRelationships(npc);
  else if (currentTab === 'plan') content.innerHTML = renderPlan(npc);
  else if (currentTab === 'reflections') content.innerHTML = renderReflections(npc);
  else if (currentTab === 'gossip') content.innerHTML = renderGossip(npc);
  else if (currentTab === 'events') content.innerHTML = renderEvents();
}

function renderOverview(npc) {
  const s = npc.state;
  const cm = npc.core_memory;
  let html = '<div class="card"><h3>Needs</h3>';
  for (const [label, val] of [['Hunger', s.hunger], ['Energy', s.energy], ['Social', s.social]]) {
    html += `<div class="need-row"><span class="need-label">${label}</span>
      <div class="need-bar"><div class="need-fill" style="width:${val}%;background:${needColor(val)}"></div></div>
      <span class="need-val">${Math.round(val)}</span></div>`;
  }
  html += '</div>';

  html += '<div class="card"><h3>Core Memory</h3>';
  html += `<div class="core-field"><div class="core-label">Emotional State</div>
    <div class="core-value ${cm.emotional_state?'':'empty'}">${cm.emotional_state || 'neutral'}</div></div>`;
  html += `<div class="core-field"><div class="core-label">About the Player</div>
    <div class="core-value ${cm.player_summary?'':'empty'}">${cm.player_summary || 'Haven\'t met yet'}</div></div>`;
  if (cm.key_facts?.length) {
    html += '<div class="core-field"><div class="core-label">Key Facts</div><div>';
    cm.key_facts.forEach(f => html += `<span class="fact-chip">${f}</span>`);
    html += '</div></div>';
  }
  if (cm.npc_summaries && Object.keys(cm.npc_summaries).length) {
    html += '<div class="core-field"><div class="core-label">About Others</div>';
    for (const [name, summary] of Object.entries(cm.npc_summaries)) {
      html += `<div class="summary-entry"><span class="summary-name">${name}:</span> ${summary}</div>`;
    }
    html += '</div>';
  }
  html += '</div>';

  html += `<div class="card"><h3>Stats</h3>
    <div style="display:grid;grid-template-columns:1fr 1fr 1fr 1fr;gap:8px;font-size:13px">
    <div><div style="font-size:20px;font-weight:600;color:#4f46e5">${npc.stats.total_memories}</div>Memories</div>
    <div><div style="font-size:20px;font-weight:600;color:#10b981">${npc.stats.total_conversations}</div>Conversations</div>
    <div><div style="font-size:20px;font-weight:600;color:#8b5cf6">${npc.stats.total_reflections}</div>Reflections</div>
    <div><div style="font-size:20px;font-weight:600;color:#f59e0b">${npc.stats.total_gossip}</div>Gossip</div>
    </div></div>`;

  html += `<div class="card"><h3>Personality</h3>
    <div style="font-size:13px;line-height:1.6;color:#374151">${npc.identity.personality}</div>
    <div style="font-size:12px;color:#6b7280;margin-top:6px"><em>Speech: ${npc.identity.speech_style}</em></div></div>`;
  return html;
}

function renderMemories(npc) {
  if (!npc.recent_memories?.length) return '<div class="empty"><h3>No memories yet</h3></div>';
  let html = '<div class="card"><h3>Recent Memories (newest first)</h3>';
  const mems = [...npc.recent_memories].reverse();
  for (const m of mems) {
    html += `<div class="mem-item">
      <span class="mem-badge ${m.type}">${m.type.replace('_',' ')}</span>
      <div><div class="mem-text">${m.text} ${m.protected ? '<span class="mem-star">&#9733;</span>' : ''}</div>
      <div class="mem-meta">importance: ${m.importance} | ${formatTime(m.time)}${m.actor ? ' | by '+m.actor : ''}</div></div></div>`;
  }
  html += '</div>';
  return html;
}

function renderRelationships(npc) {
  const rels = npc.relationships;
  if (!rels || !Object.keys(rels).length) return '<div class="empty"><h3>No relationships yet</h3></div>';
  let html = '<div class="card"><h3>Relationships</h3>';
  const sorted = Object.entries(rels).sort((a,b) => {
    const sa = a[1].trust*0.4 + a[1].affection*0.35 + a[1].respect*0.25;
    const sb = b[1].trust*0.4 + b[1].affection*0.35 + b[1].respect*0.25;
    return sb - sa;
  });
  for (const [name, r] of sorted) {
    html += `<div class="rel-item"><span class="rel-name">${name}</span><div class="rel-bars">`;
    for (const [dim, val] of [['Trust', r.trust], ['Affection', r.affection], ['Respect', r.respect]]) {
      const pct = Math.abs(val) / 2;
      const cls = val >= 0 ? 'positive' : 'negative';
      const style = val >= 0 ? `left:50%;width:${pct}%` : `right:50%;width:${pct}%`;
      html += `<div class="rel-bar-row"><span class="rel-bar-label">${dim}</span>
        <div class="rel-bar"><div class="rel-fill ${cls}" style="${style}"></div></div>
        <span class="rel-val">${val}</span></div>`;
    }
    html += '</div></div>';
  }
  html += '</div>';
  return html;
}

function renderPlan(npc) {
  if (!npc.plan?.length) return '<div class="empty"><h3>No plan for today</h3></div>';
  let html = '<div class="card"><h3>Today\'s Schedule</h3>';
  const hour = state.game_time.hour;
  for (const b of npc.plan) {
    const current = hour >= b.start && hour < b.end ? 'current' : '';
    html += `<div class="plan-block ${current}">
      <span class="plan-time">${String(b.start).padStart(2,'0')}:00-${String(b.end).padStart(2,'0')}:00</span>
      <span class="plan-loc">${b.location}</span>
      <span class="plan-act">${b.activity}</span></div>`;
  }
  html += '</div>';
  return html;
}

function renderReflections(npc) {
  if (!npc.reflections?.length) return '<div class="empty"><h3>No reflections yet</h3><p>Reflections trigger after ~100 accumulated importance</p></div>';
  let html = '';
  for (const r of npc.reflections) {
    html += `<div class="reflection-card"><div class="text">"${r.text}"</div>
      <div class="meta">${formatTime(r.time)} | importance: ${r.importance}</div></div>`;
  }
  return html;
}

function renderGossip(npc) {
  if (!npc.gossip?.length) return '<div class="empty"><h3>No gossip heard yet</h3></div>';
  let html = '<div class="card"><h3>Gossip Heard</h3>';
  for (const g of npc.gossip) {
    html += `<div class="gossip-item"><div class="gossip-source">From: ${g.source} <span class="gossip-hops">(${g.hops} hop${g.hops!==1?'s':''})</span></div>
      <div class="gossip-text">${g.text}</div>
      <div style="font-size:11px;color:#9ca3af;margin-top:2px">${formatTime(g.time)}</div></div>`;
  }
  html += '</div>';
  return html;
}

function renderEvents() {
  // Events tab is global (not per-NPC)
  let html = '';

  // Chronicle entries (Gemini Pro narrative summaries)
  const chronicles = state.chronicle || [];
  if (chronicles.length) {
    html += '<div class="card" style="border-left:3px solid #4f46e5;background:#fafafe">';
    html += '<h3 style="color:#4f46e5">Town Chronicle (Gemini 2.5 Pro)</h3>';
    for (const c of chronicles.slice().reverse()) {
      html += `<div style="padding:10px 0;border-bottom:1px solid #eef2ff">
        <div style="font-size:14px;line-height:1.6;color:#1a1a1a;font-style:italic">"${c.text}"</div>
        <div style="font-size:11px;color:#9ca3af;margin-top:4px">${formatTime(c.time)}</div></div>`;
    }
    html += '</div>';
  }

  // Raw events
  const events = state.events || [];
  if (!events.length && !chronicles.length) return '<div class="empty"><h3>No events yet</h3><p>Events appear as NPCs converse, gossip, plan, and reflect</p></div>';

  if (events.length) {
    html += '<div class="card"><h3>Recent Events</h3>';
    for (const ev of events) {
      const actors = (ev.entities || [ev.actor]).join(', ');
      html += `<div class="mem-item">
        <span class="mem-badge ${ev.type}">${ev.type.replace('_',' ')}</span>
        <div><div class="mem-text"><strong>${ev.actor}</strong>: ${ev.text}</div>
        <div class="mem-meta">${formatTime(ev.time)}${actors !== ev.actor ? ' | with '+actors : ''}</div></div></div>`;
    }
    html += '</div>';
  }
  return html;
}

// Auto-refresh
fetchState();
setInterval(() => { if (document.getElementById('auto-refresh').checked) fetchState(); }, 5000);
</script>
</body>
</html>"""


class InspectorHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/' or self.path == '/index.html':
            self.send_response(200)
            self.send_header('Content-Type', 'text/html; charset=utf-8')
            self.end_headers()
            self.wfile.write(DASHBOARD_HTML.encode('utf-8'))
        elif self.path == '/api/state':
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Access-Control-Allow-Origin', '*')
            self.end_headers()
            try:
                with open(STATE_FILE, 'r', encoding='utf-8') as f:
                    data = f.read()
                self.wfile.write(data.encode('utf-8'))
            except FileNotFoundError:
                self.wfile.write(b'{"error": "inspector_state.json not found. Is the game running?"}')
            except Exception as e:
                self.wfile.write(json.dumps({"error": str(e)}).encode('utf-8'))
        else:
            self.send_response(404)
            self.end_headers()

    def log_message(self, format, *args):
        pass  # Suppress request logging


def main():
    print(f"DeepTown NPC Inspector")
    print(f"  State file: {STATE_FILE}")
    print(f"  Dashboard:  http://localhost:{PORT}")
    print(f"  Press Ctrl+C to stop\n")

    if not os.path.exists(STATE_FILE):
        print(f"  [!] State file not found yet. Start the game first!")

    server = HTTPServer(('', PORT), InspectorHandler)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nShutting down.")
        server.shutdown()


if __name__ == '__main__':
    main()
