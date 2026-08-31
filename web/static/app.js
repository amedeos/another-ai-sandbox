'use strict';
// ---------------------------------------------------------------------------
// Dashboard + browser terminal.
//
// The terminal deliberately adopts the *session's* geometry rather than
// imposing the browser window's: zellij collapses a shared session to its
// smallest client, so a browser that sized itself would shrink the terminal of
// anyone else attached. The grid is scaled with a CSS transform to fit the
// viewport instead, and a real resize is only requested when the server
// confirms this browser is the session's only client.
// ---------------------------------------------------------------------------

const BASE_FONT = 14;
const INPUT_FLUSH_MS = 12;

const $ = (id) => document.getElementById(id);
const state = { term: null, attachId: null, source: null, session: null, pending: [] };

async function api(path, options = {}) {
  const opts = Object.assign({ headers: {} }, options);
  opts.headers = Object.assign({ 'X-AI-Sandbox': '1' }, opts.headers);
  const res = await fetch(path, opts);
  if (res.status === 401) { window.location = '/'; throw new Error('unauthorized'); }
  return res;
}

async function apiJson(path, options) {
  const res = await api(path, options);
  let body = null;
  try { body = await res.json(); } catch (e) { /* empty body */ }
  if (!res.ok) throw new Error((body && body.error) || `HTTP ${res.status}`);
  return body;
}

// --- Session list ----------------------------------------------------------

function sessionRow(s) {
  const row = document.createElement('div');
  row.className = 'session';

  const label = document.createElement('div');
  const name = document.createElement('div');
  name.className = 'name';
  name.textContent = s.session;
  const meta = document.createElement('div');
  meta.className = 'meta';
  const bits = [s.agent, s.workdir, `${s.cols}x${s.rows}`,
                `${s.cpus} cpu`, s.memory, `net: ${s.network}`];
  if (s.blocked) bits.push(`blocked: ${s.blocked}`);
  meta.textContent = bits.filter(Boolean).join(' · ');
  label.append(name, meta);

  const spacer = document.createElement('span');
  spacer.style.flex = '1';

  const open = document.createElement('button');
  open.textContent = 'Attach';
  open.addEventListener('click', () => openTerminal(s));

  const stop = document.createElement('button');
  stop.className = 'danger';
  stop.textContent = 'Stop';
  stop.addEventListener('click', async () => {
    if (!window.confirm(`Stop ${s.session}? The agent will be terminated.`)) return;
    stop.disabled = true;
    try { await apiJson(`/api/sessions/${s.session}/stop`, { method: 'POST' }); }
    catch (err) { window.alert(err.message); }
    refresh();
  });

  row.append(label, spacer, open, stop);
  return row;
}

async function refresh() {
  const host = $('sessions');
  try {
    const data = await apiJson('/api/sessions');
    host.textContent = '';
    if (!data.sessions.length) {
      const p = document.createElement('p');
      p.className = 'muted';
      p.textContent = 'No sessions. Only sandboxes started with --web appear here.';
      host.append(p);
      return;
    }
    data.sessions.forEach((s) => host.append(sessionRow(s)));
  } catch (err) {
    host.textContent = '';
    const p = document.createElement('p');
    p.className = 'error';
    p.textContent = err.message;
    host.append(p);
  }
}

$('start').addEventListener('submit', async (e) => {
  e.preventDefault();
  const err = $('start-error');
  err.hidden = true;
  const button = e.target.querySelector('button');
  button.disabled = true;
  try {
    await apiJson('/api/sessions', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        agent: $('agent').value,
        dirs: [$('dir').value.trim()],
        name: $('name').value.trim(),
        cpus: $('cpus').value.trim(),
        memory: $('memory').value.trim(),
        network_off: $('network_off').checked,
        cols: 120, rows: 32,
      }),
    });
    $('dir').value = '';
    $('name').value = '';
    refresh();
  } catch (ex) {
    err.textContent = ex.message;
    err.hidden = false;
  } finally {
    button.disabled = false;
  }
});

// --- Terminal --------------------------------------------------------------

function cellSize() {
  // Measure one cell at the base font size, so an ideal column/row count for
  // the viewport can be computed without reaching into xterm internals.
  const probe = document.createElement('span');
  probe.style.cssText =
    `position:absolute;visibility:hidden;font:${BASE_FONT}px ui-monospace,` +
    'SFMono-Regular,Menlo,Consolas,monospace;white-space:pre';
  probe.textContent = 'M'.repeat(100);
  document.body.append(probe);
  const w = probe.getBoundingClientRect().width / 100;
  const h = Math.ceil(BASE_FONT * 1.2);
  probe.remove();
  return { w, h };
}

function rescale() {
  const scaleBox = $('term-scale');
  const stage = $('term-stage');
  scaleBox.style.transform = 'none';
  const natural = scaleBox.getBoundingClientRect();
  if (!natural.width || !natural.height) return;
  const avail = stage.getBoundingClientRect();
  const scale = Math.min(avail.width / natural.width,
                         avail.height / natural.height, 1.75);
  // Never shrink past legibility; the stage scrolls instead.
  const clamped = Math.max(scale, 0.45);
  scaleBox.style.transform = `scale(${clamped})`;
}

