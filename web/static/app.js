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
// Mirrors MAX_PASTE_BYTES in the server: refuse an oversized image here rather
// than push megabytes at a request that is going to be rejected anyway.
const MAX_PASTE_BYTES = 10 * 1024 * 1024;

const $ = (id) => document.getElementById(id);
const MIN_ZOOM = 0.5;
const MAX_ZOOM = 2.5;
// fontScale is the reader's own zoom, applied to the font rather than to the
// painted image: bigger type means fewer columns fit, exactly as in a terminal
// emulator, and the session is asked to match. A CSS transform is only the
// fallback for when it refuses.
const state = { term: null, attachId: null, source: null, session: null, pending: [],
                fontScale: 1, opening: false };

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
  const extra = (s.mounts || '').split(';').filter(Boolean).length - 1;
  const bits = [s.agent, s.hostdir || s.workdir,
                extra > 0 ? `+${extra} more` : '',
                `${s.cols}x${s.rows}`, `${s.cpus} cpu`, s.memory, `net: ${s.network}`];
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

const lines = (id) => $(id).value.split('\n').map((v) => v.trim()).filter(Boolean);

// Directory completion, one level per request: the server lists the immediate
// children of the directory being typed in and nothing below them, so the cost
// never depends on the size of the tree. The browser's own datalist dropdown
// does the presenting -- matching ignores case, but what lands in the field is
// the exact name on disk, because that is what gets mounted.
let dirTimer = null;
let dirCache = null;                  // null, not '': an empty field is a real
                                      // directory to ask about (the first root)
async function completeDirs() {
  const typed = $('dir').value;
  const upto = typed.slice(0, typed.lastIndexOf('/') + 1);
  if (upto === dirCache) return;      // same directory, the list still applies
  dirCache = upto;
  let result;
  try {
    result = await apiJson(`/api/dirs?path=${encodeURIComponent(typed)}`);
  } catch (err) {
    return;                           // outside the roots, or gone: no suggestions
  }
  const list = $('dir-options');
  list.replaceChildren(...result.dirs.map((d) => {
    const option = document.createElement('option');
    option.value = d;
    return option;
  }));
}

$('dir').addEventListener('input', () => {
  window.clearTimeout(dirTimer);
  dirTimer = window.setTimeout(completeDirs, 150);
});
$('dir').addEventListener('focus', () => { dirCache = null; completeDirs(); });

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
        dirs: [$('dir').value.trim(), ...lines('dirs-extra')],
        name: $('name').value.trim(),
        cpus: $('cpus').value.trim(),
        memory: $('memory').value.trim(),
        blocked: lines('blocked'),
        network_off: $('network_off').checked,
        // The grid this window would give it. A session's geometry is fixed
        // when it is created, and a hardcoded default made every session
        // started here 120x32 whatever the window -- then, being the smallest
        // client, it pinned any terminal attached later to that size too.
        ...windowGrid(null),
      }),
    });
    $('dir').value = '';
    $('dirs-extra').value = '';
    $('name').value = '';
    $('blocked').value = '';
    refresh();
  } catch (ex) {
    err.textContent = ex.message;
    err.hidden = false;
  } finally {
    button.disabled = false;
  }
});

// --- Terminal --------------------------------------------------------------

function fontPx() {
  return Math.max(6, Math.round(BASE_FONT * state.fontScale));
}

function cellSize() {
  // Measure one cell at the font actually in use, so an ideal column/row count
  // for the window can be computed without reaching into xterm internals.
  const px = fontPx();
  const probe = document.createElement('span');
  probe.style.cssText =
    `position:absolute;visibility:hidden;font:${px}px ui-monospace,` +
    'SFMono-Regular,Menlo,Consolas,monospace;white-space:pre';
  probe.textContent = 'M'.repeat(100);
  document.body.append(probe);
  const w = probe.getBoundingClientRect().width / 100;
  const h = Math.ceil(px * 1.2);
  probe.remove();
  return { w, h };
}

// The cell grid this window would give a terminal. `box` is the element the
// terminal will live in, or null before there is one (the start form needs the
// same answer to size a session it is about to create).
function windowGrid(box) {
  const cell = cellSize();
  const rect = box ? box.getBoundingClientRect() : null;
  const width = (rect && rect.width) || (document.documentElement.clientWidth - 24);
  const height = (rect && rect.height) || (document.documentElement.clientHeight - 96);
  return {
    cols: Math.max(40, Math.min(500, Math.floor(width / cell.w) - 1)),
    rows: Math.max(10, Math.min(200, Math.floor(height / cell.h) - 1)),
  };
}

