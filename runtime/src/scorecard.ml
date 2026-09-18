(* M4: the promotion gate. A probation lesson reaches prompts only after
   MEASUREMENT (one scorer, arms compared on the same tasks; tellbench's
   lesson on propensities): the same eval tasks run in fresh throwaway repos under two
   arms — baseline (lessons suppressed) and candidate (the lesson forced) —
   k reps each. Promotion requires task lift AND no tripwire regression; a
   lesson that fires more tripwires than baseline is RETIRED as harmful,
   whatever its task lift. Every arm's run keeps its own journal under the
   eval repo; the verdict is appended to SCORECARD.json in the main repo. *)

type arm_result = {
  committed : int;
  total : int;
  tripwires_fired : int;
  tripwires_measured : int;
}

let rate num den = if den = 0 then 0. else float_of_int num /. float_of_int den

let sh ~cwd cmd =
  (* Gate-level measurement machinery (repo setup, tripwire probes) — not
     agent effects; the agent trajectories inside Fleet.run are journaled
     as always. *)
  Sys.command (Printf.sprintf "cd %s && ( %s ) >/dev/null 2>&1" (Filename.quote cwd) cmd)

let fresh_eval_repo ~gate_dir ~arm ~(task : Task_spec.t) ~rep : string =
  let dir =
    Filename.concat gate_dir (Printf.sprintf "%s/%s-r%d" arm task.id rep)
  in
  let rc =
    sh ~cwd:"/"
      (Printf.sprintf
         "mkdir -p %s && cd %s && git init -q -b main && git config \
          user.email harness@gate && git config user.name harness-gate && \
          git commit -q --allow-empty -m root"
         (Filename.quote dir) (Filename.quote dir))
  in
  if rc <> 0 then failwith (Printf.sprintf "eval repo init failed: %s" dir);
  (match task.setup with
  | Some setup ->
      if sh ~cwd:dir setup <> 0 then
        failwith (Printf.sprintf "eval setup failed in %s: %s" dir setup)
  | None -> ());
  dir

let run_arm ~(base : Fleet.config) ~gate_dir ~arm ~(mode : Recall.mode)
    ~(evals : Task_spec.t list) ~(k : int) : arm_result =
  List.fold_left
    (fun acc (task : Task_spec.t) ->
      List.fold_left
        (fun acc rep ->
          let eval_repo = fresh_eval_repo ~gate_dir ~arm ~task ~rep in
          let cfg =
            {
              base with
              Fleet.repo_root = eval_repo;
              work_dir = Filename.concat eval_repo ".harness";
              lesson_mode = mode;
            }
          in
          let exit_code =
            Fleet.run cfg ~resume:None
              ~run_id:(Some (Printf.sprintf "gate-%s-r%d" arm rep))
              ~task_paths:[ task.path ]
          in
          let committed = if exit_code = 0 then 1 else 0 in
          let fired, measured =
            match task.tripwire with
            | None -> (0, 0)
            | Some probe -> ((if sh ~cwd:eval_repo probe = 0 then 1 else 0), 1)
          in
          {
            committed = acc.committed + committed;
            total = acc.total + 1;
            tripwires_fired = acc.tripwires_fired + fired;
            tripwires_measured = acc.tripwires_measured + measured;
          })
        acc
        (List.init k (fun i -> i + 1)))
    { committed = 0; total = 0; tripwires_fired = 0; tripwires_measured = 0 }
    evals

