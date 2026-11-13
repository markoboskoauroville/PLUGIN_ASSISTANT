const HOST = 'http://127.0.0.1:8873';
const $ = id => document.getElementById(id);
let st = null, plugins = null, busy = false;

async function api(path, body) {
  const r = await fetch(HOST + path, body === undefined ? { cache: 'no-store' }
    : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) });
  return r.json();
}
const pct = db => Math.max(0, Math.min(100, (db + 60) / 60 * 100)) + '%';

function drawChain() {
  const c = $('chain'); c.textContent = '';
  (st.chain || []).forEach((s, i) => {
    const d = document.createElement('div'); d.className = 'slot' + (s.bypass ? ' by' : '');
    const n = document.createElement('div'); n.className = 'n';
    const b = document.createElement('b'); b.textContent = s.name; n.appendChild(b);
    const m = document.createElement('span'); m.className = 'mut'; m.textContent = s.manufacturer; n.appendChild(m);
    d.appendChild(n);
    const mk = (t, f, dis) => { const x = document.createElement('button'); x.textContent = t; x.disabled = !!dis; x.onclick = f; d.appendChild(x); };
    mk('UI', () => api('/ui/open', { slot: s.id }));
    mk(s.bypass ? 'BYPASSED' : 'BYPASS', () => act({ action: 'bypass', slot: s.id }));
    mk('UP', () => act({ action: 'move', slot: s.id, to: i - 1 }), i === 0);
    mk('DOWN', () => act({ action: 'move', slot: s.id, to: i + 1 }), i === st.chain.length - 1);
    mk('X', () => act({ action: 'remove', slot: s.id }));
    c.appendChild(d);
  });
}
async function act(o) { st = await api('/chain', o); drawChain(); }

async function poll() {
  if (busy) return; busy = true;
  try {
    const s = await api('/status');
    const first = !st; const prev = st && JSON.stringify(st.chain);
    st = s;
    $('onoff').disabled = false; $('onoff').textContent = s.on ? 'OFF' : 'ON';
    $('status').className = s.error ? 'bad' : 'mut';
    $('status').textContent = s.error || (s.on ? `ON: ${s.input} to ${s.output}, ${s.latencyMs} ms` : 'host ready, OFF');
    $('mi').style.width = pct(s.levels.inRms); $('mo').style.width = pct(s.levels.outRms);
    $('pi').style.left = pct(s.levels.in); $('po').style.left = pct(s.levels.out);
    if (first || prev !== JSON.stringify(s.chain)) drawChain();
    chrome.storage.local.set({ on: !!s.on });
  } catch (e) {
    st = null; $('onoff').disabled = true; $('onoff').textContent = 'ON';
    $('status').className = 'bad'; $('status').textContent = 'host not running: open Plugin Assistant (Mantra)';
    $('chain').textContent = ''; chrome.storage.local.set({ on: false });
  }
  busy = false;
}

$('onoff').onclick = async () => {
  try { st = await api(st && st.on ? '/off' : '/on', {}); } catch (e) {}
  poll();
};
$('addb').onclick = async () => {
  $('addbox').hidden = false; $('q').focus();
  if (!plugins) plugins = (await api('/plugins')).plugins;
  list();
};
function list() {
  const t = $('q').value.toLowerCase(), r = $('res'); r.textContent = '';
  plugins.filter(p => !t || (p.name + ' ' + p.manufacturer).toLowerCase().includes(t)).slice(0, 60).forEach(p => {
    const d = document.createElement('div'); d.textContent = p.name;
    d.onclick = async () => { $('addbox').hidden = true; $('q').value = ''; st = await api('/chain', { action: 'add', plugin: p.id }); drawChain(); };
    r.appendChild(d);
  });
}
$('q').oninput = list;

// enable the swap on the site of the current tab (asks Chrome for that origin only)
chrome.tabs.query({ active: true, currentWindow: true }, tabs => {
  const t = tabs[0]; if (!t || !t.url || !/^https?:/.test(t.url)) { $('site').disabled = true; return; }
  const origin = new URL(t.url).origin + '/*';
  $('siteinfo').textContent = new URL(t.url).host;
  if (/mpa-academy\.pages\.dev/.test(t.url)) { $('site').disabled = true; $('site').textContent = 'ALWAYS ON HERE'; return; }
  $('site').onclick = async () => {
    const ok = await chrome.permissions.request({ origins: [origin] });
    if (!ok) return;
    const id = 'pa-' + origin.replace(/[^a-z0-9]/gi, '');
    try { await chrome.scripting.unregisterContentScripts({ ids: [id + 'b', id + 'm'] }); } catch (e) {}
    await chrome.scripting.registerContentScripts([
      { id: id + 'b', matches: [origin], js: ['bridge.js'], runAt: 'document_start', allFrames: true, world: 'ISOLATED', persistAcrossSessions: true },
      { id: id + 'm', matches: [origin], js: ['inject.js'], runAt: 'document_start', allFrames: true, world: 'MAIN', persistAcrossSessions: true }
    ]);
    $('site').textContent = 'ENABLED: reload the page'; $('site').disabled = true;
  };
});

poll(); setInterval(poll, 250);
