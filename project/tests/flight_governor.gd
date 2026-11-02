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
##   every physics frame:
##     var st := streamer.get_stats()
##     g.observe_loader(delta, st.disk_loads_needed, st.inflight >= terrain.streaming_concurrent_loads, metres_per_load)
##     g.step(delta, streamer.get_path_ready_distance(path_id))
##     scale the corridor radius, cone width and lookahead with g.quality (and g.safety), blur with g.speed_fraction()
##   metres_per_load = region size / regions in one column of the corridor at the current radius.
##   then place the camera at path(g.distance) with g.altitude, g.pitch and g.fov, and hold the landing
##   (keep hovering) until the destination is loaded: g.is_done(destination_loaded).
##
## Collision: dynamic collision refreshes cost about 25 ms per landed region near the camera. Set
## terrain.collision_mode = Terrain3DCollision.DISABLED at take-off and restore it at landing; set it after
## add_child (before it the mode is ignored).

## Upper clamp on the speed (m/s), not a target. Short hops never reach it. With auto_cap, setup() sets it from the
## flight distance: cap_low up to cap_d_low, rising linearly to cap_high at cap_d_high (2.5 km/s up to 12 km, 3.5 km/s
## at 28 km), so a 10 km flight keeps its ~5 s and a 28 km flight is not twice as long. Scale the blur to speed / max_speed.
var max_speed := 2500.0
var auto_cap := true
var cap_low := 2500.0
var cap_high := 3500.0
var cap_d_low := 12000.0
var cap_d_high := 28000.0
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
## SOFT GOVERNOR (v2). When the loader falls behind the camera does not wait for the braking distance clamp and nearly
## stop: the target speed is min(cap, 0.88 x the loader's sustainable rate, rate + k x (ready - desired margin)), changed
## with a fraction of the normal deceleration and jerk, after the sharp footprint was degraded (quality) before slowing.
## The braking distance clamp stays underneath as the hole free failsafe. Turn off for the v1 behaviour.
var soft := true
var soft_k := 0.3 ## 1/s: speed change per meter of ready distance above or below the desired margin
var ready_soft_tau := 1.2 ## s, time constant of the slower ready distance the soft law uses
var soft_decel_fraction := 0.35 ## of max_accel while adapting
var soft_jerk_fraction := 0.3 ## of max_jerk while adapting
var cruise_fraction := 0.88 ## cruise speed as a share of the measured sustainable rate
var floor_fraction := 0.3 ## the soft law never asks for less than this share of the cap
var margin_look := 0.25 ## s of travel kept as a buffer on top of safety and the stopping distance
var rate_tau := 2.0 ## s, time constant of a rise of the sustainable rate estimate (low bandwidth)
var rate_tau_down := 0.7 ## s, time constant of a fall (a loader that slows is believed sooner than one that speeds up)
var rate_hold_tau := 1.5 ## s, the soft law follows the rate estimate through this extra low pass
var rate_window := 0.5 ## s, length of one throughput sample
var stretch_until := 1.75 ## s: while no estimate exists yet, accelerate with stretch_accel x max_accel until here
var stretch_accel := 0.6
## Sharp footprint quality, 1 = full. It falls (quality_rate per s) while the loader limits the speed and does NOT recover
## during the flight (widening the corridor again would put missing regions right ahead of the camera); the caller
## restores it at landing with restore_quality(). The caller scales the corridor radius, cone width and margins with it. The governor scales safety by
## lerp(far_min_fraction, 1, quality).
var quality := 1.0
var quality_min := 0.45
var quality_rate := 0.35
var far_min_fraction := 0.6
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
var ready_soft := INF ## Slower copy of ready_filtered for the soft law (steps of a landed column do not move the target)
var clamp_hits := 0 ## Steps where the hard clamp had to hold the camera back (should stay 0)
var min_ready_margin := INF ## Smallest (ready distance - travel - safety) over the steps that were limited by loading
var plan_clearance := INF ## Smallest planned altitude above the terrain samples, from setup()
var rate_est := 0.0 ## Sustainable path rate estimate (m/s), valid once rate_valid
var rate_valid := false
var rate_hold := 0.0 ## rate_est smoothed further for the soft law
var rate_samples := 0
var elapsed := 0.0
var adapting := false ## The soft law is limiting the speed this step
var soft_speed := INF ## The soft target this step
var safety_full := -1.0
var _win_t := 0.0
var _win_sat := 0.0
var _win_loads := -1
var _observed := false
var _unsat_time := 0.0
var _limit_seen := false

