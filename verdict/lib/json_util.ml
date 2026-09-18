exception Schema_error of string

let fail path message = raise (Schema_error (path ^ ": " ^ message))

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let rec validate_json ~root = function
  | `Null | `Bool _ | `Int _ | `Intlit _ | `String _ -> ()
  | `Float value ->
      if Float.is_nan value || Float.is_infinite value then
        fail root "must not contain NaN or infinity"
  | `List values -> List.iter (validate_json ~root) values
  | `Assoc fields ->
      let seen = Hashtbl.create (List.length fields) in
      List.iter
        (fun (key, value) ->
          if Hashtbl.mem seen key then
            fail root (Printf.sprintf "duplicate object key %S" key);
          Hashtbl.add seen key ();
          validate_json ~root value)
        fields
  | `Tuple _ | `Variant _ -> fail root "invalid JSON value"

let parse_string ~path payload =
  let value =
    try Yojson.Safe.from_string payload with
    | Yojson.Json_error message -> fail path ("invalid JSON: " ^ message)
    | Failure message -> fail path ("invalid JSON: " ^ message)
  in
  validate_json ~root:path value;
  value

let parse_file ~path_label path = parse_string ~path:path_label (read_file path)

let require_object path = function
  | `Assoc fields -> fields
  | _ -> fail path "must be an object"

let require_array path = function
  | `List values -> values
  | _ -> fail path "must be an array"

let sorted_unique values = List.sort_uniq String.compare values

let require_exact_keys ~required ?(optional = []) path fields =
  let keys = List.map fst fields in
  let missing =
    List.filter (fun key -> not (List.mem key keys)) required |> List.sort String.compare
  in
  let allowed = required @ optional in
  let unknown =
    List.filter (fun key -> not (List.mem key allowed)) keys
    |> sorted_unique
  in
  if missing <> [] then fail path ("missing fields: " ^ String.concat ", " missing);
  if unknown <> [] then fail path ("unknown fields: " ^ String.concat ", " unknown)

let member fields name = List.assoc_opt name fields

let required_member path fields name =
  match member fields name with
  | Some value -> value
  | None -> fail path ("missing fields: " ^ name)

let require_string ?(nonempty = true) path = function
  | `String value ->
      if nonempty && String.trim value = "" then fail path "must not be empty";
      value
  | _ -> fail path "must be a string"

let require_bool path = function
  | `Bool value -> value
  | _ -> fail path "must be a boolean"

let require_int ?(minimum = 0) path = function
  | `Int value ->
      if value < minimum then fail path (Printf.sprintf "must be at least %d" minimum);
      value
  | `Intlit literal -> (
      match int_of_string_opt literal with
      | Some value ->
          if value < minimum then fail path (Printf.sprintf "must be at least %d" minimum);
          value
      | None -> fail path "integer is outside the supported OCaml range")
  | _ -> fail path "must be an integer"

let require_string_list ?(nonempty = false) path value =
  let values = require_array path value in
  let strings =
    List.mapi
      (fun index value -> require_string (Printf.sprintf "%s[%d]" path index) value)
      values
  in
  if nonempty && strings = [] then fail path "must not be empty";
  if List.length strings <> List.length (sorted_unique strings) then
    fail path "must not contain duplicates";
  strings

let is_lower_hex character =
  match character with '0' .. '9' | 'a' .. 'f' -> true | _ -> false

let require_sha256 path value =
  let digest = require_string path value in
  if String.length digest <> 64 || not (String.for_all is_lower_hex digest) then
    fail path "must be a lowercase sha256 hex digest";
  digest

let int_substring value offset length =
  int_of_string_opt (String.sub value offset length)

let leap_year year = year mod 4 = 0 && (year mod 100 <> 0 || year mod 400 = 0)

let valid_date_parts year month day =
  let days =
    match month with
    | 1 | 3 | 5 | 7 | 8 | 10 | 12 -> 31
    | 4 | 6 | 9 | 11 -> 30
    | 2 -> if leap_year year then 29 else 28
    | _ -> 0
  in
  year >= 1 && day >= 1 && day <= days

let valid_date_text value =
  String.length value = 10
  && value.[4] = '-'
  && value.[7] = '-'
  &&
  match
    (int_substring value 0 4, int_substring value 5 2, int_substring value 8 2)
  with
  | Some year, Some month, Some day -> valid_date_parts year month day
  | _ -> false

let require_date path value =
  let text = require_string path value in
  if not (valid_date_text text) then fail path "must be an ISO 8601 date";
  text

let all_digits value start length =
  let rec loop index =
    index = start + length
    ||
    match value.[index] with
    | '0' .. '9' -> loop (index + 1)
    | _ -> false
  in
  start >= 0 && length >= 0 && start + length <= String.length value && loop start

let valid_timezone value offset =
  let remaining = String.length value - offset in
  if remaining = 1 && value.[offset] = 'Z' then true
  else if remaining = 6 && (value.[offset] = '+' || value.[offset] = '-') then
    value.[offset + 3] = ':'
    && all_digits value (offset + 1) 2
    && all_digits value (offset + 4) 2
    &&
    match (int_substring value (offset + 1) 2, int_substring value (offset + 4) 2) with
    | Some hours, Some minutes -> hours < 24 && minutes < 60
    | _ -> false
  else false

