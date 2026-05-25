# TODO

## Completed

- Sea-level-aware AGL with editable `seaLevel` and `seaLevelAwareAgl`.
- `minimap look [player] [distance]` with configured-player and 5000m defaults.
- Ship computer TERM mirror/control.

## Altitude tape: predicted-altitude ghost cursor (option E)
Project altitude forward by `vy * N` seconds and draw a faint cursor on the
altitude tape at the prediction. Closes the loop visually so you can see "I'm
about to overshoot" before it happens.

- vy is already computed every fastTick (10Hz) via finite-diff of altitude.
- Pick a horizon (~2s feels right; tunable).
- Render at the projected sub-pixel row in a low-contrast color (light gray?)
  so it doesn't compete with the real ship cursor.
- Skip when |vy| is tiny.

## Forward-looking terrain sampling
Today `state.groundY` is the max surface Y in a 3x3-chunk window centered on
the ship (radius=1). When flying fast over rising terrain the controller
reacts late and may trip STOP_AND_RISE more than necessary. Shift the sample
center forward along the heading vector by `velocity * lookahead_seconds`, or
sample two windows (under-ship + ahead) and demand cruise altitude above the
max. Easy follow-up once the basic altitude controller is tuned.

## Horizontal controller tuning
Expose PID-style/tunable values for forward thrust and turning behavior,
similar to the existing burner/altitude controller tuning.

## Waypoint creation from pins
Add an in-game way to turn the current map pin into a saved waypoint by writing
to the local waypoint file through the UI.

## Ship computer TERM mirror/control - Done
Allow the main ship computer to render/control through both the attached
monitor and the native terminal. This needs separate display/button maps if
the two surfaces have different sizes, plus logical input de-duping so one
physical monitor reachable through multiple peripheral paths does not toggle
buttons twice.

Implemented as `minimap-term`: a local TERM client that shares the minimap UI
path, sends commands to the ship controller through local events, and leaves
the main `minimap` process as the only ship controller.