var start_altitude := 0.0
var cruise_altitude := 0.0
var end_altitude := 0.0
var ramp_up := 0.0 ## Distance over which the climb eases in
var ramp_down := 0.0 ## Distance over which the descent eases out
var _pitch_vel := 0.0
var _fov_vel := 0.0


## The speed cap for a flight of this distance
func cap_for_distance(d: float) -> float:
	return lerpf(cap_low, cap_high, clampf((d - cap_d_low) / maxf(cap_d_high - cap_d_low, 1.0), 0.0, 1.0))


## Blur strength and similar effects scale to this (0..1 of the cap for this flight)
func speed_fraction() -> float:
	return clampf(speed / max_speed, 0.0, 1.0)


## Feed the loader's throughput: disk_loads_total is the running count of threaded loads consumed for regions needed now
## (Terrain3DStreamer.get_stats().disk_loads_needed: not RAM cache insertions, not prefetch ahead of the path),
## saturated says the load queue was full (inflight >= concurrent_loads, so the rate is what the loader can do and not
## what was asked), metres_per_load is the path length one load advances the front (region size / regions per column).
## Call every physics frame before step().
func observe_loader(delta: float, disk_loads_total: int, saturated: bool, metres_per_load: float) -> void:
	_observed = true
	if _win_loads < 0:
		_win_loads = disk_loads_total
	_win_t += delta
	_win_sat += delta if saturated else 0.0
	if _win_t < rate_window:
		return
	var r := float(disk_loads_total - _win_loads) / _win_t * metres_per_load
	var a := 1.0 - exp(-_win_t / (rate_tau if r > rate_est else rate_tau_down))
	if _win_sat >= 0.9 * _win_t:
		rate_est = r if not rate_valid else lerpf(rate_est, r, a)
		rate_valid = true
		rate_samples += 1
	elif rate_valid and r > rate_est:
		rate_est = lerpf(rate_est, r, a) # Not saturated: the loader can do at least this
	_unsat_time = 0.0 if _win_sat >= 0.9 * _win_t else _unsat_time + _win_t
	_win_t = 0.0
	_win_sat = 0.0
	_win_loads = disk_loads_total


## Landed: the footprint goes back to full
func restore_quality() -> void:
	quality = 1.0


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
	if auto_cap:
		max_speed = cap_for_distance(path_length)
	rate_est = 0.0
	rate_hold = 0.0
	rate_valid = false
	rate_samples = 0
	elapsed = 0.0
	quality = 1.0
	_win_t = 0.0
	_win_sat = 0.0
	_win_loads = -1
	_observed = false
	_unsat_time = 0.0
	_limit_seen = false
	safety_full = -1.0
	distance = 0.0
	speed = 0.0
	accel = 0.0
	jerk = 0.0
	clamp_hits = 0
	min_ready_margin = INF
	ready_filtered = INF
	ready_soft = INF
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


## The ground in front of the camera that must be loaded for the sharp central area of the view (the edges
## are blurred): how far ahead (the ground at far_angle_deg below the horizon, at least) and how wide at that
## distance, from the cruise altitude, the pitch, the vertical field of view and the share of it that is sharp.
## Use far as safety and half_width as the corridor radius and the cone half width.
static func view_footprint(p_altitude: float, p_pitch_deg: float, p_vfov_deg: float, p_aspect: float = 16.0 / 9.0,
		p_sharp: float = 0.35, p_far_angle_deg: float = 6.0, p_margin: float = 100.0) -> Dictionary:
	var sharp_v := p_vfov_deg * p_sharp
	var angle := maxf(-p_pitch_deg - sharp_v * 0.5, p_far_angle_deg) # Below the horizon at the sharp area's far edge
	var far := p_altitude / tan(deg_to_rad(angle))
	var sharp_h := 2.0 * atan(tan(deg_to_rad(sharp_v) * 0.5) * p_aspect)
	return {"far": far, "half_width": far * tan(sharp_h * 0.5) + p_margin}


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


