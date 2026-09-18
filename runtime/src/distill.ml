(* M3: distill — the Reflector/Curator step (ACE shape): read a run's
   journal, extract candidate lessons, write them on PROBATION. Two lanes:

   - MECHANICAL: recognized failure signatures (runner quota, timeouts,
     policy denials) become lessons with zero model spend. Unrecognized
     parks are reported, never guessed at.
   - LLM: the journal digest is handed to an agent runner which proposes
     lessons in a strict line format; parsed, never trusted beyond that.

   Distill runs INSIDE a handler stack of its own: its reads, its lesson
   writes, and any LLM call are journaled, policy-checked effects — the
   learning loop is itself a recorded, replayable trajectory. *)

type candidate = { id : string; matchers : string list; guidance : string }

let now_date () =
  let tm = Unix.gmtime (Unix.gettimeofday ()) in
  Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900) (tm.Unix.tm_mon + 1)
    tm.Unix.tm_mday

(* ---- journal digest ----------------------------------------------------- *)

type failure = {
  task : string;
  runner : string;
  title : string;
  signature : string; (* first line(s) of the failing output *)
}

let digest_journal (entries : Yojson.Safe.t list) :
    failure list * string list (* parked task ids *) =
  let str k e = match Yojson.Safe.Util.member k e with `String s -> s | _ -> "" in
  let data e = Yojson.Safe.Util.member "data" e in
  let current_task = ref ("", "", "") (* id, title, runner *) in
  let failures = ref [] in
  let parked = ref [] in
  List.iter
    (fun e ->
      let phase = str "phase" e and kind = str "kind" e in
      (if phase = "note" && kind = "task_config" then
         let d = data e in
         current_task := (str "task" d, str "title" d, str "runner" d));
      (if phase = "result" && kind = "tool_exec" then
         let d = data e in
         match Yojson.Safe.Util.member "exit_code" d with
         | `Int code when code <> 0 ->
             let id, title, runner = !current_task in
             let out = str "output" d in
             let firstline =
               match String.index_opt out '\n' with
               | Some i -> String.sub out 0 i
               | None -> out
             in
             let firstline =
               if String.length firstline > 300 then String.sub firstline 0 300
               else firstline
             in
             failures :=
               {
                 task = id;
                 runner;
                 title;
                 signature = Printf.sprintf "exit %d: %s" code firstline;
               }
               :: !failures
         | _ -> ());
      if phase = "denied" then (
        let id, title, runner = !current_task in
        failures :=
          {
            task = id;
            runner;
            title;
            signature = Printf.sprintf "policy denied %s: %s" kind (str "reason" (data e));
          }
          :: !failures);
      if phase = "note" && kind = "task_parked" then
        parked := str "task" (data e) :: !parked)
    entries;
  (List.rev !failures, List.rev !parked)

(* ---- mechanical lane ---------------------------------------------------- *)

let slug s =
  String.map
    (fun c ->
      match c with
      | 'a' .. 'z' | '0' .. '9' -> c
      | 'A' .. 'Z' -> Char.lowercase_ascii c
      | _ -> '-')
    s

let contains ~needle hay = Recall.contains ~needle hay

let mechanical_candidates (failures : failure list) : candidate list =
  List.filter_map
    (fun f ->
      if contains ~needle:"usage limit" f.signature
         || contains ~needle:"quota" f.signature
         || contains ~needle:"429" f.signature
         || contains ~needle:"403" f.signature
      then
        Some
          {
            id = Printf.sprintf "runner-%s-quota" (slug f.runner);
            matchers = [ f.runner ];
            guidance =
              Printf.sprintf
                "The %s runner has hit its provider usage limit (observed: \
                 %s). Runs dispatched to it will fail until the quota window \
                 resets; use a different --runner for now."
                f.runner f.signature;
          }
      else if contains ~needle:"TIMEOUT after" f.signature
              || contains ~needle:"exit 124" f.signature
      then
        Some
          {
            id = Printf.sprintf "timeout-%s" (slug f.task);
            matchers = [ f.title ];
            guidance =
              Printf.sprintf
                "Task '%s' timed out (%s). Raise --timeout for this task \
                 class instead of retrying at the same budget."
                f.title f.signature;
          }
      else if contains ~needle:"policy denied" f.signature then
        Some
          {
            id = Printf.sprintf "policy-%s" (slug f.task);
            matchers = [ f.title ];
            guidance =
              Printf.sprintf
                "A previous run of '%s' attempted an action the harness \
                 policy denies (%s). Do not attempt it; work within the \
                 owned paths and let the harness make the commit."
                f.title f.signature;
          }
      else None)
    failures

(* ---- LLM lane ----------------------------------------------------------- *)

let llm_prompt (failures : failure list) (parked : string list) : string =
  String.concat "\n"
    ([
       "You are the consolidation step of an agent harness. Below are \
        failure signatures from one run's effect journal. Propose AT MOST 3 \
        lessons that would help future runs avoid these failures. Only \
        propose a lesson if the evidence supports it; propose none if the \
        failures are transient noise.";
       "";
       "Output STRICTLY in this line format, nothing else:";
       "LESSON id: <kebab-case-slug>";
       "MATCHERS: <comma-separated substrings that select future tasks>";
       "GUIDANCE: <one or two sentences of guidance>";
       "END";
       "";
       Printf.sprintf "Parked tasks: %s" (String.concat ", " parked);
       "Failure signatures:";
     ]
    @ List.map
        (fun f ->
          Printf.sprintf "- task %s (%s, runner %s): %s" f.task f.title
            f.runner f.signature)
        failures)

