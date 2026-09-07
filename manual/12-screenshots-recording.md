# Screenshots & OmaRecord

On keyboards with a Print Screen key, one key and its modifiers handle screenshots, OmaRecord, colour picking, and text extraction. If your keyboard doesn't have one, use `Super + Ctrl + C` to open the same set as a menu. Apple keyboards also have direct F-key alternatives:

| Hotkey | Function |
| ------ | -------- |
| `Print Screen` | Screenshot |
| `Alt + Print Screen` | OmaRecord (or stop the one that's running) |
| `Super + Print Screen` | Colour picker |
| `Super + Ctrl + Print Screen` | Extract text from a region |
| `Super + Ctrl + C` | Capture menu |
| `Super + Ctrl + .` | Transcode a picture or video |
| `Super + F10` | Screenshot a window on an Apple keyboard |
| `Super + F11` | Screenshot a region on an Apple keyboard |
| `Super + F12` | Screenshot the full display on an Apple keyboard |
| `Super + Alt + F12` | Start/stop fullscreen OmaRecord without audio on an Apple keyboard |

Omarchy configures the top row on Apple keyboards as media keys, and binds both
the media keycodes and F10-F12. These shortcuts work with or without `Fn`.

## Screenshots

Hit `Print Screen` and the screen freezes so nothing shifts under you while you aim. Drag a box for a freeform region, or just click once and the shot snaps to whatever rectangle you clicked in — a window if you landed on one, the whole monitor if you landed on the bar or in a gap. Changed your mind? Hit `Print Screen` again to dismiss the picker.

The result goes two places at once: a PNG in your pictures directory, and the clipboard, so you can paste it straight into a chat window with `Super + V`. A notification pops up with a thumbnail. Click it (or hit `Super + Alt + ,` to invoke the last notification) and the shot opens in Tensaku, the annotation editor, where you can draw arrows and boxes on it before you send it.

Files land in `~/Pictures` by default, named `screenshot-2026-08-13_14-22-05.png`. If you'd rather keep them in their own folder, set `OMARCHY_SCREENSHOT_DIR` — see [the FAQ](46-faq.md) for where to put session environment variables. Omarchy creates the directory for you if it isn't there. You can swap the editor too with `OMARCHY_SCREENSHOT_EDITOR`.

From the terminal, `omarchy screenshot` takes the same shot, and you can be explicit about it: `omarchy capture screenshot region` for freeform only, `windows` to snap to window and monitor rectangles, or `fullscreen` to skip the picker entirely and grab the focused monitor. A second argument of `copy` puts the shot only on the clipboard, and `save` only on disk.

### Driving the picker from the keyboard

While the selection is up, you don't have to use the mouse at all:

| Key | Function |
| --- | -------- |
| `Return` | Capture the highlighted window |
| `Ctrl + Return` | Capture the whole screen |
| `Tab` / `Ctrl + Tab` | Highlight the next / previous window |
| Arrow keys | Highlight the window in that direction |

The arrows and Tab move the cursor to the window they pick, so the highlight follows along and you can see what you're about to capture. These bindings only exist while a selection is on screen, so they can't collide with anything in your own config.

## OmaRecord

`Alt + Print Screen` opens _Trigger > Capture > OmaRecord_, which asks what you want on the soundtrack: no audio, desktop audio, desktop plus microphone, or desktop plus microphone plus webcam. That last one only shows up if you actually have a camera plugged in. Pick one and you get the same picker as a screenshot: drag a region, or click a window or monitor.

From a terminal, use `omarecord` with the same options: `omarecord --fullscreen` starts a full-display recording, and `omarecord --stop-recording` stops it. The routed commands `omarchy screenrecord` and `omarchy capture screenrecording` remain supported.

On Apple Silicon, `Super + Alt + F12` starts a fullscreen OmaRecord without audio. The same hotkey stops it, and holding `Fn` works too.

Recording normally runs on gpu-screen-recorder, which encodes on the GPU at
60fps and falls back to the CPU if it has to. On Apple Silicon it uses
wf-recorder with CPU encoding because the Asahi GPU has no supported hardware
video encoder. The result is an MP4 in `~/Videos`, named
`screenrecording-2026-08-13_14-22-05.mp4`. Set `OMARCHY_SCREENRECORD_DIR` to
change that — but note that unlike the screenshot directory, this one has to
exist already, or the recording refuses to start.

While you're recording, a little indicator shows up in the bar. Click it to stop. You can also stop with `Alt + Print Screen` again, or with the _Stop OmaRecord_ entry under _Trigger > Capture > OmaRecord_, which only appears while something is actually recording.

Stopping does a bit of tidying before it hands you the file: the first frame gets trimmed, and if there's audio it's normalized to -14 LUFS with the PipeWire capture pop at the very start muted out. Then a notification appears with a thumbnail from the recording. Click it to play the file in mpv.

### The webcam overlay

When you record with a webcam, the camera appears as a pinned, cropped portrait window in the bottom-right corner of whatever you're recording. If it's sitting on top of something you need, resize it on the fly:

| Hotkey | Function |
| ------ | -------- |
| `Super + Alt + [` | Make the webcam overlay smaller |
| `Super + Alt + ]` | Make the webcam overlay larger |

There are three sizes — small, medium, and large — and the hotkeys step between them. Medium is the default. They're proportional to the recording, so the camera takes up the same share of the frame whether you're recording a 1080p monitor or a 6K one. And if you recorded a region rather than a whole display, the overlay anchors to that region's corner rather than the monitor's, so it stays inside the shot.

You can also call it directly with `omarchy-capture-webcam-resize small`, or `reset` to go back to medium.

### Showing keystrokes

Install the optional overlay with `omarchy pkg add showmethekey`, then start a recording with `omarecord --show-keystrokes`. You can combine the flag with `--fullscreen`, audio, webcam, and resolution options; `omarchy screenrecord --show-keystrokes` and `omarchy capture screenrecording --show-keystrokes` remain supported.

Omarchy starts `showmethekey-gtk -k -A -C`, waits for its floating window to appear, and only then starts the recorder. The recorder captures the visible overlay as pixels in the video; Omarchy does not create a separate key log. The overlay instance started for that recording is stopped when the recording stops, fails to start, or exits unexpectedly, without stopping independently launched Show Me The Key windows. If Show Me The Key is missing or its window cannot open, the recording aborts instead of continuing without keystrokes.

`--show-keystrokes` requires monitor or region capture. It is rejected when `OMARCHY_SCREENRECORD_USE_PORTAL=true` selects portal capture because Omarchy cannot guarantee that the compositor-managed overlay will be included there.

**Privacy warning:** Show Me The Key reads and displays every key you type, including passwords; password fields cannot be detected. Quickly press Alt twice (or press both Alt keys) to pause the overlay before entering anything sensitive, then repeat the gesture to resume.

## Text, QR codes, and colours

`Super + Ctrl + Print Screen` selects a region and OCRs it to the clipboard. That's covered properly in [Text Extraction & Dictation](11-text-extraction-dictation.md).

_Trigger > Capture > QR Code_ does the same trick for QR codes. Select the region with the code in it, and the decoded value goes to the clipboard. It only looks for QR codes — dense screen content has a habit of false-positiving as a barcode otherwise. Worth knowing: the decoded value goes to the clipboard and nowhere else. It isn't printed, it isn't in the notification, and it's marked sensitive so it doesn't stick around in [clipboard history](08-unified-clipboard-history.md). QR codes routinely carry secrets — the `otpauth://` URI behind a 2FA setup code, for one — and you don't want that in a log. Pasting still works fine.

`Super + Print Screen` (or _Trigger > Capture > Color_) turns the cursor into an eyedropper. Click anything on screen and the colour lands on the clipboard. Press the hotkey again to back out without picking.

## Transcoding before you share

A 4K screen recording or a raw HEIC off your phone is often too big to just send. `Super + Ctrl + .` (or _Trigger > Transcode_) fixes that. It offers you a fuzzy file picker over `~/Pictures` and `~/Videos`, then asks for a format and a size.

Pictures go to jpg or png at high, medium, or low, which cap the width at 3160, 2160, and 1080 pixels. Videos go to mp4 or an animated gif at 4k, 1080p, or 720p. The converted file is written next to the original with the resolution in the name — `demo-1080p.mp4` — and the path is copied to the clipboard as a file URI, so you can paste it directly into an app that takes file drops.

It works from the terminal too, if you already know what you want: `omarchy transcode ~/Videos/demo.mov mp4 1080p`. There's also `omarchy transcode ascii`, which turns an image into ASCII art — that one's mostly for [branding](41-branding.md).

## Sending it somewhere

Once you've got the file, `Super + Ctrl + S` opens the Share menu and sends it to another device on your network via LocalSend. See [GUIs](22-guis.md) for that.
