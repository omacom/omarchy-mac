---
track: knowledge
category: shell-dev
component: quickshell-process
symptom: "second launch of a Process that reads stdin hangs forever"
root_cause: "Process.stdinEnabled persists across runs: once set false to close the write channel, the next run starts with stdin already closed, so a child doing read-to-EOF never receives input or EOF."
applies_to: "shell/plugins/** Panel.qml Process components that write to child stdin or schedule work that must outlive the panel"
last_updated: 2026-09-15
---

# Quickshell Process lifecycle gotchas for secret-bearing panels

Two Process lifecycle behaviors in the omarchy shell bit during the secrets panel (`shell/plugins/secrets/Panel.qml`) and will recur in any panel that pipes a value into a child's stdin or schedules work past the panel's lifetime.

## Re-arm `stdinEnabled` before every launch

Writing a value to a child's stdin uses the pattern:

```qml
Process {
  id: setProc
  stdinEnabled: true
  onStarted: { write(field.text); stdinEnabled = false }
}
```

`stdinEnabled = false` in `onStarted` is what delivers EOF to `child.read()`. But the flag **persists on the Process across runs** — a second `setProc.running = true` starts with stdin already closed, so the child blocks on `read()` forever (or gets empty input). The first add works; every later add in the same summon session fails. Re-arm in the launch path:

```qml
setProc.stdinEnabled = true
setProc.running = true
```

## Timed/scheduled work must not live in the panel

An in-panel `Timer` dies with the plugin instance on dismiss (plugins have no `keepLoaded`; the loader deactivates them). A "clears clipboard in 30s" promise therefore silently never happens in the dominant copy-then-Esc flow. Schedule it detached instead — `Util.execArgv` (qs.Commons) spawns argv without shell interpretation:

```qml
Util.execArgv(["systemd-run", "--user", "--quiet", "--on-active=30", "--",
  "omarchy-secrets-clipclear", service, account])
```

The delayed job then survives panel destruction; `omarchy-secrets-clipclear` re-verifies the clipboard still holds the secret before clearing, so it is also safe against the user copying something else meanwhile.

## Related traps verified in the same review

- `get | wl-copy` masks a failed `get` (pipe status is wl-copy's, and empty stdin clobbers the clipboard to empty). Gate on success: `v=$(get "$1" "$2") && printf %s "$v" | wl-copy --sensitive`.
- `Process` has no spawn-failure path that emits `onExited`; a binary missing from PATH wedges `running` with no terminal signal. A watchdog `Timer` bound to `proc.running` is the honest surface.
- Backends that print success diagnostics to stderr (`deleted 1 item(s)`) look like errors if a stderr collector calls `setNotice` unconditionally — buffer to `lastStderr` and surface only on nonzero exit.
