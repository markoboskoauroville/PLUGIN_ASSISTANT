# Plugin Assistant (Mantra): takeover

Marko's PatchWork-like rack for the microphone, in two parts. Public, unpromoted: no README, no description. Compiled only by GitHub Actions (.github/workflows/build.yml, the mac-swift template plus the extension zip); never on the Mac. Release v<N> marked Latest with `app.zip` and `plugin-assistant-extension.zip`. Whole-number versions (`let VERSION` in app/App.swift; extension manifest "version" follows).

## A) Mac host app (app/, SwiftUI + AVAudioEngine)
Input = a chosen microphone (BlackHole excluded), a vertical rack of Audio Unit effects (aufx and aumf, listed from AVAudioUnitComponentManager, searchable), each slot: UI (the plug-in's own view in a window), BYPASS, UP/DOWN, REMOVE. Input/output hairline meters, latency estimate, presets (AU fullState, base64 in ~/Library/Application Support/Plugin Assistant (Mantra)/presets/<name>.json; `_last.json` is the autosave restored at launch). Output = "BlackHole 2ch" by default, so Chrome can take it as a microphone. Devices named ADAM are never offered as output. Device buffer 128 frames. Nothing starts by itself: ON in the window or POST /on.
Graph: inputNode -> head mixer (stereo) -> slots -> tail mixer -> mainMixer -> outputNode (input and output devices set with kAudioOutputUnitProperty_CurrentDevice before start). Order/add/remove restarts the engine for a moment; bypass does not.
Local API on 127.0.0.1:8873 (next free port above if busy; number in ~/.mantra/ports/plugin-assistant). CORS for chrome-extension:// origins (and https://mpa-academy.pages.dev).
GET /status /plugins /devices /presets; POST /on /off /device {input,output uid} /chain {action: add{plugin id or name,at} | remove{slot} | move{slot,to} | bypass{slot,value}} /preset/save {name} /preset/load {name} /ui/open {slot}.

## B) Chrome extension (extension/, Manifest V3, unpacked, developer mode)
Popup: ON/OFF (calls the host, stores `on` in chrome.storage.local), the chain mirrored from the host (add with search, bypass, order, UI, remove, meters), "host not running" when unreachable, "ENABLE ON THIS SITE" (optional host permission + registered content scripts for that origin). background.js checks the host every 30 s and turns `on` off if the host is gone.
bridge.js (isolated world) copies `on` to `<html data-pa-on>`; inject.js (MAIN world, document_start, mpa-academy.pages.dev) wraps navigator.mediaDevices.getUserMedia: with ON and an audio request it resolves the "BlackHole 2ch" input by label (one short probe request if labels are hidden), forces deviceId exact, and echoCancellation / noiseSuppression / autoGainControl OFF; video is untouched. Falls back to the normal request if BlackHole is not found. MediaStreamTrack.applyConstraints is wrapped so the page cannot switch those three back on for that track.

## Not tested on a real machine at v1
Written without compiling on the Mac (rule); the first real run is Marko's: microphone permission prompt, AU instantiate, input and output on different devices in one AVAudioEngine (clock drift between the mic and BlackHole is not corrected), plug-ins that refuse a stereo chain.
