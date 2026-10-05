o.window("^(Bitwarden)$", { no_screen_share = true, tag = "+floating-window" })

-- Browser extension popup, in any Chromium profile. It floats at the size the
-- extension asks for: forcing the standard floating size leaves the popup
-- unpainted until Chromium redraws.
o.window("chrome-nngceckbapebfimnlniiiahkandclblb-.+", {
  no_screen_share = true,
  float = true,
  center = true,
})
