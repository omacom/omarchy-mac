# System sleep

Omarchy enables suspend and hibernation by default, but if you're having issues with either on your machine, you can toggle them off.

### Power profiles

On a laptop, Omarchy remembers your power profile separately for plugged in and running on battery, and switches between the two as you plug and unplug. Out of the box that means performance on AC and balanced on battery.

You can see what your machine offers with `omarchy powerprofiles list`, and set the one you want for the state you're currently in with `omarchy powerprofiles set autodetect power-saver`. To set the other state without unplugging anything, name it directly: `omarchy powerprofiles set battery power-saver`. Whatever you pick is what you'll get back the next time you're in that state.

### Toggle suspend

You toggle suspend by running `omarchy toggle suspend` from the terminal. That just reveals/hides the option under _System_ (or `Super + Esc`), and then you can see if it works consistently on your system. If not, you can hide it again with the same command.

### Toggle hibernation

You set up hibernation by running `omarchy hibernation setup` from the terminal. Hibernation creates a /swap subvolume on your boot drive the size of your physical RAM allocation, so make sure you have plenty of room to spare. On a 32GB machine, you'll always need 32GB+ free for this volume. Hibernation also requires the default Limine bootloader.

When set up, you'll see the hibernate option under _System_ (or `Super + Esc`), and then you can see if it works consistently on your system. If not, you can remove it again by running `omarchy hibernation remove`.

### Emergency battery protection

Omarchy watches a discharging laptop from system startup, including before login and after logout. At 10% remaining, or when the battery reports no more than 90 seconds left, it gives you one minute to connect power. Connecting power cancels the countdown immediately. If power is still absent, Omarchy hibernates when configured hibernation support is available and otherwise performs an orderly shutdown before the battery reaches its hardware cutoff.

Hibernation preserves the running session across the protection event. Omarchy Mac currently does not offer hibernation on Apple Silicon, so its safe fallback closes the session during shutdown; applications can restore only the state they saved themselves. Apple Silicon Mac laptops normally start when power is connected unless that firmware behavior has been disabled.
