(* The outermost handler: the only code in the system that actually touches
   the world. Everything here is reached exclusively via effects that have
   already passed capture (journaled) and policy (checked). *)

open Effect.Deep

type config = { logs_dir : string }

let rec ensure_dir dir =
  if not (Sys.file_exists dir) then (
    ensure_dir (Filename.dirname dir);
    try Unix.mkdir dir 0o755 with Unix.Unix_error (Unix.EEXIST, _, _) -> ())

let read_file path =
  let ic = open_in_bin path in
  let n = in_channel_length ic in
  let s = really_input_string ic n in
  close_in ic;
  s

let write_file path content =
  let dir = Filename.dirname path in
  ensure_dir dir;
  let tmp = path ^ ".tmp" in
  let oc = open_out_bin tmp in
  output_string oc content;
  close_out oc;
  Sys.rename tmp path

(* Run argv (no shell), teeing combined stdout+stderr to a log file, with a
   hard timeout (SIGKILL). Returns the combined output and timing. *)
let exec (cfg : config) (req : Effects.exec_req) : Effects.exec_result =
  ensure_dir cfg.logs_dir;
  let stamp = Unix.gettimeofday () in
  let log_path =
    Filename.concat cfg.logs_dir
      (Printf.sprintf "%s.%d.log" req.log_hint (int_of_float (stamp *. 1000.)))
  in
  let log = open_out_gen [ Open_append; Open_creat ] 0o644 log_path in
  output_string log (Printf.sprintf "$ %s\n" (String.concat " " req.argv));
  flush log;
  let r_fd, w_fd = Unix.pipe ~cloexec:false () in
  let env =
    Array.append (Unix.environment ())
      (Array.of_list
         (List.map (fun (k, v) -> k ^ "=" ^ v) req.env_extra))
  in
  let pid =
    let saved_cwd = Sys.getcwd () in
    Sys.chdir req.cwd;
    Fun.protect
      ~finally:(fun () -> Sys.chdir saved_cwd)
      (fun () ->
        Unix.create_process_env (List.hd req.argv) (Array.of_list req.argv) env
          Unix.stdin w_fd w_fd)
  in
  Unix.close w_fd;
  let deadline = stamp +. Float.of_int req.timeout_s in
  let buf = Buffer.create 4096 in
  let chunk = Bytes.create 65536 in
  let timed_out = ref false in
  let rec pump () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0. then (
      timed_out := true;
      (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ()))
    else
      match Unix.select [ r_fd ] [] [] (Float.min remaining 1.0) with
      | [], _, _ -> pump ()
      | _ -> (
          match Unix.read r_fd chunk 0 (Bytes.length chunk) with
          | 0 -> () (* EOF *)
          | n ->
              let s = Bytes.sub_string chunk 0 n in
              Buffer.add_string buf s;
              output_string log s;
              flush log;
              pump ())
  in
  pump ();
  Unix.close r_fd;
  let _, status = Unix.waitpid [] pid in
  let exit_code =
    if !timed_out then 124
    else
      match status with
      | Unix.WEXITED c -> c
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 137
  in
  if !timed_out then (
    let msg = Printf.sprintf "\n[TIMEOUT after %ds]" req.timeout_s in
    Buffer.add_string buf msg;
    output_string log msg);
  output_string log (Printf.sprintf "\n[exit %d]\n" exit_code);
  close_out log;
  {
    Effects.exit_code;
    output = Buffer.contents buf;
    log_path;
    duration_ms = int_of_float ((Unix.gettimeofday () -. stamp) *. 1000.);
  }

let git_commit (cfg : config) (req : Effects.commit_req) : Effects.commit_result
    =
  let run argv hint =
    exec cfg { argv; cwd = req.repo; timeout_s = 60; log_hint = hint; env_extra = [] }
  in
  let add = run ([ "git"; "add"; "--" ] @ req.paths) "git-add" in
  if add.exit_code <> 0 then
    failwith (Printf.sprintf "git add failed (exit %d): %s" add.exit_code add.output);
  let commit =
    run ([ "git"; "commit"; "-m"; req.message; "--" ] @ req.paths) "git-commit"
  in
  if commit.exit_code <> 0 then
    failwith
      (Printf.sprintf "git commit failed (exit %d): %s" commit.exit_code
         commit.output);
  let sha = run [ "git"; "rev-parse"; "HEAD" ] "git-rev-parse" in
  { Effects.sha = String.trim sha.output }

