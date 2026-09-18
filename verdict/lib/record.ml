open Json_util

let schema_version = "1"

type tool_call = {
  name : string;
  arguments : Yojson.Safe.t;
  result : Yojson.Safe.t;
  status : string;
  duration_ms : int;
}

type result = { terminal : bool; action : string option; reply : string option }
type usage = { input : int; cached : int; output : int }

type t = {
  key : string;
  scenario_id : string;
  family : string;
  rep : int;
  variant : string;
  model : string;
  base_url : string;
  prompt_hash : string;
  system_prompt : string;
  history : Yojson.Safe.t list;
  tool_calls : tool_call list;
  result : result;
  usage : usage;
  nudges : int;
  seed : int;
  wall_ms : int;
  finished_at : string;
  manifest_ref : string;
}

let option_string path = function
  | `Null -> None
  | value -> Some (require_string ~nonempty:false path value)

let tool_call_of_json value =
  let fields = require_object "tool_call" value in
  require_exact_keys
    ~required:[ "name"; "arguments"; "result"; "status"; "duration_ms" ]
    "tool_call" fields;
  {
    name = require_string "tool_call.name" (required_member "tool_call" fields "name");
    arguments = required_member "tool_call" fields "arguments";
    result = required_member "tool_call" fields "result";
    status = require_string "tool_call.status" (required_member "tool_call" fields "status");
    duration_ms =
      require_int "tool_call.duration_ms" (required_member "tool_call" fields "duration_ms");
  }

let result_of_json value =
  let fields = require_object "result" value in
  require_exact_keys ~required:[ "terminal"; "action"; "reply" ] "result" fields;
  {
    terminal = require_bool "result.terminal" (required_member "result" fields "terminal");
    action = option_string "result.action" (required_member "result" fields "action");
    reply = option_string "result.reply" (required_member "result" fields "reply");
  }

let usage_of_json value =
  let fields = require_object "usage" value in
  require_exact_keys ~required:[ "input"; "cached"; "output" ] "usage" fields;
  let input = require_int "usage.input" (required_member "usage" fields "input") in
  let cached = require_int "usage.cached" (required_member "usage" fields "cached") in
  let output = require_int "usage.output" (required_member "usage" fields "output") in
  if cached > input then fail "usage.cached" "must not exceed usage.input";
  { input; cached; output }

let history_of_json value =
  require_array "record.history" value
  |> List.mapi (fun index message ->
         ignore (require_object (Printf.sprintf "record.history[%d]" index) message);
         message)

let tool_calls_of_json value =
  require_array "record.tool_calls" value |> List.map tool_call_of_json

let required_fields =
  [
    "key";
    "scenario_id";
    "family";
    "rep";
    "variant";
    "model";
    "base_url";
    "prompt_hash";
    "system_prompt";
    "history";
    "tool_calls";
    "result";
    "usage";
    "nudges";
    "seed";
    "wall_ms";
    "finished_at";
    "manifest_ref";
  ]

let of_yojson value =
  validate_json ~root:"record" value;
  let fields = require_object "record" value in
  require_exact_keys ~required:required_fields ~optional:[ "schema_version" ] "record" fields;
  let version =
    match member fields "schema_version" with
    | None -> schema_version
    | Some value -> require_string "record.schema_version" value
  in
  if version <> schema_version then
    fail "record.schema_version"
      (Printf.sprintf "unsupported version %S; expected %S" version schema_version);
  {
    key = require_string "record.key" (required_member "record" fields "key");
    scenario_id =
      require_string "record.scenario_id" (required_member "record" fields "scenario_id");
    family = require_string "record.family" (required_member "record" fields "family");
    rep = require_int "record.rep" (required_member "record" fields "rep");
    variant = require_string "record.variant" (required_member "record" fields "variant");
    model = require_string "record.model" (required_member "record" fields "model");
    base_url =
      require_string ~nonempty:false "record.base_url" (required_member "record" fields "base_url");
    prompt_hash =
      require_sha256 "record.prompt_hash" (required_member "record" fields "prompt_hash");
    system_prompt =
      require_string ~nonempty:false "record.system_prompt"
        (required_member "record" fields "system_prompt");
    history = history_of_json (required_member "record" fields "history");
    tool_calls = tool_calls_of_json (required_member "record" fields "tool_calls");
    result = result_of_json (required_member "record" fields "result");
    usage = usage_of_json (required_member "record" fields "usage");
    nudges = require_int "record.nudges" (required_member "record" fields "nudges");
    seed = require_int "record.seed" (required_member "record" fields "seed");
    wall_ms = require_int "record.wall_ms" (required_member "record" fields "wall_ms");
    finished_at =
      require_datetime "record.finished_at" (required_member "record" fields "finished_at");
    manifest_ref =
      require_string "record.manifest_ref" (required_member "record" fields "manifest_ref");
  }

let of_string payload = parse_string ~path:"record" payload |> of_yojson
let of_file path = read_file path |> of_string

let tool_call_to_yojson call =
  `Assoc
    [
      ("name", `String call.name);
      ("arguments", call.arguments);
      ("result", call.result);
      ("status", `String call.status);
      ("duration_ms", `Int call.duration_ms);
    ]

let option_to_yojson = function None -> `Null | Some value -> `String value

let result_to_yojson value =
  `Assoc
    [
      ("terminal", `Bool value.terminal);
      ("action", option_to_yojson value.action);
      ("reply", option_to_yojson value.reply);
    ]

let usage_to_yojson value =
  `Assoc [ ("input", `Int value.input); ("cached", `Int value.cached); ("output", `Int value.output) ]

let to_yojson value =
  `Assoc
    [
      ("schema_version", `String schema_version);
      ("key", `String value.key);
      ("scenario_id", `String value.scenario_id);
      ("family", `String value.family);
      ("rep", `Int value.rep);
      ("variant", `String value.variant);
      ("model", `String value.model);
      ("base_url", `String value.base_url);
      ("prompt_hash", `String value.prompt_hash);
      ("system_prompt", `String value.system_prompt);
      ("history", `List value.history);
      ("tool_calls", `List (List.map tool_call_to_yojson value.tool_calls));
      ("result", result_to_yojson value.result);
      ("usage", usage_to_yojson value.usage);
      ("nudges", `Int value.nudges);
      ("seed", `Int value.seed);
      ("wall_ms", `Int value.wall_ms);
      ("finished_at", `String value.finished_at);
      ("manifest_ref", `String value.manifest_ref);
    ]

let to_string value = canonical_json (to_yojson value)
let content_hash value = content_hash (to_yojson value)

let validate_jsonl path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let rec loop line_number count =
        match input_line channel with
        | line ->
            if String.trim line = "" then loop (line_number + 1) count
            else (
              (try ignore (of_string line) with
              | Schema_error message ->
                  raise (Schema_error (Printf.sprintf "%s:%d: %s" path line_number message)));
              loop (line_number + 1) (count + 1))
        | exception End_of_file -> count
      in
      let count = loop 1 0 in
      if count = 0 then raise (Schema_error ("record JSONL is empty: " ^ path));
      count)

let read_jsonl path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () ->
      let rec loop line_number records =
        match input_line channel with
        | line ->
            if String.trim line = "" then loop (line_number + 1) records
            else
              let record =
                try of_string line with
                | Schema_error message ->
                    raise
                      (Schema_error
                         (Printf.sprintf "%s:%d: %s" path line_number message))
              in
              loop (line_number + 1) (record :: records)
        | exception End_of_file -> List.rev records
      in
      let records = loop 1 [] in
      if records = [] then raise (Schema_error ("record JSONL is empty: " ^ path));
      records)