function rescale() {
  const scaleBox = $('term-scale');
  const stage = $('term-stage');
  scaleBox.style.transform = 'none';
  const natural = scaleBox.getBoundingClientRect();
  if (!natural.width || !natural.height) return;

  // Squeeze the grid into the window only while the reader has not chosen a
  // size of their own. A session another client keeps wider than this window
  // cannot be resized down, and it has to be shown somehow; but once they have
  // zoomed, honouring that beats fitting, and the stage scrolls.
  let scale = 1;
  if (state.fontScale === 1) {
    const avail = stage.getBoundingClientRect();
    scale = Math.max(0.45, Math.min(avail.width / natural.width,
                                    avail.height / natural.height, 1));
  }
  scaleBox.style.transform = `scale(${scale})`;
  // A transform leaves layout size untouched, so the stage would scroll across
  // the unscaled grid; give the sizer the dimensions actually painted.
  const sizer = $('term-sizer');
  sizer.style.width = `${Math.ceil(natural.width * scale)}px`;
  sizer.style.height = `${Math.ceil(natural.height * scale)}px`;
  $('zoom-level').textContent = `${Math.round(state.fontScale * 100)}%`;
}

// Zoom changes the type size and then asks the session for the grid that now
// fits the window -- the terminal-emulator behaviour, where larger type means
// fewer columns. The session may refuse (another client would be dragged down
// with it), and then rescale() falls back to painting the grid we have.
async function setZoom(scale) {
  state.fontScale = Math.min(MAX_ZOOM, Math.max(MIN_ZOOM, Math.round(scale * 20) / 20));
  if (state.term) state.term.options.fontSize = fontPx();
  await tryResize();
}

