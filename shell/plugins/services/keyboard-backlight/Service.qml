import QtQuick
import Quickshell.Io
import Quickshell.Wayland

// The idle half of the macOS keyboard backlight: the compositor's idle
// notifier reports IDLE_SECONDS without a key press or trackpad touch, and
// the loop behind omarchy-brightness-keyboard-auto.service turns the keys
// off, then brings them back at the first input. This service only relays the
// idle state. The policy, the config file, and every write to the LED live in
// the command, so they behave the same from a TTY or with the shell stopped.
// Without an ambient light sensor or keyboard backlight LED the availability
// probe fails and the service stays inert.
Item {
  id: root

  // Injected by omarchy-shell (the first-party service loader).
  property var shell: null

  property bool supported: false
  property int idleSeconds: 10

  // What the idle monitor last wanted and what was last handed to the
  // command. A fast idle -> active flip while the command is still running
  // must not be dropped, so the wanted state is sent again when it exits.
  property bool wantedIdle: false
  property bool sentIdle: false

  function report(idle) {
    root.wantedIdle = idle
    if (!root.supported || relayProcess.running) return
    root.sentIdle = idle
    relayProcess.command = ["omarchy-brightness-keyboard-auto", idle ? "--idle" : "--active"]
    relayProcess.running = true
  }

  Process {
    id: availableProcess
    command: ["omarchy-brightness-keyboard-auto", "--available"]
    onExited: function(exitCode) {
      root.supported = (exitCode === 0)
      if (!root.supported) {
        console.log("keyboard-backlight: no ambient light sensor or keyboard backlight LED, staying inert")
        return
      }
      console.log("keyboard-backlight: sensor and LED found, enabling idle-off")
      idleSecondsProcess.running = true
      // A previous shell that died while idle leaves the keys dark until
      // someone says otherwise; this shell starts with the user active.
      root.report(false)
    }
  }

  // IDLE_SECONDS comes from the command's own config parser, so the setting
  // is read in one place rather than once in bash and again here.
  Process {
    id: idleSecondsProcess
    command: ["omarchy-brightness-keyboard-auto", "--idle-seconds"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var seconds = parseInt(text, 10)
        if (!isNaN(seconds) && seconds > 0) root.idleSeconds = seconds
      }
    }
  }

  Process {
    id: relayProcess
    onExited: function() {
      if (root.wantedIdle !== root.sentIdle) root.report(root.wantedIdle)
    }
  }

  IdleMonitor {
    enabled: root.supported
    timeout: root.idleSeconds
    // Playback inhibits the screen lock, not the keyboard: keys go dark during
    // a film on macOS too.
    respectInhibitors: false
    onIsIdleChanged: root.report(isIdle)
  }

  Component.onCompleted: availableProcess.running = true
}