async function tryResize() {
  if (!state.term || !state.attachId) return;
  const cell = cellSize();
  const stage = $('term-stage').getBoundingClientRect();
  const cols = Math.max(40, Math.floor(stage.width / cell.w) - 1);
  const rows = Math.max(10, Math.floor(stage.height / cell.h) - 1);
  if (cols === state.term.cols && rows === state.term.rows) { rescale(); return; }
  try {
    await apiJson(`/api/attach/${state.attachId}/resize`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cols, rows }),
    });
    state.term.resize(cols, rows);
    $('term-status').textContent = 'Sole client — terminal sized to this window.';
  } catch (err) {
    // 409: another client is attached, so adopt the session's size and scale.
    $('term-status').textContent =
      'Another client is attached — showing the session at its own size.';
  }
  rescale();
}

function flushInput() {
  if (!state.pending.length || !state.attachId) return;
  const payload = state.pending.join('');
  state.pending = [];
  const bytes = new TextEncoder().encode(payload);
  let binary = '';
  bytes.forEach((b) => { binary += String.fromCharCode(b); });
  api(`/api/attach/${state.attachId}/input`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ d: btoa(binary) }),
  }).catch(() => {});
}

async function uploadImage(file) {
  $('term-status').textContent = `Uploading ${file.name || 'image'}…`;
  try {
    const body = await file.arrayBuffer();
    const result = await apiJson(`/api/attach/${state.attachId}/paste`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/octet-stream' },
      body,
    });
    $('term-status').textContent = `Pasted as ${result.path}`;
  } catch (err) {
    $('term-status').textContent = `Paste failed: ${err.message}`;
  }
}

async function openTerminal(session) {
  let info;
  try {
    info = await apiJson(`/api/sessions/${session.session}/attach`, { method: 'POST' });
  } catch (err) {
    window.alert(err.message);
    return;
  }

  state.session = session.session;
  state.attachId = info.attach_id;
  $('list-view').hidden = true;
  $('term-view').hidden = false;
  $('back').hidden = false;
  $('crumb').textContent = `${session.session} · ${session.agent}`;

  const term = new Terminal({
    cols: info.cols,
    rows: info.rows,
    fontSize: BASE_FONT,
    fontFamily: 'ui-monospace, SFMono-Regular, Menlo, Consolas, monospace',
    cursorBlink: true,
    allowProposedApi: true,
    theme: { background: '#12141a', foreground: '#d7dce5' },
  });
  term.open($('term'));
  state.term = term;
  term.focus();
  rescale();

  term.onData((data) => { state.pending.push(data); });
  state.flusher = window.setInterval(flushInput, INPUT_FLUSH_MS);

  // Image paste: intercept only when the clipboard actually carries files, so
  // ordinary text paste still goes through xterm.js (and stays bracketed).
  if (term.textarea) {
    term.textarea.addEventListener('paste', (e) => {
      const files = Array.from((e.clipboardData && e.clipboardData.files) || []);
      const images = files.filter((f) => f.type.startsWith('image/'));
      if (!images.length) return;
      e.preventDefault();
      uploadImage(images[0]);
    });
  }

  const source = new EventSource(`/api/attach/${info.attach_id}/stream`);
  state.source = source;
  source.onmessage = (event) => {
    const binary = atob(event.data);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
    term.write(bytes);
  };
  source.onerror = () => {
    $('term-status').textContent = 'Disconnected. Go back and attach again.';
  };

  $('term-status').textContent = `Attached at ${info.cols}x${info.rows}.`;
  window.setTimeout(tryResize, 250);
}

function closeTerminal() {
  if (state.source) { state.source.close(); state.source = null; }
  if (state.flusher) { window.clearInterval(state.flusher); state.flusher = null; }
  if (state.attachId) {
    // Release the attachment promptly so no phantom zellij client is left
    // holding the session's geometry. The server's sweeper is the backstop.
    api(`/api/attach/${state.attachId}`, { method: 'DELETE' }).catch(() => {});
    state.attachId = null;
  }
  if (state.term) { state.term.dispose(); state.term = null; }
  $('term').textContent = '';
  $('term-view').hidden = true;
  $('list-view').hidden = false;
  $('back').hidden = true;
  $('crumb').textContent = '';
  refresh();
}

$('back').addEventListener('click', closeTerminal);
window.addEventListener('beforeunload', () => {
  if (state.attachId) {
    api(`/api/attach/${state.attachId}`, { method: 'DELETE', keepalive: true }).catch(() => {});
  }
});

let resizeTimer = null;
window.addEventListener('resize', () => {
  window.clearTimeout(resizeTimer);
  resizeTimer = window.setTimeout(tryResize, 200);
});

refresh();
window.setInterval(() => { if (!$('list-view').hidden) refresh(); }, 5000);