let arm_json (r : arm_result) : Yojson.Safe.t =
  `Assoc
    [
      ("committed", `Int r.committed);
      ("total", `Int r.total);
      ("tripwires_fired", `Int r.tripwires_fired);
      ("tripwires_measured", `Int r.tripwires_measured);
    ]

let scorecard_path repo_root = Filename.concat repo_root "SCORECARD.json"

let append_entry ~repo_root (entry : Yojson.Safe.t) =
  let path = scorecard_path repo_root in
  let existing =
    if Effect.perform (Effects.File_exists path) then
      match Yojson.Safe.from_string (Effect.perform (Effects.File_read path)) with
      | `List l -> l
      | other -> [ other ]
    else []
  in
  Effect.perform
    (Effects.File_write
       {
         path;
         content = Yojson.Safe.pretty_to_string (`List (existing @ [ entry ])) ^ "\n";
       })

type verdict = Promote | Keep_probation | Retire_harmful

let judge ~(baseline : arm_result) ~(candidate : arm_result) : verdict =
  if rate candidate.tripwires_fired candidate.tripwires_measured
     > rate baseline.tripwires_fired baseline.tripwires_measured
  then Retire_harmful
  else if rate candidate.committed candidate.total > rate baseline.committed baseline.total
  then Promote
  else Keep_probation

let verdict_string = function
  | Promote -> "promoted"
  | Keep_probation -> "probation"
  | Retire_harmful -> "retired-harmful"

let gate ~(base : Fleet.config) ~(lesson_id : string)
    ~(eval_paths : string list) ~(k : int) : int =
  let evals_r = List.map Task_spec.parse_file eval_paths in
  let errors = List.filter_map (function Error e -> Some e | Ok _ -> None) evals_r in
  if errors <> [] then (
    prerr_endline (String.concat "\n" errors);
    1)
  else
    let evals = List.filter_map (function Ok t -> Some t | Error _ -> None) evals_r in
    let gate_dir =
      Filename.concat base.Fleet.work_dir (Filename.concat "gate" lesson_id)
    in
    let baseline =
      run_arm ~base ~gate_dir ~arm:"baseline" ~mode:Recall.Suppress ~evals ~k
    in
    let candidate =
      run_arm ~base ~gate_dir ~arm:"candidate"
        ~mode:(Recall.Force [ lesson_id ]) ~evals ~k
    in
    let verdict = judge ~baseline ~candidate in
    (* Verdict application runs on the effect stack: journaled + revertible. *)
    let journal =
      Journal.open_journal
        ~dir:(Filename.concat base.Fleet.work_dir "journal")
        ~run_id:(Printf.sprintf "gate-%s" lesson_id)
    in
    let world =
      {
        Handler_world.logs_dir =
          Filename.concat base.Fleet.work_dir
            (Filename.concat "logs" (Printf.sprintf "gate-%s" lesson_id));
      }
    in
    let policy =
      {
        Policy.repo_root = base.Fleet.repo_root;
        write_roots =
          [
            Lesson.lessons_dir base.Fleet.lessons_root;
            scorecard_path base.Fleet.repo_root;
            base.Fleet.work_dir;
          ];
        commit_paths = [];
      }
    in
    let result =
      Stack.run ~world ~policy ~journal (fun () ->
          Handler_revert.run (fun () ->
              let lessons, _ = Lesson.load_all ~repo_root:base.Fleet.lessons_root in
              match
                List.find_opt (fun (l : Lesson.t) -> l.id = lesson_id) lessons
              with
              | None ->
                  Printf.eprintf "no lesson with id %s\n" lesson_id;
                  1
              | Some lesson ->
                  let status =
                    match verdict with
                    | Promote -> Lesson.Promoted
                    | Keep_probation -> Lesson.Probation
                    | Retire_harmful -> Lesson.Retired
                  in
                  ignore
                    (Lesson.set_status ~repo_root:base.Fleet.lessons_root lesson
                       status);
                  append_entry ~repo_root:base.Fleet.repo_root
                    (`Assoc
                      [
                        ("ts", `String (Journal.now_iso ()));
                        ("lesson", `String lesson_id);
                        ( "evals",
                          `List
                            (List.map
                               (fun (t : Task_spec.t) -> `String t.id)
                               evals) );
                        ("k", `Int k);
                        ("baseline", arm_json baseline);
                        ("candidate", arm_json candidate);
                        ("verdict", `String (verdict_string verdict));
                      ]);
                  Printf.printf
                    "gate %s: baseline %d/%d committed (%d/%d tripwires), \
                     candidate %d/%d committed (%d/%d tripwires) -> %s\n%!"
                    lesson_id baseline.committed baseline.total
                    baseline.tripwires_fired baseline.tripwires_measured
                    candidate.committed candidate.total
                    candidate.tripwires_fired candidate.tripwires_measured
                    (verdict_string verdict);
                  0))
    in
    Journal.close journal;
    result
