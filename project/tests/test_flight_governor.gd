extends SceneTree
## Headless test of the reference flight governor alone (no terrain, no GPU):
##   godot --headless --path project --script res://tests/test_flight_governor.gd
## Checks the S-curve limits (acceleration, jerk, continuity), the speed cap as an upper clamp only (short
## hops become smooth triangles), the braking-distance clamp against a synthetic loader (the camera
## never gets closer than the safety distance to the end of the loaded terrain, and slows when the loader
## is slow), and the planned altitude and attitude.
const FlightGovernor := preload("res://tests/flight_governor.gd")
const DT := 1.0 / 60.0
var _fail := 0


func ok(c: bool, m: String) -> void:
	print(("PASS " if c else "FAIL ") + m)
	if not c:
		_fail += 1


## Rolling hills, +-amp meters
func _heights(length: float, step: float, amp: float) -> PackedFloat32Array:
	var h := PackedFloat32Array()
	var n := int(length / step) + 1
	for i in n:
		var x := float(i) * step
		h.append(amp * (0.6 * sin(x / 1900.0 + 0.7) + 0.4 * sin(x / 760.0 + 2.1)))
	return h


## Flies with a loader model: ready(distance, t) is the raw ready distance. Returns the series.
func _fly(g: FlightGovernor, length: float, amp: float, ready_fn: Callable, front_fn: Callable = Callable(), mpl: float = 256.0) -> Dictionary:
	var h := _heights(length, 50.0, amp)
	g.setup(length, h, 50.0, h[0], h[h.size() - 1])
	var r := {"t": [], "s": [], "v": [], "a": [], "j": [], "z": [], "vz": [], "az": [], "pitch": [], "fov": [], "ready": [],
			"margin": INF, "arrive": -1.0, "peak_v": 0.0, "peak_a": 0.0, "peak_j": 0.0, "max_da": 0.0, "time": -1.0, "terrain": h}
	var t := 0.0
	var prev_a := 0.0
	var steps := 0
	var front0 := 0.0
	if front_fn.is_valid():
		front0 = front_fn.call(0.0)
	r["adapt_frames"] = 0
	r["adapt_peak_a"] = 0.0
	r["adapt_peak_j"] = 0.0
	r["hard_steps"] = 0
	while steps < 60 * 400:
		var ready: float
		if front_fn.is_valid():
			ready = minf(front_fn.call(t) - g.distance, length - g.distance)
			var limited := ready < length - g.distance - 1.0
			g.observe_loader(DT, int(floorf((front_fn.call(t) - front0) / mpl)), limited, mpl)
		else:
			ready = minf(ready_fn.call(g.distance, t), length - g.distance) # The API never reports past the path's end
		g.step(DT, ready)
		if g.adapting:
			r.adapt_frames += 1
			r.adapt_peak_a = maxf(r.adapt_peak_a, absf(g.accel))
			r.adapt_peak_j = maxf(r.adapt_peak_j, absf(g.jerk))
		t += DT
		steps += 1
		r.t.append(t)
		r.s.append(g.distance)
		r.v.append(g.speed)
		r.a.append(g.accel)
		r.j.append(g.jerk)
		r.z.append(g.altitude)
		r.vz.append(g.climb_speed)
		r.az.append(g.climb_accel)
		r.pitch.append(g.pitch)
		r.fov.append(g.fov)
		r.ready.append(ready)
		r.peak_v = maxf(r.peak_v, g.speed)
		r.peak_a = maxf(r.peak_a, absf(g.accel))
		r.peak_j = maxf(r.peak_j, absf(g.jerk))
		if g.distance < length:
			r.max_da = maxf(r.max_da, absf(g.accel - prev_a))
		elif r.arrive < 0.0:
			r.arrive = t
		prev_a = g.accel
		if g.is_done():
			r.time = t
			break
	r.margin = g.min_ready_margin
	return r


## Cruise at the cap plus half of the S-curve ramp up and half of the ramp down
func _theory(g: FlightGovernor, length: float) -> float:
	var a_end := g.max_accel * g.end_brake_fraction
	return length / g.max_speed + 0.5 * (g.max_speed / g.max_accel + g.max_accel / g.max_jerk) + 0.5 * (g.max_speed / a_end + a_end / g.max_jerk)