async function tryResize() {
  if (!state.term || !state.attachId) return;
  const { cols, rows } = windowGrid($('term-stage'));
  if (cols === state.term.cols && rows === state.term.rows) { rescale(); return; }
  try {
    await apiJson(`/api/attach/${state.attachId}/resize`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ cols, rows }),
    });
    state.term.resize(cols, rows);
    $('term-status').textContent = `Session sized to ${cols}x${rows}.`;
  } catch (err) {
    // 409: another client is attached, so adopt the session's size and scale.
    // Say what the numbers are: a session started from a very wide terminal is
    // unreadable here at fit scale, and the way out is the zoom control, a
    // smaller terminal, or detaching the other client.
    // Only a *shrink* is refused now: growing cannot drag another client down,
    // since zellij sizes the session to its smallest client.
    $('term-status').textContent =
      `Another client is attached — the session stays ${state.term.cols}x${state.term.rows}` +
      ` and will not shrink to this window's ${cols}x${rows} while that client is there.` +
      ' Use the zoom control, or detach it.';
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

// The image a paste carries, or null for an ordinary text paste.
//
// Browsers disagree about where it lives: Chromium exposes a pasted *bitmap*
// only through items[] (kind 'file', getAsFile()) and leaves files empty unless
// an actual file was copied from a file manager, while Firefox fills both (and
// lists the image twice). Read items first, fall back to files.
//
// Synchronous by necessity: a DataTransferItemList is emptied the moment the
// paste handler returns, so the File has to be taken out before any await.
function clipboardImage(data) {
  if (!data) return null;
  for (const item of Array.from(data.items || [])) {
    if (item.kind === 'file' && (item.type || '').startsWith('image/')) {
      const file = item.getAsFile();
      if (file) return file;
    }
  }
  return Array.from(data.files || [])
    .find((f) => (f.type || '').startsWith('image/')) || null;
}

// One paste gesture in flight at a time. Both routes have to consult it before
// acting, and whichever gets there first consumes it: the paste event usually
// wins, but a clipboard read that was already waiting on Chromium's permission
// prompt can land afterwards, and then the loser must do nothing rather than
// deliver the same image twice.
//
// The gesture also remembers the attachment it was armed for. A clipboard read
// can be pending for as long as the prompt is up, which is long enough to go
// Back and attach a different session -- and an image that arrives then belongs
// to nobody, least of all to the other sandbox's agent.
let pasteGesture = null;

// Neither the DOM nor the clipboard API gives a paste an identity, and the
// gesture record alone cannot tell "a new paste" from "the paste I just served,
// arriving again": the listener would see no gesture in flight either way and
// deliver a second copy. Measured with a single Ctrl+V and a screenshot on the
// clipboard, that produced two uploads and two paths at the prompt in both
// engines -- Gecko dispatches a second paste event for the same keystroke, and
// in Chromium the clipboard read resolves before the event arrives.
//
// So a delivery closes the door behind it for a moment. Pasting twice inside
// this window is not something a person does by hand; a duplicate landing
// milliseconds after its twin is the whole failure mode.
const PASTE_SETTLE_MS = 750;
let pasteServedAt = 0;

// The last upload, so the identical bytes are never sent twice in a row. The
// duplicate this caught came from a real defect, now fixed, but the backstop
// stays: every route ends here, a paste that reaches it twice hands the agent
// two paths for one image, and the cost of being wrong is only that an
// intentional re-paste of the same screenshot inside PASTE_DUPLICATE_MS is
// refused -- which the status line says out loud rather than swallowing.
const PASTE_DUPLICATE_MS = 1500;
let lastUpload = { size: -1, at: 0 };

function pasteSettled() {
  return Date.now() - pasteServedAt >= PASTE_SETTLE_MS;
}

function servePaste() {
  pasteServedAt = Date.now();
}

function armPaste(label, fallback) {
  pasteTrace = [label];
  pasteGesture = { label, attachId: state.attachId, fallback: fallback === true };
  return pasteGesture;
}

function claimPaste(gesture) {
  if (!gesture || gesture !== pasteGesture) return false;   // already consumed
  pasteGesture = null;
  return Boolean(state.attachId) && gesture.attachId === state.attachId;
}

// A paste that produces nothing is otherwise silent, and the two halves of the
// mechanism (the DOM event, the direct clipboard read) fail for different
// reasons in different browsers -- so each step records what it saw and the
// status line says it out loud when nothing came of it.
let pasteTrace = [];

function traceStatus() {
  const line = pasteTrace.join(' · ') || 'nothing happened';
  $('term-status').textContent = `Paste: ${line}`;
  // Also in the console: the status line sits under a terminal that can be
  // taller than the window, so it is easy to miss.
  if (window.console) window.console.log(`paste: ${line}`);
}

function describe(data) {
  if (!data) return 'event: no clipboardData';
  const types = Array.from(data.types || []).join(',') || '-';
  const items = Array.from(data.items || [])
    .map((i) => `${i.kind}:${i.type || '?'}`).join(',') || '-';
  return `event: types=[${types}] files=${(data.files || []).length} items=[${items}]`;
}

function sendImage(blob) {
  if (blob.size > MAX_PASTE_BYTES) {
    $('term-status').textContent = 'That image is larger than the 10 MB limit.';
    return;
  }
  const now = Date.now();
  if (blob.size === lastUpload.size && now - lastUpload.at < PASTE_DUPLICATE_MS) {
    $('term-status').textContent = 'Same image again — ignored the duplicate.';
    return;
  }
  lastUpload = { size: blob.size, at: now };
  uploadImage(blob);
}

// Route two for Ctrl+V: ask the clipboard itself, rather than waiting for a
// DataTransfer to be handed to the page. Chromium reaches this because its
// paste event arrives without the image (or does not arrive); Firefox never
// does, because there the event carries it -- which also means no Firefox
// permission prompt.
//
// Text is handled here too, not only images: with Ctrl+V given back to the
// browser, a browser that fires no paste event would otherwise paste nothing at
// all. term.paste() is xterm's own entry point, so it stays bracketed.
async function pasteFromClipboard(gesture) {
  if (gesture !== pasteGesture || !state.term || !state.attachId) return;
  if (!pasteSettled()) return;          // something already served this burst
  if (!navigator.clipboard || !navigator.clipboard.read) {
    claimPaste(gesture);
    pasteTrace.push('read: unavailable (insecure context?)');
    traceStatus();
    return;
  }

  let items;
  try {
    items = await navigator.clipboard.read();
  } catch (err) {
    // Chromium asks permission the first time and refuses outright in some
    // windows; say so, because nothing else in the UI would.
    claimPaste(gesture);
    pasteTrace.push(`read: ${err.name}: ${err.message}`);
    traceStatus();
    return;
  }

  for (const item of items) {
    const image = item.types.find((t) => t.startsWith('image/'));
    if (image) {
      // Claimed only now, after the await: the event may have delivered this
      // same paste while the read was waiting on the permission prompt.
      if (!claimPaste(gesture)) return;
      servePaste();
      try {
        sendImage(await item.getType(image));
      } catch (err) {
        pasteTrace.push(`read: ${image} failed: ${err.message}`);
        traceStatus();
      }
      return;
    }
  }
  for (const item of items) {
    if (!item.types.includes('text/plain')) continue;
    if (!claimPaste(gesture)) return;
    servePaste();
    try {
      state.term.paste(await (await item.getType('text/plain')).text());
    } catch (err) {
      pasteTrace.push(`read: text failed: ${err.message}`);
      traceStatus();
    }
    return;
  }
  if (!claimPaste(gesture)) return;
  pasteTrace.push(`read: no image, types=[${items.map((i) => i.types.join(',')).join(' ')}]`);
  traceStatus();
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
  // A second click before the first POST resolves would overwrite
  // state.attachId and state.source, leaving the first EventSource open --
  // and because the stream refreshes last_seen on every loop, the reaper
  // would never collect it either. That is a phantom zellij client for the
  // life of the session, which is the leak closeTerminal exists to prevent.
  if (state.opening || state.attachId) return;
  state.opening = true;
  try {
    await attachTerminal(session);
  } finally {
    state.opening = false;
  }
}

async function attachTerminal(session) {
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
  $('zoom').hidden = false;
  $('crumb').textContent = `${session.session} · ${session.agent}`;

  state.fontScale = 1;
  const term = new Terminal({
    cols: info.cols,
    rows: info.rows,
    fontSize: fontPx(),
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

  // Hand Ctrl+V back to the browser, which is what makes an image paste
  // possible at all: xterm.js encodes it as ^V and cancels the DOM event, so no
  // `paste` event is ever produced, and the gestures that do produce one are not
  // equivalent -- Chromium's Ctrl+Shift+V is *paste as plain text*, and the
  // DataTransfer it builds has the image stripped out of it. Returning false
  // makes xterm skip the key WITHOUT cancelling it, so the browser performs a
  // real paste: xterm's own paste listener still handles text (bracketed, as
  // before) and the capture-phase listener below takes the image.
  //
  // ^V therefore cannot be typed in the browser terminal, which is the accepted
  // trade for the paste every user expects. Cmd+V on macOS was never encoded by
  // xterm, so it needed no such handover.
  //
  // Every event type, not keydown alone: xterm consults this handler from its
  // keypress path too and cancels the event there before it ever looks at
  // ctrlKey, and Gecko still dispatches a keypress for Ctrl+letter -- cancel
  // that one and Firefox stops pasting as well. keyup is inert either way.
  //
  // keyCode, deprecated as it is, and not `key`: this has to match exactly the
  // event xterm would have encoded as ^V, and xterm switches on keyCode. On a
  // Cyrillic or Dvorak layout `key` is some other letter while keyCode is still
  // 86, so the two decisions would otherwise drift apart and Ctrl+V would send
  // ^V to the agent with no paste to show for it.
  //
  // Handing the key over is necessary but not sufficient: measured in Chromium
  // 141 on a real session, a Ctrl+V with a screenshot on the clipboard produces
  // no usable image for the page at all, while the identical build of this page
  // works in Firefox. So the keystroke also arms a second route that does not
  // depend on the paste event -- see pasteFromClipboard below -- and whichever
  // arrives first wins.
  term.attachCustomKeyEventHandler((e) => {
    const isPaste = e.keyCode === 86 && !e.altKey
      && ((e.ctrlKey && !e.metaKey) || (e.metaKey && !e.ctrlKey));
    if (!isPaste) return true;

    // keydown only: keypress and keyup would arm the same gesture twice. And
    // only once the last delivery has settled: key autorepeat, or a second
    // keydown for one press, would otherwise arm a second gesture -- and a
    // second gesture is a second delivery, which is how one Ctrl+V uploaded
    // the same screenshot twice.
    if (e.type === 'keydown') {
      let label = 'Ctrl+V';
      if (e.metaKey) label = 'Cmd+V';
      else if (e.shiftKey) label = 'Ctrl+Shift+V';
      if (pasteSettled()) {
        // Armed here, synchronously, and NOT inside the callback: the paste
        // event lands within a couple of milliseconds, and a gesture that only
        // comes into being when the timer fires leaves that event to arm one of
        // its own -- two gestures for one keystroke, each delivering once.
        const gesture = armPaste(label, true);
        window.setTimeout(() => pasteFromClipboard(gesture), 200);
      }
    }

    // Only plain Ctrl+V has to be taken away from xterm, which would send ^V
    // instead. Ctrl+Shift+V and Cmd+V are not encoded by xterm at all, so the
    // browser already pastes on them and they need nothing beyond the gesture
    // armed above -- which they do need, because Ctrl+Shift+V is precisely the
    // gesture Chromium answers with the image stripped out (it means "paste as
    // plain text" there), and Cmd+V is the macOS one.
    //
    // Never on keyup: a false return there also skips the focus() and cursor
    // update xterm performs on every key release (verified in the pinned 5.5.0
    // bundle: `_keyUp` short-circuits on a false custom handler), which is how
    // the hidden textarea gets focus back after a paste moved it.
    return e.shiftKey || e.metaKey || e.type === 'keyup';
  });

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
  $('zoom').hidden = true;
  $('crumb').textContent = '';
  refresh();
}

// Image paste, in the capture phase and on the container rather than on the
// terminal itself, for two reasons:
//
//   - xterm registers its own paste listener on both its textarea and its root
//     element during term.open(), i.e. before any listener added afterwards,
//     and it forwards the clipboard's text/plain sibling -- for an image copied
//     from a web page, a URL or the alt text -- to the agent as a bracketed
//     paste. An ancestor capture listener runs first in every browser, so
//     stopPropagation() here keeps xterm out of the image case entirely.
//   - #term outlives every attachment, so this is registered exactly once.
//     Registered per attach it would stack a listener per Back/Attach cycle and
//     upload the same image once per cycle: stopPropagation does not stop
//     sibling listeners on the same node.
//
// An ordinary text paste falls through untouched.
$('term').addEventListener('paste', (e) => {
  if (!state.term || !state.attachId) return;

  // This terminal owns every paste that lands on it. Cancelling unconditionally
  // and routing text through xterm's own paste() below leaves exactly one path
  // per gesture, which is what makes a duplicate recognisable at all -- and it
  // is the only way to stop an image paste from typing its text/plain sibling
  // (a URL, or the alt text) at the agent's prompt, extracted image or not.
  e.preventDefault();
  e.stopPropagation();

  const data = e.clipboardData;
  // No gesture in flight means either a paste route of the browser's own (the
  // context menu, middle click, Shift+Insert) or the twin of one just served.
  let gesture = pasteGesture;
  if (!gesture) {
    if (!pasteSettled()) return;
    gesture = armPaste('paste', false);
  }

  const image = clipboardImage(data);
  if (image) {
    if (claimPaste(gesture)) {
      servePaste();
      sendImage(image);
    }
    return;
  }

  const claimsImage = Boolean(data)
    && Array.from(data.types || []).some((t) => t.startsWith('image/'));
  if (claimsImage) {
    // Chromium: the clipboard has an image, the event did not carry it. Leave
    // the gesture for the clipboard read -- and start one, if this gesture came
    // from a browser route that armed none.
    if (!gesture.fallback) {
      gesture.fallback = true;
      window.setTimeout(() => pasteFromClipboard(gesture), 0);
    }
    return;
  }

  const text = data ? data.getData('text/plain') : '';
  if (text) {
    // paste() is xterm's own entry point, the same one its listener would have
    // used, so this stays bracketed exactly as before.
    if (claimPaste(gesture)) {
      servePaste();
      state.term.paste(text);
    }
    return;
  }

  pasteTrace.push(describe(data));
  if (!gesture.fallback) {
    claimPaste(gesture);
    traceStatus();                      // nothing else is coming for this one
  }
}, true);

$('back').addEventListener('click', closeTerminal);
$('zoom-in').addEventListener('click', () => setZoom(state.fontScale * 1.15));
$('zoom-out').addEventListener('click', () => setZoom(state.fontScale / 1.15));
$('zoom-fit').addEventListener('click', () => setZoom(1));
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