## The smooth loader limited target: settles where the speed equals the loader's sustainable rate and the
## ready distance equals the desired margin (safety + stopping distance + a short buffer).
func soft_target() -> float:
	if not soft:
		return INF
	# Once the loader has limited the flight the speed is held at a share of its rate, also when everything ahead
	# is loaded, so the flight is one smooth profile and does not speed up at the end
	var hold := INF
	if rate_valid and _limit_seen:
		hold = clampf(cruise_fraction * rate_hold, floor_fraction * max_speed, max_speed)
	if is_inf(ready_soft):
		return hold
	var margin := safety + stop_distance(speed, max_accel * brake_fraction, max_jerk) + speed * margin_look
	var rate_ref := rate_hold * 0.95 if rate_valid else speed
	var v := rate_ref + soft_k * (ready_soft - margin)
	return minf(clampf(v, floor_fraction * max_speed, max_speed), hold)


func step(delta: float, ready_distance: float = INF) -> void:
	var dt := maxf(delta, 1e-4)
	elapsed += dt
	if safety_full < 0.0:
		safety_full = safety
	if soft:
		safety = safety_full * lerpf(far_min_fraction, 1.0, quality)
	var remaining := length - distance
	# Filtered ready distance: what was ready minus what was flown, rising smoothly, dropping at once. A
	# path that is ready to its end limits nothing.
	var limited := not is_inf(ready_distance) and ready_distance < remaining - 1.0
	if not limited:
		ready_filtered = INF
		ready_soft = INF
	elif is_inf(ready_filtered):
		ready_filtered = ready_distance
	else:
		var predicted := ready_filtered - speed * dt
		if ready_distance < predicted:
			ready_filtered = ready_distance
		else:
			ready_filtered = predicted + (ready_distance - predicted) * (1.0 - exp(-dt / ready_tau))
	if not is_inf(ready_filtered):
		ready_soft = ready_filtered if is_inf(ready_soft) else lerpf(ready_soft - speed * dt, ready_filtered, 1.0 - exp(-dt / ready_soft_tau))
	var a_prev := accel
	var v_hard := target_speed()
	var v_soft := soft_target()
	soft_speed = v_soft
	var v_target := minf(v_hard, v_soft)
	adapting = soft and v_soft < v_hard and v_soft < max_speed * 0.995
	var ready_brake := INF if is_inf(ready_filtered) else speed_for_distance(ready_filtered - safety, max_accel * brake_fraction, max_jerk)
	var loader_limited := soft and rate_valid and minf(v_soft, ready_brake) < max_speed * 0.97
	_limit_seen = _limit_seen or loader_limited
	if rate_valid:
		rate_hold = rate_est if rate_hold <= 0.0 else lerpf(rate_hold, rate_est, 1.0 - exp(-dt / rate_hold_tau))
	if soft and rate_valid and limited and _unsat_time >= 0.5:
		# The queue is not full although regions are missing: the loader is not the limit, probe upwards slowly
		rate_est = minf(rate_est * (1.0 + 0.25 * dt), max_speed / cruise_fraction)
	if soft:
		if loader_limited:
			quality = maxf(quality - quality_rate * dt, quality_min) # Shrink the sharp footprint before slowing further
	if adapting:
		# Smooth loader limited speed: a fraction of the normal deceleration and jerk, no braking curve
		# Once the loader has limited the flight both directions change gently; before that the take-off accelerates
		# normally. Where the gentle jerk could not stop the speed at the target in time, the full jerk is used.
		var a_lim := max_accel * soft_decel_fraction if (v_target < speed or _limit_seen) else max_accel
		var j_soft := max_jerk * soft_jerk_fraction
		var j_use := j_soft if (accel <= 0.0 or speed + accel * accel / (2.0 * j_soft) <= v_target * 1.02) else max_jerk
		accel = track(speed, accel, v_target, a_lim, j_use, dt)
	elif v_target < max_speed - 1.0:
		# A braking constraint is active. Its target falls along the stopping curve as the camera
		# approaches, so follow it with its rate of change fed forward (a plain error law would trail it
		# and brake too late), still jerk limited.
		var a_ff := minf((target_speed(speed * dt) - v_target) / dt, 0.0)
		var a_cmd := clampf(a_ff + (v_target - speed) / brake_tau, -max_accel, max_accel)
		accel = a_prev + clampf((a_cmd - a_prev) / dt, -max_jerk, max_jerk) * dt
	else:
		var a_up := max_accel * stretch_accel if (soft and _observed and not rate_valid and elapsed < stretch_until and speed < 0.7 * max_speed) else max_accel
		accel = track(speed, accel, v_target, a_up, max_jerk, dt)
	var v_new := clampf(speed + accel * dt, 0.0, max_speed)
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