let valid_datetime_text value =
  let length = String.length value in
  if length < 20 || not (valid_date_text (String.sub value 0 10)) then false
  else
    let time_start = 11 in
    if value.[13] <> ':' || value.[16] <> ':'
       || not (all_digits value time_start 2)
       || not (all_digits value (time_start + 3) 2)
       || not (all_digits value (time_start + 6) 2)
    then false
    else
      match
        ( int_substring value time_start 2,
          int_substring value (time_start + 3) 2,
          int_substring value (time_start + 6) 2 )
      with
      | Some hours, Some minutes, Some seconds
        when hours < 24 && minutes < 60 && seconds < 60 ->
          let after_seconds = 19 in
          if after_seconds >= length then false
          else if value.[after_seconds] = '.' then
            let rec fraction_end index =
              if index < length then
                match value.[index] with
                | '0' .. '9' -> fraction_end (index + 1)
                | _ -> index
              else index
            in
            let timezone_at = fraction_end (after_seconds + 1) in
            timezone_at > after_seconds + 1 && valid_timezone value timezone_at
          else valid_timezone value after_seconds
      | _ -> false

let require_datetime path value =
  let text = require_string path value in
  if not (valid_datetime_text text) then
    if String.length text >= 19 && valid_date_text (String.sub text 0 10) then
      fail path "must include a UTC offset"
    else fail path "must be an ISO 8601 datetime";
  text

let python_float_to_string value =
  if value = 0. then
    if Int64.bits_of_float value = Int64.min_int then "-0.0" else "0.0"
  else
    let negative = value < 0. in
    let magnitude = Float.abs value in
    let rec shortest_precision precision =
      if precision = 17 then precision
      else
        let candidate = Printf.sprintf "%.*g" precision magnitude in
        if float_of_string candidate = magnitude then precision
        else shortest_precision (precision + 1)
    in
    let precision = shortest_precision 1 in
    let scientific = Printf.sprintf "%.*e" (precision - 1) magnitude in
    let exponent_marker = String.index scientific 'e' in
    let mantissa = String.sub scientific 0 exponent_marker in
    let exponent =
      String.sub scientific (exponent_marker + 1)
        (String.length scientific - exponent_marker - 1)
      |> int_of_string
    in
    let digits =
      String.to_seq mantissa
      |> Seq.filter (fun character -> character <> '.')
      |> String.of_seq
    in
    let unsigned =
      if exponent >= -4 && exponent < 16 then
        let decimal_position = exponent + 1 in
        if decimal_position <= 0 then
          "0." ^ String.make (-decimal_position) '0' ^ digits
        else if decimal_position >= String.length digits then
          digits ^ String.make (decimal_position - String.length digits) '0' ^ ".0"
        else
          String.sub digits 0 decimal_position ^ "."
          ^ String.sub digits decimal_position (String.length digits - decimal_position)
      else
        let mantissa_text =
          if String.length digits = 1 then digits
          else String.sub digits 0 1 ^ "." ^ String.sub digits 1 (String.length digits - 1)
        in
        let exponent_text =
          if exponent >= 0 then Printf.sprintf "+%02d" exponent
          else Printf.sprintf "-%02d" (-exponent)
        in
        mantissa_text ^ "e" ^ exponent_text
    in
    if negative then "-" ^ unsigned else unsigned

let add_json_string buffer value =
  Buffer.add_string buffer (Yojson.Safe.to_string ~std:true (`String value))

let rec add_canonical_json buffer = function
  | `Null -> Buffer.add_string buffer "null"
  | `Bool true -> Buffer.add_string buffer "true"
  | `Bool false -> Buffer.add_string buffer "false"
  | `Int value -> Buffer.add_string buffer (string_of_int value)
  | `Intlit value -> Buffer.add_string buffer value
  | `Float value -> Buffer.add_string buffer (python_float_to_string value)
  | `String value -> add_json_string buffer value
  | `List values ->
      Buffer.add_char buffer '[';
      List.iteri
        (fun index value ->
          if index > 0 then Buffer.add_char buffer ',';
          add_canonical_json buffer value)
        values;
      Buffer.add_char buffer ']'
  | `Assoc fields ->
      Buffer.add_char buffer '{';
      fields
      |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      |> List.iteri (fun index (key, value) ->
             if index > 0 then Buffer.add_char buffer ',';
             add_json_string buffer key;
             Buffer.add_char buffer ':';
             add_canonical_json buffer value);
      Buffer.add_char buffer '}'
  | `Tuple _ | `Variant _ -> invalid_arg "canonical_json: non-JSON value"

let canonical_json value =
  validate_json ~root:"value" value;
  let buffer = Buffer.create 256 in
  add_canonical_json buffer value;
  Buffer.contents buffer

let sha256_string value =
  Digestif.SHA256.(to_hex (digest_string value))

let content_hash value = sha256_string (canonical_json value)

let hash_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let buffer = Bytes.create (1024 * 1024) in
      let rec loop context =
        let count = input channel buffer 0 (Bytes.length buffer) in
        if count = 0 then context
        else loop (Digestif.SHA256.feed_bytes context ~off:0 ~len:count buffer)
      in
      Digestif.SHA256.(to_hex (get (loop empty))))
