extends RefCounted
## Reference camera flight governor (game side example, not part of the addon).
##
## Flies a camera along a path like a fast helicopter: jerk limited S-curve speed, a smooth climb to a
## constant cruise altitude that starts with the take-off acceleration, a level cruise, and a descent that
## finishes with the deceleration. The altitude is PLANNED, not followed: the cruise altitude is the highest
## terrain along the path plus a clearance (the terrain heights come from a source that does not depend on
## the loaded regions, in the game the world wide low resolution map), so the camera never bobs over hills.
##
## The target speed is never faster than the loaded terrain allows. Every step it is clamped to the speed
## from which the camera can still stop inside the terrain that is visible, the braking distance constraint
## v = sqrt(2 * a_brake * (ready - safety)) (the exact jerk limited form is used here), and the clamped
## target goes through the jerk limited filter, so there is no jolt when the loader is slow. The ready
## distance comes from Terrain3DStreamer.get_path_ready_distance(). It jumps by a region every time one
## lands, so it passes a one sided filter: a drop applies at once, a rise is low passed. Pass INF when
## nothing limits the flight.
##
## Use:
##   const FlightGovernor := preload("res://tests/flight_governor.gd")
##   var g := FlightGovernor.new()
##   g.setup(path_length, heights, 50.0, ground_start, ground_end)
##   every physics frame: g.step(delta, streamer.get_path_ready_distance(path_id))
##   then place the camera at path(g.distance) with g.altitude, g.pitch and g.fov, and hold the landing
##   (keep hovering) until the destination is loaded: g.is_done(destination_loaded).
##
## Collision: dynamic collision refreshes cost about 25 ms per landed region near the camera. Set
## terrain.collision_mode = Terrain3DCollision.DISABLED at take-off and restore it at landing; set it after
## add_child (before it the mode is ignored).

## Upper clamp on the speed (m/s), not a target. Short hops never reach it.
var max_speed := 2500.0
var max_accel := 4000.0 ## m/s^2
var max_jerk := 12000.0 ## m/s^3
## Share of max_accel the governor plans a stop inside the loaded terrain with, the rest is reserve.
var brake_fraction := 0.7
## Share of max_accel the final stop at the end of the path is planned with.
var end_brake_fraction := 0.9
## Meters of loaded terrain that must remain in front of the camera at all times.
var safety := 600.0
## Time constant (s) of the rise of the filtered ready distance. Drops are not filtered.
var ready_tau := 0.4
## Time constant (s) with which a braking target is followed.
var brake_tau := 0.15
## Comfort limits of the climb and descent. The ramp distances are stretched until the planned altitude
## stays inside them at max_speed.
var vert_max_accel := 3000.0
var vert_max_jerk := 9000.0
## Height above the terrain at take-off and landing, and the margin above the highest terrain at cruise.
var start_height := 100.0
var landing_height := 100.0
var cruise_clearance := 150.0
## Camera attitude: base pitch (negative looks down), nose-down per full forward acceleration, spring rate.
var base_pitch_deg := -12.0
var accel_pitch_deg := 8.0
var spring_omega := 6.0
var base_fov := 75.0
var fov_extra := 5.0

# State
var length := 0.0 ## Path length (m)
var distance := 0.0 ## Travelled along the path (m)
var speed := 0.0
var accel := 0.0
var jerk := 0.0
var altitude := 0.0
var climb_speed := 0.0
var climb_accel := 0.0
var pitch := 0.0 ## Radians, negative is nose down
var fov := 75.0
var ready_filtered := INF
var clamp_hits := 0 ## Steps where the hard clamp had to hold the camera back (should stay 0)
var min_ready_margin := INF ## Smallest (ready distance - travel - safety) over the steps that were limited by loading
var plan_clearance := INF ## Smallest planned altitude above the terrain samples, from setup()

var start_altitude := 0.0
var cruise_altitude := 0.0
var end_altitude := 0.0
var ramp_up := 0.0 ## Distance over which the climb eases in
var ramp_down := 0.0 ## Distance over which the descent eases out
var _pitch_vel := 0.0
var _fov_vel := 0.0


