# Architecture

The layer stack for the autonomous controller. Written before the code so the
boundaries are a decision rather than an accident.

Read [FRAMES.md](FRAMES.md) first. Every value crossing a layer boundary is in
one of those frames.

## The stack

| Layer | Name | Owns | Rate |
|---|---|---|---|
| L4 | **Link** | telemetry out, commands in, over rednet | ~1 Hz |
| L3 | **Mission** | the queue of legs, energy budget, abort and divert | ~1 Hz |
| L2 | **Leg** | the phase machine, one leg at a time | 20 Hz |
| L1 | **Control** | attitude, altitude, translation. Writes the actuators | 20 Hz |
| L0 | **Hardware** | peripherals and the `sublevel` API | on demand |

Each runs as its own coroutine under `parallel.waitForAny`, exactly like
`gpsLoop` and `monLoop` do today. That pattern is already proven in `fly.lua`
and is the reason this layering costs nothing to adopt.

## The rules that matter

**1. Nothing that yields goes in L1.** Every peripheral call and every
`sublevel` call costs a tick. The control loop makes the minimum set and no
more. Slow reads live in their own coroutine and publish into a shared table.
This is why monitoring, GPS and telemetry are separate loops rather than inline.

**2. Layers share tables, never calls.** A layer publishes state into a plain
Lua table and reads what it needs from tables below. No layer calls up. No layer
blocks another. If L3 wants a new altitude, it writes a target and L2 acts on it
next iteration.

**3. Only L1 touches the thruster.** Everything above expresses intent as
targets: a position, an altitude, an attitude, a leg. If a higher layer is
setting a thrust vector, the boundary has leaked.

**4. Nothing above L1 may stall L1.** A mission decision that takes a while, a
telemetry send that blocks, a rednet timeout: none of these may delay a control
iteration. The drone must keep flying while the layers above it think.

## L2: legs

A leg is one unit of flight that the phase machine can execute start to finish.
Today's modes are all single-leg missions, which is why nothing already built
gets thrown away.

| Leg | Meaning | Ends when |
|---|---|---|
| `climb` | reach a cruise altitude | at altitude |
| `cruise` | fly to an x,z | inside arrival radius, braked |
| `hold` | station keep at a point | told to, or a timeout |
| `hover` | station keep at a point and a set altitude | settled inside a tolerance |
| `action` | fire a redstone side, wait, confirm | the action reports done |
| `dock` | align, descend, capture | connector reports docked |
| `undock` | release once thrust is established | released |

An airdrop mission is then just:

```
climb -> cruise(target) -> hover(target, dropAlt) -> action(release)
      -> climb -> cruise(home) -> dock(pad)
```

Return-to-home is not a special mode. It is the same legs with different
arguments, which is the point of the layering.

## L3: mission, and the point of no return

L3 owns the one thing that makes unattended flight safe: a continuous check that
the drone can still get home.

Reserve needed is estimated from the distance home, the observed cruise speed
and the observed drain rate, all of which the monitoring loop already tracks.
When the margin goes thin, L3 rewrites the queue: skip the delivery, go home
now. It does not ask L2 to stop mid-phase, it simply changes what comes next.

The same mechanism handles a failed capture, a lost payload and a recall from
base. All of them are queue edits.

## L1: mass feedforward

Hover throttle must be computed from `sublevel.getMass()`, not held as a
constant. A delivery drone changes mass in flight, and the moment the payload
releases it will climb hard if the throttle is still trimmed for the loaded
weight. Feedforward from measured mass makes the release a non-event, and the
altitude integrator should be rescaled by the mass ratio at the same instant to
kill the remaining transient.

This is the one place a higher-layer concern legitimately reaches into L1, and
it is worth the exception.

## L4: link

A wireless modem and `rednet`, in its own coroutine at about 1 Hz.

**Out**: position, attitude, current leg and phase, energy and drain rate, fuel,
mass, dock state.

**In**: `recall`, `abort`, `hold`, `resume`. Commands are queue edits handed to
L3, never direct actuator commands. A command that could fly the drone from base
is a command that can crash it when the link drops.

Telemetry is advisory. The drone completes its mission with the radio dead.

## Payload

A shulker box or a barrel, released by redstone. Loose items scatter on impact
and despawn in five minutes; a container survives the fall and stays where it
lands. Release is an `action` leg so that the mission layer can confirm it
happened, by mass change, before flying home.

## What not to do

- Do not add mission phases to the L2 phase machine. It handles one leg; the
  queue lives above it.
- Do not put a rednet call anywhere near L1.
- Do not let the drone act on a base command that L3 has not vetted against the
  energy budget.
- Do not convert attitude to Euler angles anywhere in the control path. See
  [FRAMES.md](FRAMES.md).
