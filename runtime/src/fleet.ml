(* The fleet program — the first agent program running on the effect
   interpreter. Ports an existing Python fleet-dispatch contract: parse specs,
   validate disjoint ownership, dispatch an agent per task, verify with the
   catcher, retry once with failure context, commit passing work with
   pathspec-only commits, park the rest. Sequential in M1; the Eio scheduler
   lands with the parallel lane. *)

let max_attempts = 2
let min_free_bytes = 2 * 1024 * 1024 * 1024

type config = {
  repo_root : string;
  work_dir : string;
  runner : Runners.t;
  checks : string list;
  timeout_s : int;
  dry_run : bool;
  lesson_mode : Recall.mode;
  recall_judge : Recall.judge; (* how substring hits are narrowed *)
  lessons_root : string; (* repo whose lessons/ dir recall reads; usually repo_root, but the gate's eval repos borrow the main corpus *)
}

(* A full disk mid-patch is destructive, not just failing: ENOSPC during a
   patch apply deleted a source file outright (observed in a prior fleet run). *)
let check_disk_headroom root =
  let df =
    Unix.open_process_in
      (Printf.sprintf "df -k %s | tail -1 | awk '{print $4}'"
         (Filename.quote root))
  in
  let free_kb = try int_of_string (String.trim (input_line df)) with _ -> max_int in
  ignore (Unix.close_process_in df);
  if free_kb * 1024 < min_free_bytes then
    Error
      (Printf.sprintf "disk preflight: %d MiB free, need %d MiB"
         (free_kb / 1024)
         (min_free_bytes / 1024 / 1024))
  else Ok ()

let task_policy (cfg : config) (task : Task_spec.t) : Policy.t =
  {
    Policy.repo_root = cfg.repo_root;
    write_roots =
      cfg.work_dir
      :: List.map (fun p -> Filename.concat cfg.repo_root p) task.owns;
    commit_paths = task.owns;
  }

let standing_orders (cfg : config) : string option =
  let path = Filename.concat cfg.repo_root "AGENTS.md" in
  (* Existence goes through the effect system too: if AGENTS.md appears or
     vanishes between record and replay, replay reports the divergence
     instead of silently building a different prompt. *)
  if Effect.perform (Effects.File_exists path) then
    Some (Effect.perform (Effects.File_read path))
  else None

(* One task through up to max_attempts agent->verify cycles. Runs INSIDE the
   handler stack; every action below is a journaled, policy-checked effect. *)
let run_task (cfg : config) (state : Run_state.t) (task : Task_spec.t) : string
    =
  let note label data = Effect.perform (Effects.Note (label, `Assoc data)) in
  (* The launch configuration is part of the trajectory: replaying with a
     different runner/checks/timeout/spec diverges on this very note. *)
  note "task_config"
    [
      ("task", `String task.id);
      ("title", `String task.title);
      ("owns", `List (List.map (fun p -> `String p) task.owns));
      ("acceptance", `String task.acceptance);
      ("runner", `String (Runners.to_string cfg.runner));
      ("checks", `List (List.map (fun c -> `String c) cfg.checks));
      ("timeout_s", `Int cfg.timeout_s);
      ("repo_root", `String cfg.repo_root);
    ];
  (* M3 recall: the corpus consulted once per task, before the first
     attempt; the selection is journaled (Recall emits a "recall" note). *)
  let lessons =
    List.map
      (fun (l : Lesson.t) -> l.guidance)
      (Recall.for_task ~judge:cfg.recall_judge ~repo_root:cfg.lessons_root
         ~task
         ~runner:(Runners.to_string cfg.runner)
         ~mode:cfg.lesson_mode ())
  in
  let rec attempt failure_context =
    if Run_state.attempts_of state task.id >= max_attempts then (
      Run_state.transition state task.id ~status:"parked"
        ~extra:
          [ ("error", `String (Option.value ~default:"" failure_context)) ]
        ();
      note "task_parked" [ ("task", `String task.id) ];
      "parked")
    else (
      let n = Run_state.bump_attempts state task.id in
      Run_state.transition state task.id ~status:"running" ();
      note "attempt_start"
        [ ("task", `String task.id); ("attempt", `Int n) ];
      let prompt =
        Prompt.build ~task ~checks:cfg.checks
          ~standing_orders:(standing_orders cfg)
          ~lessons ~failure_context
      in
      let res =
        Effect.perform
          (Effects.Tool_exec
             (Runners.exec_req cfg.runner ~prompt ~repo_root:cfg.repo_root
                ~timeout_s:cfg.timeout_s
                ~log_hint:(Printf.sprintf "%s.attempt%d" task.id n)))
      in
      if res.exit_code <> 0 then (
        Run_state.transition state task.id ~status:"agent_failed" ();
        attempt
          (Some
             (Printf.sprintf "agent exited %d\n%s" res.exit_code
                (let cap = 3000 in
                 let o = res.output in
                 if String.length o > cap then
                   String.sub o (String.length o - cap) cap
                 else o))))
      else
        match
          Catcher.verify ~task ~repo_root:cfg.repo_root ~checks:cfg.checks
            ~timeout_s:cfg.timeout_s
        with
        | Error failure ->
            Run_state.transition state task.id ~status:"verify_failed" ();
            attempt (Some failure)
        | Ok () -> (
            let title =
              let prefix = task.commit_type ^ ": " in
              if String.starts_with ~prefix task.title then
                String.sub task.title (String.length prefix)
                  (String.length task.title - String.length prefix)
              else task.title
            in
            match
              Effect.perform
                (Effects.Git_commit
                   {
                     repo = cfg.repo_root;
                     message =
                       Printf.sprintf "%s: %s (harness %s)" task.commit_type
                         title task.id;
                     paths = task.owns;
                   })
            with
            | { sha } ->
                Run_state.transition state task.id ~status:"committed"
                  ~extra:[ ("sha", `String sha) ] ();
                "committed"
            | exception e ->
                Run_state.transition state task.id ~status:"commit_failed"
                  ~extra:[ ("error", `String (Printexc.to_string e)) ] ();
                "commit_failed"))
  in
  attempt None

(* M2: replay a recorded run against today's code, world disconnected. The
   same run_task program executes with the replay handler answering every
   effect from the journal; completing with the journal fully consumed
   proves the trajectory is still exactly reproducible. *)
let run_replay (cfg : config) ~(run_id : string) ~(task_paths : string list) :
    int =
  match
    let parsed = List.map Task_spec.parse_file task_paths in
    let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) parsed in
    if errors <> [] then Error (String.concat "\n" errors)
    else Ok (List.filter_map (function Ok t -> Some t | Error _ -> None) parsed)
  with
  | Error e ->
      prerr_endline e;
      1
  | Ok tasks -> (
      let journal_path =
        Filename.concat (Filename.concat cfg.work_dir "journal") (run_id ^ ".jsonl")
      in
      if not (Sys.file_exists journal_path) then (
        Printf.eprintf "no journal at %s\n" journal_path;
        1)
      else
        let cursor = Handler_replay.of_journal_file journal_path in
        let total =
          List.length cursor.Handler_replay.remaining
        in
        let state = Run_state.create_ephemeral ~run_id:(run_id ^ "-replay") in
        match
          List.map
            (fun (task : Task_spec.t) ->
              let outcome =
                Handler_replay.run cursor (fun () -> run_task cfg state task)
              in
              Printf.printf "[%13s] %s %s (replayed)\n%!" outcome task.id
                task.title;
              outcome)
            tasks
        with
        | _ when Handler_replay.fully_consumed cursor ->
            Printf.printf "REPLAYED OK: %d journal entries matched, world disconnected\n%!"
              total;
            0
        | _ ->
            Printf.printf
              "REPLAY INCOMPLETE: %d journal entries left unconsumed after \
               the last task\n%!"
              (List.length cursor.Handler_replay.remaining);
            1
        | exception Handler_replay.Divergence { seq; expected; got } ->
            Printf.printf
              "REPLAY DIVERGENCE at journal seq %d:\n  recorded:  %s\n  \
               performed: %s\n%!"
              seq expected got;
            1
        | exception Handler_replay.Unreplayable { seq; reason } ->
            Printf.printf "UNREPLAYABLE at journal seq %d: %s\n%!" seq reason;
            1)

let select_tasks task_paths : (Task_spec.t list, string) result =
  if task_paths = [] then Error "no task files given"
  else
    let parsed = List.map Task_spec.parse_file task_paths in
    let errors =
      List.filter_map (function Error e -> Some e | Ok _ -> None) parsed
    in
    if errors <> [] then Error (String.concat "\n" errors)
    else
      let tasks =
        List.filter_map (function Ok t -> Some t | Error _ -> None) parsed
      in
      match Ownership.check_disjoint tasks with
      | Ok () -> Ok tasks
      | Error e -> Error e

let run (cfg : config) ~(resume : string option) ~(run_id : string option)
    ~(task_paths : string list) : int =
  match check_disk_headroom cfg.repo_root with
  | Error e ->
      prerr_endline e;
      1
  | Ok () -> (
      match select_tasks task_paths with
      | Error e ->
          prerr_endline e;
          1
      | Ok all_tasks -> (
          if not (Sys.file_exists cfg.work_dir) then Unix.mkdir cfg.work_dir 0o755;
          let state, tasks =
            match resume with
            | Some rid ->
                let st = Run_state.load ~work_dir:cfg.work_dir ~run_id:rid in
                let remaining =
                  List.filter
                    (fun (t : Task_spec.t) ->
                      Run_state.status_of st t.id <> "committed")
                    all_tasks
                in
                Printf.printf "resuming %s: %d tasks remaining\n%!" rid
                  (List.length remaining);
                (st, remaining)
            | None ->
                let rid =
                  match run_id with
                  | Some r -> r
                  | None ->
                      let tm = Unix.gmtime (Unix.gettimeofday ()) in
                      Printf.sprintf "run-%04d%02d%02d-%02d%02d%02d"
                        (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
                        tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
                        tm.Unix.tm_sec
                in
                (Run_state.create ~work_dir:cfg.work_dir ~run_id:rid, all_tasks)
          in
          Printf.printf "run %s: %d tasks, runner=%s\n%!" state.run_id
            (List.length tasks)
            (Runners.to_string cfg.runner);
          List.iter
            (fun (t : Task_spec.t) ->
              Printf.printf "  %s: %s  owns=[%s]\n%!" t.id t.title
                (String.concat "; " t.owns))
            tasks;
          if cfg.dry_run then (
            match tasks with
            | first :: _ ->
                print_endline "\n--dry-run: first prompt would be:\n";
                print_endline
                  (Prompt.build ~task:first ~checks:cfg.checks
                     ~standing_orders:None ~lessons:[] ~failure_context:None);
                0
            | [] -> 0)
          else
            match Runners.preflight cfg.runner with
            | Error e ->
                prerr_endline e;
                1
            | Ok () ->
                Run_state.persist state;
                let journal =
                  Journal.open_journal
                    ~dir:(Filename.concat cfg.work_dir "journal")
                    ~run_id:state.run_id
                in
                let world =
                  {
                    Handler_world.logs_dir =
                      Filename.concat cfg.work_dir
                        (Filename.concat "logs" state.run_id);
                  }
                in
                let results =
                  List.map
                    (fun (task : Task_spec.t) ->
                      let outcome =
                        Stack.run ~world ~policy:(task_policy cfg task)
                          ~journal
                          (fun () -> run_task cfg state task)
                      in
                      Printf.printf "[%13s] %s %s\n%!" outcome task.id
                        task.title;
                      (task.id, outcome))
                    tasks
                in
                Journal.close journal;
                let parked =
                  List.filter (fun (_, r) -> r <> "committed") results
                in
                Printf.printf "\ndone: %d committed, %d need review\n%!"
                  (List.length results - List.length parked)
                  (List.length parked);
                if parked <> [] then (
                  Printf.printf "needs human review: %s\n%!"
                    (String.concat ", " (List.map fst parked));
                  1)
                else 0))