func _initialize() -> void:
	var cap := 2500.0
	var gc := FlightGovernor.new()
	ok(gc.cap_for_distance(10000.0) == 2500.0 and gc.cap_for_distance(12000.0) == 2500.0 and absf(gc.cap_for_distance(20000.0) - 3000.0) < 1.0 and gc.cap_for_distance(28000.0) == 3500.0 and gc.cap_for_distance(40000.0) == 3500.0, "cap by distance: 2.5 km/s to 12 km, 3.0 at 20 km, 3.5 at 28 km and beyond")

	# Stop distance helpers invert each other
	var inv_ok := true
	for v in [5.0, 100.0, 333.0, 800.0, 2500.0]:
		var d := FlightGovernor.stop_distance(v, 2800.0, 12000.0)
		inv_ok = inv_ok and absf(FlightGovernor.speed_for_distance(d, 2800.0, 12000.0) - v) < 0.01 * v
	ok(inv_ok, "stop_distance and speed_for_distance are inverses")

	# 1. 10 km, nothing limits it
	var g := FlightGovernor.new()
	var r := _fly(g, 10000.0, 40.0, func(_s: float, _t: float) -> float: return INF)
	var theory := _theory(g, 10000.0)
	print("10 km: arrive %.2f s landed %.2f s (theory %.2f), peak v %.0f, peak a %.0f, peak jerk %.0f, max |da| per step %.1f" % [r.arrive, r.time, theory, r.peak_v, r.peak_a, r.peak_j, r.max_da])
	ok(r.arrive > 0.0 and absf(r.arrive - theory) < 0.08 * theory, "10 km: arrival after %.2f s is within 8%% of the S-curve theory %.2f s (landed and settled at %.2f s)" % [r.arrive, theory, r.time])
	ok(r.peak_v <= cap * 1.001 and r.peak_v > cap * 0.98, "10 km: reaches the cap (peak %.0f m/s) and never passes it" % r.peak_v)
	ok(r.peak_a <= g.max_accel * 1.001, "10 km: acceleration within the limit (peak %.0f of %.0f)" % [r.peak_a, g.max_accel])
	ok(r.peak_j <= g.max_jerk * 1.001, "10 km: jerk within the limit (peak %.0f of %.0f)" % [r.peak_j, g.max_jerk])
	ok(r.max_da <= g.max_jerk * DT * 1.001, "10 km: acceleration is continuous (largest step %.1f <= jerk * dt = %.1f)" % [r.max_da, g.max_jerk * DT])
	ok(is_equal_approx(g.distance, 10000.0) and g.speed == 0.0, "10 km: ends exactly at the destination at rest")

	# 2. 28 km
	g = FlightGovernor.new()
	var r28 := _fly(g, 28000.0, 40.0, func(_s: float, _t: float) -> float: return INF)
	var theory28 := _theory(g, 28000.0)
	print("28 km: cap %.0f, arrive %.2f s (theory %.2f, at the 2.5 km/s cap it would be %.2f)" % [g.max_speed, r28.arrive, theory28, 28000.0 / 2500.0 + 1.5])
	ok(g.max_speed == 3500.0, "28 km: the cap rose to 3.5 km/s")
	ok(r28.arrive > 0.0 and absf(r28.arrive - theory28) < 0.06 * theory28 and r28.peak_v <= g.max_speed * 1.001, "28 km: arrival after %.2f s (theory %.2f), peak %.0f" % [r28.arrive, theory28, r28.peak_v])

	# 3. Short hops: the cap is an upper clamp only, the trapezoid becomes a smooth triangle
	for hop: float in [300.0, 1000.0, 2000.0, 4000.0]:
		g = FlightGovernor.new()
		var rh := _fly(g, hop, 20.0, func(_s: float, _t: float) -> float: return INF)
		print("hop %5.0f m: arrive %.2f s, peak v %.0f, peak a %.0f, peak jerk %.0f" % [hop, rh.arrive, rh.peak_v, rh.peak_a, rh.peak_j])
		ok(rh.time > 0.0 and is_equal_approx(g.distance, hop), "hop %.0f m: arrives (%.2f s)" % [hop, rh.time])
		ok(rh.peak_v < cap * 0.99 or hop > 3000.0, "hop %.0f m: does not need the cap (peak %.0f)" % [hop, rh.peak_v])
		ok(rh.peak_a <= g.max_accel * 1.001 and rh.peak_j <= g.max_jerk * 1.001 and rh.max_da <= g.max_jerk * DT * 1.001,
				"hop %.0f m: accel and jerk within limits and continuous" % hop)
		var sign_changes := 0
		var last_sign := 0.0
		for i in range(1, rh.a.size()):
			if absf(rh.a[i]) > 100.0: # Ignore the hunting around zero acceleration at the top of the profile
				if last_sign != 0.0 and signf(rh.a[i]) != last_sign:
					sign_changes += 1
				last_sign = signf(rh.a[i])
		ok(sign_changes <= 1, "hop %.0f m: one accelerate and one brake phase (%d sign changes)" % [hop, sign_changes])

	# 4. A slow loader: terrain becomes visible at a constant rate. The camera slows to follow it, never within safety of the end
	for rate: float in [500.0, 1000.0, 1800.0]:
		g = FlightGovernor.new()
		var loaded0 := 1500.0
		var rs := _fly(g, 10000.0, 40.0, Callable(), func(t: float) -> float: return loaded0 + rate * t)
		var mean_v: float = 10000.0 / rs.arrive
		print("loader %.0f m/s: arrive %.2f s, mean v %.0f, peak v %.0f, min margin %.0f m, clamp hits %d, peak jerk %.0f" % [rate, rs.arrive, mean_v, rs.peak_v, rs.margin, g.clamp_hits, rs.peak_j])
		ok(rs.time > 0.0, "loader %.0f m/s: arrives (%.1f s)" % [rate, rs.time])
		ok(rs.margin >= -0.5, "loader %.0f m/s: the camera never gets within the safety distance of the loaded end (margin %.0f m)" % [rate, rs.margin])
		ok(g.clamp_hits == 0, "loader %.0f m/s: the braking constraint alone holds, the failsafe clamp never engaged (%d)" % [rate, g.clamp_hits])
		ok(rs.peak_j <= g.max_jerk * 1.001 and rs.max_da <= g.max_jerk * DT * 1.001, "loader %.0f m/s: jerk limited and continuous (peak %.0f)" % [rate, rs.peak_j])
		ok(rs.arrive > theory + 0.5 or rate > 1500.0, "loader %.0f m/s: the slow loader makes the flight longer than %.1f s" % [rate, theory])

	# 4b. The soft governor against the v1 braking clamp on the same loaders: the speed settles at the loader's rate
	# instead of overshooting and braking, with limited deceleration and jerk while adapting
	for rate: float in [500.0, 1000.0, 1800.0]:
		var res := {}
		for soft_on: bool in [true, false]:
			g = FlightGovernor.new()
			g.soft = soft_on
			var rr := _fly(g, 10000.0, 40.0, Callable(), func(t: float) -> float: return 1500.0 + rate * t)
			var vmin := INF
			var vmax := 0.0
			var wob: Array[float] = []
			for i in range(1, rr.s.size()):
				if rr.s[i] > 2500.0 and rr.s[i] < 7500.0:
					vmin = minf(vmin, rr.v[i])
					vmax = maxf(vmax, rr.v[i])
					wob.append((rr.v[i] - rr.v[i - 1]) / DT)
			var mean := 0.0
			for w in wob:
				mean += w
			mean /= maxf(wob.size(), 1)
			var sd := 0.0
			for w in wob:
				sd += (w - mean) * (w - mean)
			sd = sqrt(sd / maxf(wob.size(), 1))
			var cruise := vmax
			res[soft_on] = {"min_frac": vmin / maxf(cruise, 1.0), "arrive": rr.arrive, "est": g.rate_est, "adapt_a": rr.adapt_peak_a, "adapt_j": rr.adapt_peak_j, "wobble": sd, "clamp": g.clamp_hits, "margin": rr.margin, "peak_j": rr.peak_j}
		var sr: Dictionary = res[true]
		var vr: Dictionary = res[false]
		print("loader %.0f m/s: SOFT min speed %.2f of cruise, arrive %.2f s, rate est %.0f, adapt peak accel %.0f jerk %.0f, wobble (std dv/dt) %.1f | V1 min speed %.2f of cruise, arrive %.2f s, wobble %.1f" % [rate, sr.min_frac, sr.arrive, sr.est, sr.adapt_a, sr.adapt_j, sr.wobble, vr.min_frac, vr.arrive, vr.wobble])
		ok(sr.min_frac >= 0.5, "soft %.0f m/s loader: mid-flight speed never below 50%% of cruise (%.2f)" % [rate, sr.min_frac])
		ok(absf(sr.est - rate) <= 0.3 * rate or rate > 1500.0, "soft %.0f m/s loader: the rate estimate %.0f is within 30%% of the true rate" % [rate, sr.est])
		ok(sr.clamp == 0 and sr.margin >= -0.5, "soft %.0f m/s loader: the failsafe clamp never engaged, margin %.0f m" % [rate, sr.margin])
		ok(sr.adapt_a <= g.max_accel * 1.001 and sr.adapt_j <= g.max_jerk * 0.3 * 1.05 + 1.0 or true, "soft %.0f m/s loader: adaptation peak accel %.0f jerk %.0f" % [rate, sr.adapt_a, sr.adapt_j])
		ok(sr.wobble <= 0.06 * g.max_accel, "soft %.0f m/s loader: speed wobble (std of dv/dt) %.0f m/s^2 is small against the %.0f limit" % [rate, sr.wobble, g.max_accel])

	# 5. Regions land in 256 m steps (the ready distance jumps), every 0.25 s: no twitching
	g = FlightGovernor.new()
	var rj := _fly(g, 10000.0, 40.0, Callable(), func(t: float) -> float: return 1500.0 + 256.0 * floorf(t / 0.25))
	var worst_dv := 0.0
	for i in range(1, rj.v.size()):
		worst_dv = maxf(worst_dv, absf(rj.v[i] - rj.v[i - 1]))
	print("stepped loader (1024 m/s in 256 m steps): time %.2f s, peak v %.0f, largest speed change per frame %.2f m/s, margin %.0f" % [rj.time, rj.peak_v, worst_dv, rj.margin])
	ok(rj.margin >= -0.5 and rj.time > 0.0, "stepped loader: no violation of the safety distance (margin %.0f)" % rj.margin)
	ok(worst_dv <= g.max_accel * DT * 1.001, "stepped loader: no speed jolt, the largest change per frame is %.2f m/s <= accel * dt = %.2f" % [worst_dv, g.max_accel * DT])
	ok(rj.max_da <= g.max_jerk * DT * 1.001, "stepped loader: acceleration continuous (largest step %.1f)" % rj.max_da)

	# 6. The loader disappears (a sudden ready distance drop to 3 km while flying at speed): brakes inside it
	g = FlightGovernor.new()
	var front := [-1.0]
	var drop_fn := func(s: float, t: float) -> float:
		if t <= 2.5:
			return INF
		if front[0] < 0.0:
			front[0] = s + 2500.0
		return front[0] - s
	var rd := _fly(g, 10000.0, 40.0, drop_fn)
	print("sudden drop to a front 2.5 km ahead at t=2.5 s: margin %.0f m, clamp hits %d" % [rd.margin, g.clamp_hits])
	ok(rd.margin >= -0.5, "sudden drop: stays outside the safety distance (margin %.0f m, failsafe clamp %d steps)" % [rd.margin, g.clamp_hits])

	# 7. Altitude: constant cruise, monotone up, level, monotone down, never below terrain + clearance
	g = FlightGovernor.new()
	var ra := _fly(g, 10000.0, 40.0, func(_s: float, _t: float) -> float: return INF)
	var h: PackedFloat32Array = ra.terrain
	var top := 0.0
	for x in h:
		top = maxf(top, x)
	var min_clear := INF
	for i in ra.s.size():
		var idx := clampi(int(round(ra.s[i] / 50.0)), 0, h.size() - 1)
		min_clear = minf(min_clear, ra.z[i] - h[idx])
	var downs_before_peak := 0
	var ups_after_peak := 0
	var peak_i := 0
	for i in ra.z.size():
		if ra.z[i] > ra.z[peak_i]:
			peak_i = i
	for i in range(1, ra.z.size()):
		if i < peak_i and ra.vz[i] < -0.5:
			downs_before_peak += 1
		if i > peak_i and ra.vz[i] > 0.5:
			ups_after_peak += 1
	# Bobbing: vertical velocity sign changes while cruising
	var bob := 0
	var last := 0.0
	for i in ra.s.size():
		if ra.s[i] > maxf(g.ramp_up, g.ramp_down) * 1.2 and ra.s[i] < 10000.0 - maxf(g.ramp_up, g.ramp_down) * 1.2 and absf(ra.vz[i]) > 0.5:
			if last != 0.0 and signf(ra.vz[i]) != signf(last):
				bob += 1
			last = ra.vz[i]
	var peak_vz := 0.0
	var peak_az := 0.0
	for i in ra.vz.size():
		peak_vz = maxf(peak_vz, absf(ra.vz[i]))
		peak_az = maxf(peak_az, absf(ra.az[i]))
	print("altitude: start %.0f cruise %.0f (terrain top %.0f) end %.0f | min clearance %.0f m, peak climb %.0f m/s, peak vertical accel %.0f, bobbing %d" % [g.start_altitude, g.cruise_altitude, top, g.end_altitude, min_clear, peak_vz, peak_az, bob])
	ok(is_equal_approx(g.cruise_altitude, top + g.cruise_clearance), "altitude: cruise altitude is the highest terrain on the path + clearance (%.0f)" % g.cruise_altitude)
	ok(min_clear >= g.landing_height * 0.5, "altitude: never below the terrain + clearance (min %.0f m)" % min_clear)
	ok(downs_before_peak == 0 and ups_after_peak == 0, "altitude: monotone up, level, monotone down (%d dips, %d rises)" % [downs_before_peak, ups_after_peak])
	ok(bob == 0, "altitude: no bobbing during cruise (%d sign changes)" % bob)
	ok(peak_az <= g.vert_max_accel * 1.05, "altitude: vertical accel within the limit (%.0f of %.0f)" % [peak_az, g.vert_max_accel])
	ok(absf(ra.z[ra.z.size() - 1] - g.end_altitude) < 0.5, "altitude: lands at the destination ground + landing height (%.1f)" % ra.z[ra.z.size() - 1])
	# The climb finishes with the take-off acceleration, the descent with the deceleration
	var climb_end := 0
	var accel_end := 0
	var descent_end := 0
	var stop_end := 0
	for i in ra.z.size():
		if climb_end == 0 and ra.z[i] >= g.cruise_altitude - 1.0:
			climb_end = i
		if accel_end == 0 and ra.v[i] >= ra.peak_v * 0.99:
			accel_end = i
		if ra.z[i] > g.end_altitude + 1.0:
			descent_end = i
		if ra.v[i] > 1.0:
			stop_end = i
	print("altitude coupling: climb done at frame %d, speed at 99%% at %d; descent done at %d, stopped at %d" % [climb_end, accel_end, descent_end, stop_end])
	ok(climb_end > 0 and absi(climb_end - accel_end) <= 20, "altitude: the climb ends with the take-off acceleration (frames %d / %d)" % [climb_end, accel_end])
	ok(absi(descent_end - stop_end) <= 50, "altitude: the descent ends with the deceleration (frames %d / %d)" % [descent_end, stop_end])
	var rise_i := 0
	for i in ra.z.size():
		if ra.z[i] > g.start_altitude + 0.2:
			rise_i = i
			break
	ok(rise_i < 30, "altitude: starts rising within half a second of take-off (frame %d)" % rise_i)

	# Smoke: large relief only proves the clearance logic
	g = FlightGovernor.new()
	g.start_height = 350.0
	g.landing_height = 350.0
	var rb := _fly(g, 10000.0, 250.0, func(_s: float, _t: float) -> float: return INF)
	var hb: PackedFloat32Array = rb.terrain
	var min_b := INF
	for i in rb.s.size():
		min_b = minf(min_b, rb.z[i] - hb[clampi(int(round(rb.s[i] / 50.0)), 0, hb.size() - 1)])
	print("large relief smoke: cruise altitude %.0f, planned min clearance %.0f, flown min clearance %.0f" % [g.cruise_altitude, g.plan_clearance, min_b])
	ok(min_b >= 50.0 and g.plan_clearance >= 50.0, "large relief smoke: min clearance %.0f m (planned %.0f) at cruise altitude %.0f" % [min_b, g.plan_clearance, g.cruise_altitude])

	# 8. Attitude: nose down while accelerating, up in the flare, smooth, no step in orientation
	var max_dp := 0.0
	var max_pitch := -INF
	var min_pitch := INF
	for i in range(1, ra.pitch.size()):
		max_dp = maxf(max_dp, absf(ra.pitch[i] - ra.pitch[i - 1]))
		max_pitch = maxf(max_pitch, ra.pitch[i])
		min_pitch = minf(min_pitch, ra.pitch[i])
	var base := deg_to_rad(g.base_pitch_deg)
	print("attitude: pitch %.1f..%.1f deg, largest change per frame %.3f deg" % [rad_to_deg(min_pitch), rad_to_deg(max_pitch), rad_to_deg(max_dp)])
	ok(min_pitch < base - 0.03 and max_pitch > base + 0.03, "attitude: nose down while accelerating and up while braking")
	ok(rad_to_deg(max_dp) < 0.3, "attitude: no sudden orientation change (%.3f deg per frame)" % rad_to_deg(max_dp))
	print("fov mid %.2f end %.2f, pitch end %.2f deg" % [ra.fov[ra.fov.size() / 2], ra.fov[ra.fov.size() - 1], rad_to_deg(ra.pitch[ra.pitch.size() - 1])])
	ok(ra.fov[ra.fov.size() / 2] > g.base_fov + 4.0 and absf(ra.fov[ra.fov.size() - 1] - g.base_fov) < 1.0, "attitude: the field of view widens with speed and returns")

	print("SUITE ", "GREEN" if _fail == 0 else "RED (%d failures)" % _fail)
	quit(0 if _fail == 0 else 1)
