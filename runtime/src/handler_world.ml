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
          | Effects.Note _ ->
              (* Notes are journal-only; the world ignores them. *)
              Some (fun (k : (b, _) continuation) -> continue k ())
          | _ -> None);
    }
