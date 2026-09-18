(* harness CLI: run | status | journal. *)

open Harness_lib
open Cmdliner

let repo_arg =
  Arg.(
    required
    & opt (some dir) None
    & info [ "repo" ] ~docv:"DIR" ~doc:"Target repository root.")

let work_dir_arg =
  Arg.(
    value
    & opt (some string) None
    & info [ "work-dir" ]
        ~doc:"State/journal/logs dir (default <repo>/.harness).")

let runner_arg =
  Arg.(
    value & opt string "kimi"
    & info [ "runner" ] ~doc:"Agent runtime: kimi | codex | cmd:<shell>.")

let checks_arg =
  Arg.(
    value & opt_all string []
    & info [ "check" ]
        ~doc:"Run-level check command (repeatable), run after acceptance.")

let timeout_arg =
  Arg.(value & opt int 1800 & info [ "timeout" ] ~doc:"Per-command timeout, seconds.")

let resume_arg =
  Arg.(value & opt (some string) None & info [ "resume" ] ~doc:"Resume a prior run id.")

let run_id_arg =
  Arg.(value & opt (some string) None & info [ "run-id" ] ~doc:"Explicit run id.")

let dry_run_arg =
  Arg.(value & flag & info [ "dry-run" ] ~doc:"Print plan and first prompt; spend nothing.")

let recall_judge_arg =
  let parse s =
    match Recall.judge_of_string s with Ok j -> Ok j | Error e -> Error (`Msg e)
  in
  let print ppf j = Format.pp_print_string ppf (Recall.judge_to_string j) in
  Arg.(
    value
    & opt (conv (parse, print)) Recall.Substring
    & info [ "recall-judge" ] ~docv:"JUDGE"
        ~doc:
          "How substring-matched lessons are narrowed before injection: \
           $(b,substring) (default) or $(b,jev[:THRESHOLD]) for a journaled \
           relevance judgment per lesson. Replay needs the same value.")

let tasks_arg =
  Arg.(non_empty & pos_all file [] & info [] ~docv:"TASK.md" ~doc:"Task spec files.")

let work_dir_of repo = function
  | Some w -> w
  | None -> Filename.concat repo ".harness"

let run_cmd =
  let action repo work_dir runner checks timeout resume run_id dry_run
      recall_judge tasks =
    match Runners.of_string runner with
    | Error e ->
        prerr_endline e;
        1
    | Ok runner ->
        Fleet.run
          {
            Fleet.repo_root = repo;
            work_dir = work_dir_of repo work_dir;
            runner;
            checks;
            timeout_s = timeout;
            dry_run;
            lesson_mode = Recall.Normal;
            recall_judge;
            lessons_root = repo;
          }
          ~resume ~run_id ~task_paths:tasks
  in
  Cmd.v (Cmd.info "run" ~doc:"Dispatch task specs to agents.")
    Term.(
      const action $ repo_arg $ work_dir_arg $ runner_arg $ checks_arg
      $ timeout_arg $ resume_arg $ run_id_arg $ dry_run_arg $ recall_judge_arg
      $ tasks_arg)

let replay_cmd =
  let action repo work_dir runner checks timeout recall_judge run_id tasks =
    match Runners.of_string runner with
    | Error e ->
        prerr_endline e;
        1
    | Ok runner ->
        Fleet.run_replay
          {
            Fleet.repo_root = repo;
            work_dir = work_dir_of repo work_dir;
            runner;
            checks;
            timeout_s = timeout;
            dry_run = false;
            lesson_mode = Recall.Normal;
            recall_judge;
            lessons_root = repo;
          }
          ~run_id ~task_paths:tasks
  in
  let run_id_pos =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RUN_ID")
  in
  let tasks_pos =
    Arg.(non_empty & pos_right 0 file [] & info [] ~docv:"TASK.md")
  in
  Cmd.v
    (Cmd.info "replay"
       ~doc:
         "Replay a recorded run against today's code with the world \
          disconnected; report OK or the exact divergence.")
    Term.(
      const action $ repo_arg $ work_dir_arg $ runner_arg $ checks_arg
      $ timeout_arg $ recall_judge_arg $ run_id_pos $ tasks_pos)

let status_cmd =
  let action repo work_dir run_id =
    let st =
      Run_state.load ~work_dir:(work_dir_of repo work_dir) ~run_id
    in
    List.iter
      (fun (task_id, entry) ->
        let get k =
          match entry with
          | `Assoc fields -> List.assoc_opt k fields
          | _ -> None
        in
        let status =
          match get "status" with Some (`String s) -> s | _ -> "?"
        in
        let attempts = match get "attempts" with Some (`Int n) -> n | _ -> 0 in
        Printf.printf "%s: %s (attempts=%d)\n" task_id status attempts)
      (Run_state.tasks st);
    0
  in
  let run_id_pos =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RUN_ID")
  in
  Cmd.v (Cmd.info "status" ~doc:"Show a run's task states.")
    Term.(const action $ repo_arg $ work_dir_arg $ run_id_pos)