let parse_llm_output (out : string) : candidate list =
  let lines = String.split_on_char '\n' out in
  let strip_prefix p s =
    if String.starts_with ~prefix:p s then
      Some (String.trim (String.sub s (String.length p) (String.length s - String.length p)))
    else None
  in
  let rec go acc current = function
    | [] -> List.rev acc
    | line :: rest -> (
        let line = String.trim line in
        match strip_prefix "LESSON id:" line with
        | Some id -> go acc (Some (id, [], "")) rest
        | None -> (
            match (current, strip_prefix "MATCHERS:" line) with
            | Some (id, _, g), Some m ->
                let matchers =
                  List.filter_map
                    (fun s ->
                      let s = String.trim s in
                      if s = "" then None else Some s)
                    (String.split_on_char ',' m)
                in
                go acc (Some (id, matchers, g)) rest
            | _ -> (
                match (current, strip_prefix "GUIDANCE:" line) with
                | Some (id, m, _), Some g -> go acc (Some (id, m, g)) rest
                | _ ->
                    if line = "END" then
                      match current with
                      | Some (id, matchers, guidance)
                        when id <> "" && matchers <> [] && guidance <> "" ->
                          go ({ id = slug id; matchers; guidance } :: acc) None rest
                      | _ -> go acc None rest
                    else go acc current rest)))
  in
  go [] None lines

(* ---- driver ------------------------------------------------------------- *)

let write_candidates ~repo_root ~origin_run (cands : candidate list) :
    string list * string list =
  (* returns (written ids, skipped-existing ids) *)
  List.fold_left
    (fun (written, skipped) (c : candidate) ->
      let path =
        Filename.concat (Lesson.lessons_dir repo_root) (c.id ^ ".md")
      in
      if Effect.perform (Effects.File_exists path) then
        (written, skipped @ [ c.id ])
      else (
        ignore
          (Lesson.save ~repo_root
             {
               Lesson.id = c.id;
               status = Lesson.Probation;
               matchers = c.matchers;
               origin_run;
               created = now_date ();
               guidance = c.guidance;
               path;
             });
        (written @ [ c.id ], skipped)))
    ([], []) cands

let run ~repo_root ~work_dir ~run_id ~(llm_runner : Runners.t option)
    ~(timeout_s : int) : int =
  let journal_path =
    Filename.concat (Filename.concat work_dir "journal") (run_id ^ ".jsonl")
  in
  if not (Sys.file_exists journal_path) then (
    Printf.eprintf "no journal at %s\n" journal_path;
    1)
  else
    let entries = Journal.read_lines journal_path in
    let failures, parked = digest_journal entries in
    let distill_journal =
      Journal.open_journal
        ~dir:(Filename.concat work_dir "journal")
        ~run_id:(Printf.sprintf "distill-%s" run_id)
    in
    let world =
      {
        Handler_world.logs_dir =
          Filename.concat work_dir
            (Filename.concat "logs" (Printf.sprintf "distill-%s" run_id));
      }
    in
    let policy =
      {
        Policy.repo_root;
        write_roots = [ Lesson.lessons_dir repo_root; work_dir ];
        commit_paths = [];
      }
    in
    let exit_code =
      Stack.run ~world ~policy ~journal:distill_journal (fun () ->
          Handler_revert.run (fun () ->
              let mech = mechanical_candidates failures in
              let llm =
                match llm_runner with
                | None -> []
                | Some runner ->
                    let res =
                      Effect.perform
                        (Effects.Tool_exec
                           (Runners.exec_req runner
                              ~prompt:(llm_prompt failures parked)
                              ~repo_root ~timeout_s ~log_hint:"distill-llm"))
                    in
                    if res.exit_code <> 0 then (
                      Printf.printf "llm lane failed (exit %d); mechanical lane only\n%!"
                        res.exit_code;
                      [])
                    else parse_llm_output res.output
              in
              let written, skipped =
                write_candidates ~repo_root ~origin_run:run_id (mech @ llm)
              in
              Printf.printf
                "distilled run %s: %d failures, %d parked; %d lessons written \
                 on probation%s%s\n%!"
                run_id (List.length failures) (List.length parked)
                (List.length written)
                (if written <> [] then ": " ^ String.concat ", " written else "")
                (if skipped <> [] then
                   "; already known: " ^ String.concat ", " skipped
                 else "");
              let unrecognized =
                List.filter
                  (fun f ->
                    not
                      (List.exists
                         (fun (c : candidate) ->
                           contains ~needle:(String.sub f.signature 0 (min 20 (String.length f.signature))) c.guidance)
                         (mech @ llm)))
                  failures
              in
              if unrecognized <> [] && written = [] then
                Printf.printf
                  "unrecognized failure signatures (no lesson invented — \
                   review or rerun with --llm):\n%s\n%!"
                  (String.concat "\n"
                     (List.map
                        (fun f -> Printf.sprintf "  %s: %s" f.task f.signature)
                        unrecognized));
              0))
    in
    Journal.close distill_journal;
    exit_code
