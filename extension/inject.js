// MAIN world: wraps getUserMedia so audio requests get the "BlackHole 2ch" input (the host's processed voice).
// ON/OFF comes from the isolated bridge as the attribute data-pa-on on <html>. Video is untouched.
(() => {
  if (window.__paWrapped) return;
  window.__paWrapped = true;
  const md = navigator.mediaDevices;
  if (!md || !md.getUserMedia) return;
  const orig = md.getUserMedia.bind(md);
  const isOn = () => document.documentElement.getAttribute('data-pa-on') === '1';
  const tagged = new WeakSet();

  async function blackHoleId() {
    let list = await md.enumerateDevices();
    let d = list.find(x => x.kind === 'audioinput' && /blackhole 2ch/i.test(x.label));
    if (!d && list.some(x => x.kind === 'audioinput' && !x.label)) {
      // labels are hidden until some permission exists: take one short probe, then look again
      try { const p = await orig({ audio: true }); p.getTracks().forEach(t => t.stop()); } catch (e) {}
      list = await md.enumerateDevices();
      d = list.find(x => x.kind === 'audioinput' && /blackhole 2ch/i.test(x.label));
    }
    return d ? d.deviceId : null;
  }

  const OFF = { echoCancellation: false, noiseSuppression: false, autoGainControl: false,
                googEchoCancellation: false, googNoiseSuppression: false, googAutoGainControl: false, googHighpassFilter: false };

  md.getUserMedia = async function (c) {
    if (!isOn() || !c || !c.audio) return orig(c);
    try {
      const id = await blackHoleId();
      if (!id) { console.warn('[Plugin Assistant] BlackHole 2ch input not found, normal microphone used'); return orig(c); }
      const a = Object.assign({}, typeof c.audio === 'object' ? c.audio : {}, OFF, { deviceId: { exact: id } });
      const s = await orig(Object.assign({}, c, { audio: a }));
      s.getAudioTracks().forEach(t => tagged.add(t));
      document.dispatchEvent(new CustomEvent('plugin-assistant-active', { detail: { device: 'BlackHole 2ch' } }));
      return s;
    } catch (e) {
      console.warn('[Plugin Assistant] fell back to the normal microphone:', e && e.name);
      return orig(c);
    }
  };

  // the page must not switch echo cancellation / noise suppression back on for our track
  const ac = MediaStreamTrack.prototype.applyConstraints;
  MediaStreamTrack.prototype.applyConstraints = function (k) {
    if (tagged.has(this) && k) k = Object.assign({}, k, OFF);
    return ac.call(this, k);
  };
})();
