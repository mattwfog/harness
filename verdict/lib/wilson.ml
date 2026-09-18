let z_95 = 1.959963984540054

let interval ~fires ~n =
  if n <= 0 then invalid_arg "n must be positive";
  if fires < 0 || fires > n then invalid_arg "fires must be in [0, n]";
  let proportion = float_of_int fires /. float_of_int n in
  let n_float = float_of_int n in
  let z_squared = z_95 *. z_95 in
  let denominator = 1.0 +. (z_squared /. n_float) in
  let center =
    (proportion +. (z_squared /. (2.0 *. n_float))) /. denominator
  in
  let half_width =
    (z_95 /. denominator)
    *. sqrt
         ((proportion *. (1.0 -. proportion) /. n_float)
         +. (z_squared /. (4.0 *. n_float *. n_float)))
  in
  (Float.max 0.0 (center -. half_width), Float.min 1.0 (center +. half_width))

let wilson_interval fires n = interval ~fires ~n
