(* The agent-environment boundary. Every action an agent program takes on
   the world is declared here as an algebraic effect and interpreted by the
   handler stack (capture -> policy -> world; see stack.ml). Nothing in an
   agent program touches Unix/filesystem/git directly. *)

type exec_req = {
  argv : string list; (* never routed through a shell unless argv says so *)
  cwd : string;
  timeout_s : int;
  log_hint : string; (* basename hint for the tee'd full-output log *)
  env_extra : (string * string) list;
}

type exec_result = {
  exit_code : int;
  output : string; (* combined stdout+stderr; journal may truncate, log_path never *)
  log_path : string;
  duration_ms : int;
}

type write_req = { path : string; content : string }

type commit_req = {
  repo : string;
  message : string;
  paths : string list; (* pathspec-only commits: exactly these paths *)
}

type commit_result = { sha : string }

(* A model JUDGMENT, as an effect. The program asks yes/no questions about a
   JSON state and receives one probability per question — never generated
   text. Because it is an effect it is journaled, policy-checked and answered
   from the journal on replay like every other contact with the world: a
   probabilistic service never makes a recorded run non-reproducible. *)
type noul_question = {
  qid : string; (* the caller's key for this answer; not shown to the model *)
  instructions : string;
  yes : string; (* what a "yes" means *)
  no : string; (* what a "no" means *)
}

type judge_req = {
  model : string;
  state : Yojson.Safe.t;
  questions : noul_question list;
}

type judge_result = {
  probabilities : (string * float) list; (* qid -> P(yes), in question order *)
  model_used : string;
  input_tokens : int;
  output_tokens : int;
}

type _ Effect.t +=
  | Tool_exec : exec_req -> exec_result Effect.t
  | File_read : string -> string Effect.t
  | File_exists : string -> bool Effect.t
  | File_write : write_req -> unit Effect.t
  | Git_commit : commit_req -> commit_result Effect.t
  | Judge : judge_req -> judge_result Effect.t
  | Note : (string * Yojson.Safe.t) -> unit Effect.t

exception Policy_denied of { effect_kind : string; reason : string }

(* Canonical request encodings — the SINGLE source both the capture handler
   (recording) and the replay handler (matching) use; sharing them is what
   makes byte-for-byte replay comparison sound. *)

let file_read_req_json path : Yojson.Safe.t = `Assoc [ ("path", `String path) ]
let file_exists_req_json path : Yojson.Safe.t = `Assoc [ ("path", `String path) ]

let file_write_req_json (r : write_req) : Yojson.Safe.t =
  `Assoc
    [
      ("path", `String r.path);
      ("bytes", `Int (String.length r.content));
      ("md5", `String (Digest.to_hex (Digest.string r.content)));
    ]

let git_commit_req_json (r : commit_req) : Yojson.Safe.t =
  `Assoc
    [
      ("repo", `String r.repo);
      ("message", `String r.message);
      ("paths", `List (List.map (fun p -> `String p) r.paths));
    ]

let exec_req_json (r : exec_req) : Yojson.Safe.t =
  `Assoc
    [
      ("argv", `List (List.map (fun a -> `String a) r.argv));
      ("cwd", `String r.cwd);
      ("timeout_s", `Int r.timeout_s);
      ("env_extra", `List (List.map (fun (k, _) -> `String k) r.env_extra));
    ]

let exec_result_json ~(cap : int) (r : exec_result) : Yojson.Safe.t =
  let truncated = String.length r.output > cap in
  let shown = if truncated then String.sub r.output 0 cap else r.output in
  `Assoc
    [
      ("exit_code", `Int r.exit_code);
      ("output", `String shown);
      ("output_truncated", `Bool truncated);
      ("log_path", `String r.log_path);
      ("duration_ms", `Int r.duration_ms);
    ]

let judge_req_json (r : judge_req) : Yojson.Safe.t =
  `Assoc
    [
      ("model", `String r.model);
      ("state", r.state);
      ( "questions",
        `List
          (List.map
             (fun q ->
               `Assoc
                 [
                   ("qid", `String q.qid);
                   ("instructions", `String q.instructions);
                   ("yes", `String q.yes);
                   ("no", `String q.no);
                 ])
             r.questions) );
    ]

let judge_result_json (r : judge_result) : Yojson.Safe.t =
  `Assoc
    [
      ( "probabilities",
        `Assoc (List.map (fun (qid, p) -> (qid, `Float p)) r.probabilities) );
      ("model_used", `String r.model_used);
      ("input_tokens", `Int r.input_tokens);
      ("output_tokens", `Int r.output_tokens);
    ]

let judge_result_of_json (d : Yojson.Safe.t) : judge_result =
  let open Yojson.Safe.Util in
  let number = function
    | `Float f -> f
    | `Int i -> float_of_int i
    | _ -> 0.0
  in
  let int_of = function `Int i -> i | _ -> 0 in
  {
    probabilities =
      (match member "probabilities" d with
      | `Assoc kv -> List.map (fun (qid, p) -> (qid, number p)) kv
      | _ -> []);
    model_used = (match member "model_used" d with `String s -> s | _ -> "");
    input_tokens = int_of (member "input_tokens" d);
    output_tokens = int_of (member "output_tokens" d);
  }
