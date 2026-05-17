# TODO

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