let journal_cmd =
  let action repo work_dir run_id =
    let path =
      Filename.concat
        (Filename.concat (work_dir_of repo work_dir) "journal")
        (run_id ^ ".jsonl")
    in
    List.iter
      (fun line -> print_endline (Yojson.Safe.pretty_to_string line))
      (Journal.read_lines path);
    0
  in
  let run_id_pos =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RUN_ID")
  in
  Cmd.v (Cmd.info "journal" ~doc:"Pretty-print a run's effect journal.")
    Term.(const action $ repo_arg $ work_dir_arg $ run_id_pos)

let distill_cmd =
  let action repo work_dir runner timeout llm run_id =
    let llm_runner =
      if not llm then None
      else
        match Runners.of_string runner with
        | Ok r -> Some r
        | Error e ->
            prerr_endline e;
            None
    in
    Distill.run ~repo_root:repo ~work_dir:(work_dir_of repo work_dir) ~run_id
      ~llm_runner ~timeout_s:timeout
  in
  let llm_flag =
    Arg.(value & flag & info [ "llm" ] ~doc:"Also run the LLM distillation lane via --runner.")
  in
  let run_id_pos =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RUN_ID")
  in
  Cmd.v
    (Cmd.info "distill"
       ~doc:
         "Distill a run's journal into candidate lessons (written on \
          probation under lessons/).")
    Term.(
      const action $ repo_arg $ work_dir_arg $ runner_arg $ timeout_arg
      $ llm_flag $ run_id_pos)

let lessons_cmd =
  let action repo =
    (* Listing is read-only introspection; run it on a throwaway stack so
       lesson reads stay effect-mediated. *)
    let dir = Filename.concat repo ".harness" in
    let journal = Journal.open_journal ~dir:(Filename.temp_dir "harness" "lessons") ~run_id:"list" in
    let world = { Handler_world.logs_dir = Filename.temp_dir "harness" "lessons-logs" } in
    let policy = { Policy.repo_root = repo; write_roots = [ dir ]; commit_paths = [] } in
    let code =
      Stack.run ~world ~policy ~journal (fun () ->
          let lessons, errors = Lesson.load_all ~repo_root:repo in
          List.iter
            (fun (l : Lesson.t) ->
              Printf.printf "%-12s %-30s matchers=[%s] origin=%s\n"
                (Lesson.status_to_string l.status)
                l.id
                (String.concat ", " l.matchers)
                l.origin_run)
            lessons;
          List.iter (fun e -> Printf.eprintf "parse error: %s\n" e) errors;
          if lessons = [] then print_endline "no lessons yet";
          0)
    in
    Journal.close journal;
    code
  in
  Cmd.v (Cmd.info "lessons" ~doc:"List the lesson corpus and statuses.")
    Term.(const action $ repo_arg)

let gate_cmd =
  let action repo work_dir runner checks timeout k lesson_id evals =
    match Runners.of_string runner with
    | Error e ->
        prerr_endline e;
        1
    | Ok runner ->
        Scorecard.gate
          ~base:
            {
              Fleet.repo_root = repo;
              work_dir = work_dir_of repo work_dir;
              runner;
              checks;
              timeout_s = timeout;
              dry_run = false;
              lesson_mode = Recall.Normal;
            recall_judge = Recall.Substring;
              lessons_root = repo;
            }
          ~lesson_id ~eval_paths:evals ~k
  in
  let k_arg =
    Arg.(value & opt int 1 & info [ "k" ] ~doc:"Reps per eval task per arm.")
  in
  let lesson_pos =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"LESSON_ID")
  in
  let evals_pos =
    Arg.(non_empty & pos_right 0 file [] & info [] ~docv:"EVAL.md")
  in
  Cmd.v
    (Cmd.info "gate"
       ~doc:
         "Measure a probation lesson on eval tasks (baseline vs forced) and \
          promote/retire it on the evidence; appends SCORECARD.json.")
    Term.(
      const action $ repo_arg $ work_dir_arg $ runner_arg $ checks_arg
      $ timeout_arg $ k_arg $ lesson_pos $ evals_pos)

let () =
  exit
    (Cmd.eval'
       (Cmd.group
          (Cmd.info "harness" ~version:"0.1.0"
             ~doc:
               "Self-learning agentic harness: agent actions are algebraic \
                effects; the harness is the handler stack.")
          [
            run_cmd; replay_cmd; status_cmd; journal_cmd; distill_cmd;
            lessons_cmd; gate_cmd;
          ]))
