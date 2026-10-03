-- LÖVE configuration for the M0 baseline sweep harness.
-- A real (small) window is kept because LÖVE initializes the video subsystem
-- at boot even for headless runs; nothing is drawn.
function love.conf(t)
  t.identity = "peggle_julia_clone_harness"
  t.version = "11.5"
  t.console = false

  t.window = {
    title = "Peggle M0 baseline harness",
    width = 320,
    height = 240,
    resizable = false,
    fullscreen = false,
    vsync = 0,
    msaa = 0,
    highdpi = false,
    usedpiscale = false,
  }

  t.modules.audio = false
  t.modules.sound = false
  t.modules.joystick = false
  t.modules.physics = false
  t.modules.touch = false
  t.modules.video = false
end
