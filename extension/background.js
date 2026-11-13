// Every 30 s: if the host is gone or switched off, the pages get their normal microphone again.
const HOST = 'http://127.0.0.1:8873';
async function check() {
  try {
    const r = await fetch(HOST + '/status', { cache: 'no-store' });
    const s = await r.json();
    const { on } = await chrome.storage.local.get('on');
    if (on && !s.on) await chrome.storage.local.set({ on: false });
  } catch (e) {
    await chrome.storage.local.set({ on: false });
  }
}
chrome.alarms.create('check', { periodInMinutes: 0.5 });
chrome.alarms.onAlarm.addListener(a => { if (a.name === 'check') check(); });
chrome.runtime.onStartup.addListener(() => chrome.storage.local.set({ on: false }));
