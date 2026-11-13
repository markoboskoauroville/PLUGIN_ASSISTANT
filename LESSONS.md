# Plugin Assistant (Mantra): lessons

- A Chrome extension cannot load AU/VST; the host app does the audio and the extension only swaps the device (BlackHole 2ch) and mirrors the rack.
- Content scripts with "world": "MAIN" need Chrome 111+; the MAIN world cannot read chrome.storage, so an isolated bridge writes the ON state to a DOM attribute.
- Without any granted permission, enumerateDevices gives empty labels: probe once, then look for BlackHole by label.
- Test audio never goes to the ADAM D3V; the output list hides it.