(* Run argv with [stdin_text] on stdin; return (exit code, stdout). Used for
   the judge transport, which must not put a credential in argv (visible in
   the process table) or in a log file. *)
let run_with_stdin ~(argv : string list) ~(stdin_text : string)
    ~(timeout_s : int) : int * string =
  let in_r, in_w = Unix.pipe ~cloexec:true () in
  let out_r, out_w = Unix.pipe ~cloexec:true () in
  let pid =
    Unix.create_process (List.hd argv) (Array.of_list argv) in_r out_w
      Unix.stderr
  in
  Unix.close in_r;
  Unix.close out_w;
  let oc = Unix.out_channel_of_descr in_w in
  (try output_string oc stdin_text with Sys_error _ -> ());
  (try close_out oc with Sys_error _ -> ());
  let deadline = Unix.gettimeofday () +. Float.of_int timeout_s in
  let buf = Buffer.create 4096 in
  let chunk = Bytes.create 65536 in
  let timed_out = ref false in
  let rec pump () =
    let remaining = deadline -. Unix.gettimeofday () in
    if remaining <= 0.0 then timed_out := true
    else
      match Unix.select [ out_r ] [] [] remaining with
      | [], _, _ -> timed_out := true
      | _ -> (
          match Unix.read out_r chunk 0 (Bytes.length chunk) with
          | 0 -> ()
          | n ->
              Buffer.add_subbytes buf chunk 0 n;
              pump ()
          | exception Unix.Unix_error (Unix.EINTR, _, _) -> pump ())
      | exception Unix.Unix_error (Unix.EINTR, _, _) -> pump ()
  in
  pump ();
  Unix.close out_r;
  if !timed_out then (
    (try Unix.kill pid Sys.sigkill with Unix.Unix_error _ -> ());
    ignore (Unix.waitpid [] pid);
    failwith (Printf.sprintf "timed out after %ds" timeout_s))
  else
    let code =
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED c -> c
      | Unix.WSIGNALED _ | Unix.WSTOPPED _ -> 255
    in
    (code, Buffer.contents buf)

let judge_endpoint = "https://api.typesafe.ai/v1/systemone"

let judge_api_key () =
  match Sys.getenv_opt "TYPESAFE_API_KEY" with
  | Some k when String.trim k <> "" -> Some (String.trim k)
  | _ -> (
      match Sys.getenv_opt "HOME" with
      | None -> None
      | Some home ->
          let path = Filename.concat home ".config/typesafe/api_key" in
          if Sys.file_exists path then Some (String.trim (read_file path))
          else None)

