-- Show Me The Key documents both app IDs and this untranslated floating-window title.
o.window({ class = "^(one\\.alynx\\.showmethekey|showmethekey-gtk)$", title = "^Floating Window - Show Me The Key$" }, {
  tag = "-default-opacity",
  float = true,
  pin = true,
  no_initial_focus = true,
  focus_on_activate = false,
  opacity = "1 1",
  move = { "(monitor_w-window_w)/2", "monitor_h-window_h-40" },
})
