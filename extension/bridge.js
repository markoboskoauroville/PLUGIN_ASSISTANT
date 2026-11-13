// ISOLATED world: copies the ON state from chrome.storage to <html data-pa-on> for inject.js (MAIN world).
(() => {
  const set = v => document.documentElement.setAttribute('data-pa-on', v ? '1' : '0');
  set(false);
  try {
    chrome.storage.local.get('on', r => set(!!(r && r.on)));
    chrome.storage.onChanged.addListener(ch => { if (ch.on) set(!!ch.on.newValue); });
  } catch (e) {}
})();