## Distance in which a jerk limited stop from v completes
static func stop_distance(v: float, a_max: float, j_max: float) -> float:
	if v <= 0.0:
		return 0.0
	if v >= a_max * a_max / j_max:
		return v * v / (2.0 * a_max) + v * a_max / (2.0 * j_max)
	return v * sqrt(v / j_max)


## Inverse of stop_distance: the speed from which a jerk limited stop takes exactly d
static func speed_for_distance(d: float, a_max: float, j_max: float) -> float:
	if d <= 0.0:
		return 0.0
	var knee := a_max * a_max / j_max
	if d >= stop_distance(knee, a_max, j_max):
		var q := a_max * a_max / (2.0 * j_max)
		return -q + sqrt(q * q + 2.0 * a_max * d)
	return pow(d * sqrt(j_max), 2.0 / 3.0)


static func smootherstep(t: float) -> float:
	t = clampf(t, 0.0, 1.0)
	return t * t * t * (t * (t * 6.0 - 15.0) + 10.0)


## Acceleration after one step of a jerk limited tracker that takes a value moving at v with acceleration a
## to v_target and ends with zero acceleration.
static func track(v: float, a: float, v_target: float, a_max: float, j_max: float, dt: float) -> float:
	var v_settled := v + a * absf(a) / (2.0 * j_max) # Where v ends up if the acceleration were removed now
	var e := v_target - v_settled
	# The square root law alone has an infinite gain at zero error and hunts at one frame steps, so cap the gain
	var a_des := signf(e) * minf(a_max, minf(sqrt(2.0 * j_max * absf(e)), 12.0 * absf(e)))
	var j := clampf((a_des - a) / dt, -j_max, j_max)
	return a + j * dt


## path_length in meters; heights are the terrain under the path every sample_step meters (from a source
## that does not depend on the loaded regions, e.g. the world wide low resolution map).
func setup(path_length: float, heights: PackedFloat32Array, sample_step: float, ground_start: float, ground_end: float) -> void:
	length = path_length
	distance = 0.0
	speed = 0.0
	accel = 0.0
	jerk = 0.0
	clamp_hits = 0
	min_ready_margin = INF
	ready_filtered = INF
	var top := ground_start
	for h in heights:
		top = maxf(top, h)
	start_altitude = ground_start + start_height
	end_altitude = ground_end + landing_height
	cruise_altitude = maxf(top + cruise_clearance, maxf(start_altitude, end_altitude))
	ramp_up = _ramp(cruise_altitude - start_altitude)
	ramp_down = _ramp(cruise_altitude - end_altitude)
	altitude = start_altitude
	plan_clearance = INF
	for i in heights.size():
		plan_clearance = minf(plan_clearance, planned_altitude(minf(float(i) * sample_step, length)) - heights[i])
	climb_speed = 0.0
	climb_accel = 0.0
	pitch = deg_to_rad(base_pitch_deg)
	_pitch_vel = 0.0
	fov = base_fov
	_fov_vel = 0.0


## The distance the speed ramp takes at max_speed, stretched until a smootherstep of the given height over
## it keeps the vertical acceleration (including the share from the horizontal acceleration) and jerk
## inside the comfort limits, and at most half the path.
func _ramp(height: float) -> float:
	var r := stop_distance(max_speed, max_accel, max_jerk)
	while r < length * 0.5:
		var a_v := 5.77 * height * max_speed * max_speed / (r * r) + 1.875 * height / r * max_accel
		var j_v := 60.0 * height * pow(max_speed / r, 3.0)
		if a_v <= vert_max_accel and j_v <= vert_max_jerk:
			break
		r *= 1.1
	return minf(r, length * 0.5)


## Landed: at the end of the path, at rest, and the destination loaded
func is_done(dest_ready: bool = true) -> bool:
	return length - distance <= 0.5 and speed < 1.0 and dest_ready


## Planned altitude at a distance along the path: monotone up with the take-off, level, monotone down
## with the landing. Smootherstep eases both ends, so velocity and acceleration are continuous.
func planned_altitude(s: float) -> float:
	var up := smootherstep(s / ramp_up) if ramp_up > 0.0 else 1.0
	var dn := smootherstep((length - s) / ramp_down) if ramp_down > 0.0 else 1.0
	var level := start_altitude + (cruise_altitude - start_altitude) * up
	return end_altitude + (level - end_altitude) * dn


