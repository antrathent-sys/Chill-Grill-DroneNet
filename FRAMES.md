# Coordinate frames

One agreed set of frames for describing the rocket's motion. Everything in this
repo, and every future controller, uses these. If a value doesn't say which
frame it's in, it's a bug.

The rule that makes this work: **world axes and body axes never share a letter.**
World axes are capital `X Y Z`. Body axes are named after the hardware, never
after an Euler angle.

## World frame: Minecraft native

| Axis | Direction |
|---|---|
| `X` | east |
| `Y` | up |
| `Z` | south |

Right-handed. This is what GPS, `sublevel` pose and the altitude sensor all
report in, so there is nothing to convert.

**Heading** is a compass bearing in degrees: 0 north, 90 east, 180 south, 270
west. From a world-frame horizontal vector:

```lua
local function headingOf(v)          -- v is a world {x=,y=,z=}
  return math.deg(math.atan2(v.x, -v.z)) % 360
end
```

This matches the convention already used in `fly.lua`. It is **not** Minecraft's
own yaw, which is zero at south and increases toward west. Convert only at the
edges, never in the middle of a control loop.

## Body frame: named after the airframe, not the attitude

Euler names are banned in this project because they don't survive a VTOL
transition. The axis that is yaw in hover becomes roll in forward flight, and
somewhere in between the maths degenerates. Body axes are therefore defined by
the hull, and mean exactly the same thing at every attitude.

| Axis | Definition |
|---|---|
| `t` | **thrust axis.** The direction the airframe is pushed when the thrusters fire. Out the top of the pod. |
| `n` | **nose.** A physically marked reference direction, perpendicular to `t`. Pick a face and mark it. |
| `s` | **starboard.** Completes a right-handed set, `s = t x n`. |

In hover `t` points along world `Y`. In forward flight it tilts. Nothing about
the names changes. Note that `n` is arbitrary but must be *chosen and marked on
the build*, because the mixer signs depend on it.

### What this frame buys you

Stated once, in terms that survive any attitude:

- **Rotation about `n` and `s`** comes from differential thrust across spread
  thrusters. Strong, direct, no vectoring needed.
- **Rotation about `t`** is zero from differential thrust, at any mounting
  geometry, because a force along an axis makes no torque about that same axis.
  It requires the thrusters to be vectored tangentially or canted.

That second line is the whole reason to decide the airframe layout before
building it.

## Attitude: quaternion only

`sublevel.getLogicalPose().orientation` gives `{x, y, z, w}`. Treat it as the
rotation taking a **body** vector to a **world** vector, and never convert it to
angles inside a control loop.

```lua
-- rotate a body-frame vector into the world frame
local function toWorld(q, v)
  local qx, qy, qz, qw = q.x, q.y, q.z, q.w
  local tx = 2 * (qy * v.z - qz * v.y)
  local ty = 2 * (qz * v.x - qx * v.z)
  local tz = 2 * (qx * v.y - qy * v.x)
  return { x = v.x + qw * tx + (qy * tz - qz * ty),
           y = v.y + qw * ty + (qz * tx - qx * tz),
           z = v.z + qw * tz + (qx * ty - qy * tx) }
end

-- rotate a world-frame vector into the body frame: same thing, conjugate q
local function toBody(q, v)
  return toWorld({ x = -q.x, y = -q.y, z = -q.z, w = q.w }, v)
end
```

The thrust axis in world coordinates is just `toWorld(q, T_BODY)` where `T_BODY`
is the unit vector along `t`. That single line replaces the whole tilt
calculation, and it is well behaved at every attitude including inverted.

Attitude error for the inner loop is the error quaternion, whose vector part is
the rotation error and feeds the controller directly. No angles anywhere.

## Attitude without a working quaternion: two nav tables and the gimbal

Neither Sable's `getLogicalPose().orientation` nor this build's nav table
gives a quaternion. It can be built onboard instead.

A navigation table targeting the north magnet reports the angle of world north
projected into the table's own plane. One flat-mounted table plus the gimbal
(gravity's direction in body frame) is two reference vectors, which is enough
for full attitude, **except** when north lies along the table's normal: the
projection collapses and the angle is undefined. For a flat table that is 90
degrees of tilt, which is exactly the VTOL transition.

**Two tables in orthogonal planes remove the singularity**, since both cannot
be degenerate at once, and between them give the full north vector in body
frame. With gravity from the gimbal that is two vectors known in both frames:
the TRIAD problem, whose closed-form answer is a rotation matrix and hence a
quaternion, valid at every attitude.

| Airframe | Fit |
|---|---|
| hovering quad | one table, flat |
| transitioning VTOL | two tables, one flat and one vertical, orthogonal |

A third table adds nothing: north alone can never give rotation *about* north.
Gravity supplies that axis, so the gimbal stays regardless.

## Which frame does each source report in?

| Source | Frame | Notes |
|---|---|---|
| `sublevel.getLogicalPose().position` | world | double precision. **Unverified**: could be plot-grid rather than world, `probe.lua` settles it |
| `sublevel.getLogicalPose().orientation` | body to world | quaternion. **Unverified**: handedness and axis order, `probe.lua` settles it |
| `sublevel.getLinearVelocity()` | world | exact, no differencing |
| `sublevel.getAngularVelocity()` | **unverified** | world or body, `probe.lua` settles it |
| `sublevel.getCenterOfMass()` | body | offset from the pose origin |
| `gps.locate()` | world | quantised to whole blocks, see README |
| `altitude_sensor.getHeight()` | world | `Y` of that sensor block, not of the pose origin |
| `velocity_sensor.getVelocity()` | body | signed, along the axis `getAxis()` names |
| `velocity_sensor.getAxis()` | body | returns `"x"`, `"y"` or `"z"`, Aeronautics' own body-axis label, fixed at placement |
| `gimbal_sensor.getAngles()` | body vs level | two Euler angles, no third axis |
| `navigation_table.getHeading()` | world | **world-frame yaw, already corrected.** 0 = Minecraft south |
| `navigation_table.getOrientation()` | body to world | quaternion. Possibly the working attitude source, unlike Sable's |
| `navigation_table.getBearing()` | block frame | 0 = target ahead of the block's arrow |
| `navigation_table.getRelativeAngle()` | table's own tilted plane | needs de-rotating before use |

The `velocity_sensor.getAxis()` labels are Aeronautics' body frame, which is not
necessarily aligned with `t`/`n`/`s` as marked on the build. `probe.lua` prints
each sensor's axis so the mapping can be written down once and then trusted.

## Pose origin is not the pod

`getLogicalPose().position` is the sub-level's pose origin, not any particular
block. To get a specific block's world position, take its offset in sub-level
coordinates and rotate that offset by the orientation quaternion before adding
it. This matters for the docking connector and is why `fly.lua` keeps using the
altitude sensor rather than deriving height from the pose.

## Open questions

`probe.lua` on the pod answers all of these, and this document should be updated
with the measured answers rather than left with the guesses:

1. Is `pose.position` world or plot-grid?
2. Does the orientation quaternion rotate body to world, or world to body?
3. Is `getAngularVelocity` world or body?
4. Which of Aeronautics' body `x`/`y`/`z` corresponds to `t`, `n` and `s`?
