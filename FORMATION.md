# Formation and escorts

Experimental. Alex, 2026-09-28: drones flying together. An escort beside a
passenger ride, or a formation pass for the ATC tower. Nothing here is built.

## How a wingman flies

- **The leader flies its own job, unchanged.** It does not know it has a
  wingman, and it never waits for one. Its job is the real one.
- **The wingman holds a slot**, an offset in the leader's frame: say 40 blocks
  back, 30 right, 15 up.
- **Where the leader is** comes from the leader's telemetry: position,
  velocity, heading and phase, once a second. It is sealed with the leader's
  key, so the wingman cannot read it. The base can, and it relays it to the
  wingman sealed with the wingman's own key. No drone ever holds another's key.
- **Prediction.** At 171 b/s, a position one second old is 171 blocks behind.
  The wingman moves it forward along the leader's velocity, as the console
  already does between packets. That is good in a straight cruise and poor in
  the brake.
- **Control.** The wingman's commanded velocity is the leader's velocity plus
  a correction toward the slot. HOLD alone chases a point and would trail by
  hundreds of blocks at cruise speed; feeding the leader's velocity forward is
  what keeps it level. The command is clamped at the wingman's own cruise lean
  limit.

## Safety rules

These are fixed, not tuning values.

- **Stepped up, always.** A wingman is never less than 15 blocks above its
  leader. At cruise the horizontal error can be tens of blocks, and height is
  what keeps them apart. Two sub-levels touching at speed means losing both
  drones.
- **Cruise only.** Each drone takes off, lands and docks on its own. The
  wingman joins after the leader reaches cruise, and breaks off when the
  leader's phase says it is braking: it peels away, then goes home, holds or
  orbits.
- **A lost leader means climb and leave.** After 2 s with no relay, the
  wingman climbs 20 blocks, stops following, holds, and then goes home. It
  never keeps chasing an old prediction.

## Proving it with one drone

**The ghost leader.** The base plays a fake leader, a point moving in a
straight line at a set speed, and relays it exactly as it would a real one.
The wingman code is proven with no second craft and nothing to hit: 30 b/s,
then 60, 120 and 171, then a turn. A second airframe comes only after that.

## Steps

One flight each. Flight-code changes are never stacked.

1. **Orders in flight from the base:** hold and land. Beacon only, with no
   change to fly. Everything below needs it.
2. **The base relays a leader,** real or ghost, to a named wingman.
3. **fly flies a slot:** the velocity feed-forward and correction, the
   stepped-up rule and the lost-leader rule. This is the flight change.
4. **Ghost leader flights:** straight, then faster, then a turn.
5. **A second airframe,** tuned as drone-2.
6. **A real pair,** straight cruise only, with a wide slot (60 back, 40 right,
   20 up). Tighten it only from what the logs show.
7. **As a service:** an escort beside a passenger ride; a formation pass at the
   ATC tower.

## Open

- **Telemetry rate.** 1 Hz now. 2 Hz halves the prediction gap, but sealing
  costs about 5 ms a packet in the flight computer. That is its own
  one-change flight.
- **What an escort costs the customer.** Alex's call.