## Speed the camera may have now: the cap, the stop at the end of the path, and the stop inside the
## visible terrain. Both stops start after the acceleration has come back to zero (the distance and
## speed gained meanwhile are counted), which is what a jerk limited reversal really needs. p_advance
## evaluates the target after the camera moved that far, to get its rate of change.
func target_speed(p_advance: float = 0.0) -> float:
	var settle := 0.0
	if accel > 0.0:
		var gained := accel * accel / (2.0 * max_jerk)
		settle = (2.0 * speed + gained) * 0.5 * accel / max_jerk
	var remaining := length - distance - p_advance
	var v := minf(max_speed, speed_for_distance(remaining - settle, max_accel * end_brake_fraction, max_jerk))
	if not is_inf(ready_filtered):
		v = minf(v, speed_for_distance(ready_filtered - p_advance - safety - settle, max_accel * brake_fraction, max_jerk))
	return v


func step(delta: float, ready_distance: float = INF) -> void:
	var dt := maxf(delta, 1e-4)
	var remaining := length - distance
	# Filtered ready distance: what was ready minus what was flown, rising smoothly, dropping at once. A
	# path that is ready to its end limits nothing.
	var limited := not is_inf(ready_distance) and ready_distance < remaining - 1.0
	if not limited:
		ready_filtered = INF
	elif is_inf(ready_filtered):
		ready_filtered = ready_distance
	else:
		var predicted := ready_filtered - speed * dt
		if ready_distance < predicted:
			ready_filtered = ready_distance
		else:
			ready_filtered = predicted + (ready_distance - predicted) * (1.0 - exp(-dt / ready_tau))
	var a_prev := accel
	var v_target := target_speed()
	if v_target < max_speed - 1.0:
		# A braking constraint is active. Its target falls along the stopping curve as the camera
		# approaches, so follow it with its rate of change fed forward (a plain error law would trail it
		# and brake too late), still jerk limited.
		var a_ff := minf((target_speed(speed * dt) - v_target) / dt, 0.0)
		var a_cmd := clampf(a_ff + (v_target - speed) / brake_tau, -max_accel, max_accel)
		accel = a_prev + clampf((a_cmd - a_prev) / dt, -max_jerk, max_jerk) * dt
	else:
		accel = track(speed, accel, v_target, max_accel, max_jerk, dt)
	var v_new := maxf(speed + accel * dt, 0.0)
	var ds := (speed + v_new) * 0.5 * dt
	# Failsafe: never move into the last `safety` meters in front of the camera's loaded terrain
	if limited:
		var allowed := maxf(ready_distance - safety, 0.0)
		if ds > allowed:
			clamp_hits += 1 if ds - allowed > 0.5 else 0
			ds = allowed
	jerk = (accel - a_prev) / dt
	speed = v_new
	distance = minf(distance + ds, length)
	if length - distance <= 0.5 and speed < 2.0:
		distance = length
		speed = 0.0
		accel = 0.0
	if limited:
		min_ready_margin = minf(min_ready_margin, ready_distance - ds - safety)
	var z_prev := altitude
	var vz_prev := climb_speed
	altitude = planned_altitude(distance)
	climb_speed = (altitude - z_prev) / dt
	climb_accel = (climb_speed - vz_prev) / dt
	_step_attitude(dt)


func _step_attitude(dt: float) -> void:
	var target := deg_to_rad(base_pitch_deg) - clampf(accel / max_accel, -1.0, 1.0) * deg_to_rad(accel_pitch_deg)
	var w := spring_omega
	_pitch_vel += (w * w * (target - pitch) - 2.0 * w * _pitch_vel) * dt
	pitch += _pitch_vel * dt
	var f_target := base_fov + fov_extra * clampf(speed / max_speed, 0.0, 1.0)
	_fov_vel += (w * w * (f_target - fov) - 2.0 * w * _fov_vel) * dt
	fov += _fov_vel * dt