let judge_body (req : Effects.judge_req) : Yojson.Safe.t =
  `Assoc
    [
      ("model", `String req.model);
      ("state", req.state);
      ( "questions",
        `Assoc
          (List.map
             (fun (q : Effects.noul_question) ->
               ( q.qid,
                 `Assoc
                   [
                     ("type", `String "noul");
                     ("instructions", `String q.instructions);
                     ( "criteria",
                       `Assoc [ ("true", `String q.yes); ("false", `String q.no) ]
                     );
                   ] ))
             req.questions) );
    ]

(* Parsing is total: whatever the service returns, the outcome is either a
   well-formed result (every question answered with a probability in 0..1) or
   a Failure the caller can fall back on — never an escaping parser error. *)
let judge_result_of_response (req : Effects.judge_req) (text : string) :
    Effects.judge_result =
  let json =
    try Yojson.Safe.from_string text
    with _ -> failwith "judge: response was not JSON"
  in
  let member key = function
    | `Assoc fields -> Option.value ~default:`Null (List.assoc_opt key fields)
    | _ -> `Null
  in
  let answers = member "answers" json in
  let probability (q : Effects.noul_question) =
    let p =
      match member "noul" (member q.qid answers) with
      | `Float f -> f
      | `Int i -> float_of_int i
      | _ -> failwith (Printf.sprintf "judge: no noul answer for %s" q.qid)
    in
    if Float.is_nan p || p < 0.0 || p > 1.0 then
      failwith (Printf.sprintf "judge: probability for %s is outside 0..1" q.qid)
    else (q.qid, p)
  in
  let int_at a b = match member b (member a json) with `Int i -> i | _ -> 0 in
  {
    Effects.probabilities = List.map probability req.questions;
    model_used = (match member "model" json with `String m -> m | _ -> req.model);
    input_tokens = int_at "usage" "input_tokens";
    output_tokens = int_at "usage" "output_tokens";
  }

let judge_timeout_s () =
  match Option.bind (Sys.getenv_opt "HARNESS_JUDGE_TIMEOUT_S") int_of_string_opt with
  | Some t when t > 0 -> t
  | _ -> 30

(* The judge transport. HARNESS_JUDGE_CMD, when set, replaces the network:
   the request body goes to that shell command's stdin and its stdout is the
   response — the same scriptable seam the cmd: runner gives agents, so tests
   and offline runs never need a key. Otherwise: curl, with the bearer token
   passed in a config read from stdin. *)
let judge (req : Effects.judge_req) : Effects.judge_result =
  let body = Yojson.Safe.to_string (judge_body req) in
  match Sys.getenv_opt "HARNESS_JUDGE_CMD" with
  | Some cmd when String.trim cmd <> "" ->
      let code, out =
        run_with_stdin ~argv:[ "sh"; "-c"; cmd ] ~stdin_text:body
          ~timeout_s:(judge_timeout_s ())
      in
      if code <> 0 then failwith (Printf.sprintf "judge command exited %d" code)
      else judge_result_of_response req out
  | _ -> (
      match judge_api_key () with
      | None ->
          failwith
            "judge: no TypeSafe API key (set TYPESAFE_API_KEY or              ~/.config/typesafe/api_key)"
      | Some key ->
          let body_path = Filename.temp_file "harness-judge-" ".json" in
          Fun.protect
            ~finally:(fun () -> try Sys.remove body_path with Sys_error _ -> ())
            (fun () ->
              write_file body_path body;
              let config =
                Printf.sprintf "header = \"Authorization: Bearer %s\"\n" key
              in
              let code, out =
                run_with_stdin
                  ~argv:
                    [
                      "curl"; "-sS"; "--max-time"; string_of_int (judge_timeout_s ()); "-K"; "-"; "-X"; "POST";
                      judge_endpoint; "-H"; "Content-Type: application/json";
                      "--data-binary"; "@" ^ body_path; "-w"; "\n%{http_code}";
                    ]
                  ~stdin_text:config ~timeout_s:(judge_timeout_s () + 5)
              in
              if code <> 0 then failwith (Printf.sprintf "judge: curl exited %d" code);
              let out = String.trim out in
              let status, payload =
                match String.rindex_opt out '\n' with
                | Some i ->
                    ( String.sub out (i + 1) (String.length out - i - 1),
                      String.sub out 0 i )
                | None -> (out, "")
              in
              if status <> "200" then
                failwith (Printf.sprintf "judge: HTTP %s" status)
              else judge_result_of_response req payload))

let run (cfg : config) (fn : unit -> 'a) : 'a =
  match_with fn ()
    {
      retc = Fun.id;
      exnc = raise;
      effc =
        (fun (type b) (eff : b Effect.t) ->
          match eff with
          | Effects.Tool_exec req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match exec cfg req with
                  | res -> continue k res
                  | exception e -> discontinue k e)
          | Effects.File_read path ->
              Some
                (fun (k : (b, _) continuation) ->
                  match read_file path with
                  | s -> continue k s
                  | exception e -> discontinue k e)
          | Effects.File_exists path ->
              Some
                (fun (k : (b, _) continuation) -> continue k (Sys.file_exists path))
          | Effects.File_write { path; content } ->
              Some
                (fun (k : (b, _) continuation) ->
                  match write_file path content with
                  | () -> continue k ()
                  | exception e -> discontinue k e)
          | Effects.Git_commit req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match git_commit cfg req with
                  | res -> continue k res
                  | exception e -> discontinue k e)
          | Effects.Judge req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match judge req with
                  | res -> continue k res
                  | exception (Failure _ as e) -> discontinue k e
                  | exception e ->
                      discontinue k (Failure ("judge: " ^ Printexc.to_string e)))
          | Effects.Note _ ->
              (* Notes are journal-only; the world ignores them. *)
              Some (fun (k : (b, _) continuation) -> continue k ())
          | _ -> None);
    }
