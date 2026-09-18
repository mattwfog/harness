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

type candidate = {
  id : string;
  matchers : string list;
  guidance : string;
  hint : Lesson.layer; (* what the lane that proposed it already knows *)
}

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
      if phase = "failed" then (
        let id, title, runner = !current_task in
        failures :=
          {
            task = id;
            runner;
            title;
            signature = Printf.sprintf "%s failed: %s" kind (str "reason" (data e));
          }
          :: !failures);
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
            hint = Lesson.Immediate; (* true now, false when the window resets *)
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
            hint = Lesson.Full;
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
            hint = Lesson.Full;
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
                          go ({ id = slug id; matchers; guidance; hint = Lesson.Full } :: acc) None rest
                      | _ -> go acc None rest
                    else go acc current rest)))
  in
  go [] None lines

(* ---- evidence ------------------------------------------------------------ *)

(* What the run's journal recorded, task by task: what the agent said, what
   each check printed, what the harness decided. This — not a failure's first
   line — is what a candidate memory is verified against. *)
let evidence_cap = 24_000

let evidence_digest ?(cap = evidence_cap) (entries : Yojson.Safe.t list) : string =
  let open Yojson.Safe.Util in
  let str k e = match member k e with `String s -> s | _ -> "" in
  let strs k e =
    match member k e with
    | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
    | _ -> []
  in
  (* One section per task. A task is EVENTFUL if anything in it failed, was
     rejected, was retried, parked, or ran with recalled lessons; a long
     session is mostly uneventful, and the cap must never be spent on forty
     clean tasks while the one failure at the end is cut off. *)
  let sections = ref [] in
  let header = ref "" and body = Buffer.create 1024 and eventful = ref false in
  let flush () =
    if !header <> "" then
      sections := (!header, Buffer.contents body, !eventful) :: !sections;
    Buffer.clear body;
    eventful := false
  in
  let line fmt = Printf.ksprintf (fun l -> Buffer.add_string body (l ^ "\n")) fmt in
  let pending = ref `Check in
  List.iter
    (fun e ->
      let phase = str "phase" e and kind = str "kind" e and d = member "data" e in
      match (phase, kind) with
      | "note", "task_config" ->
          flush ();
          header :=
            Printf.sprintf "## task %s: %s (owns %s)" (str "task" d) (str "title" d)
              (String.concat ", " (strs "owns" d))
      | "note", "recall" when strs "lessons" d <> [] ->
          eventful := true;
          line "[harness] lessons injected into the prompt: %s"
            (String.concat ", " (strs "lessons" d))
      | "note", "attempt_start" ->
          let n = match member "attempt" d with `Int n -> n | _ -> 0 in
          if n > 1 then eventful := true;
          line "[harness] attempt %d" n
      | "request", "tool_exec" ->
          let argv = strs "argv" d in
          let is_snapshot =
            List.exists (fun a -> contains ~needle:"git ls-files -m -d" a) argv
          in
          let is_agent =
            member "env_extra" d <> `List []
            || (match argv with
               | prog :: _ ->
                   Filename.basename prog = "kimi" || Filename.basename prog = "codex"
               | [] -> false)
          in
          pending :=
            if is_snapshot then `Snapshot
            else if is_agent then `Agent
            else `Command (match List.rev argv with last :: _ -> last | [] -> "")
      | "result", "tool_exec" -> (
          let code = match member "exit_code" d with `Int c -> c | _ -> 0 in
          let output =
            let o = String.trim (str "output" d) in
            if String.length o > 900 then String.sub o 0 900 else o
          in
          if code <> 0 && !pending <> `Snapshot then eventful := true;
          match !pending with
          | `Snapshot -> ()
          | `Agent -> line "[agent] exit %d\n%s" code output
          | `Command cmd -> line "[check] exit %d | %s\n%s" code cmd output
          | `Check -> line "[check] exit %d\n%s" code output)
      | "denied", _ ->
          eventful := true;
          line "[harness] %s denied by policy: %s" kind (str "reason" d)
      | "failed", _ ->
          eventful := true;
          line "[harness] %s failed: %s" kind (str "reason" d)
      | "note", "scope_violation" ->
          eventful := true;
          line "[harness] attempt rejected: files changed outside the owned paths: %s"
            (String.concat ", " (strs "paths" d))
      | "note", "task_parked" ->
          eventful := true;
          line "[harness] task %s PARKED" (str "task" d)
      | "result", "git_commit" -> line "[harness] committed"
      | _ -> ())
    entries;
  flush ();
  let sections = List.rev !sections in
  let render ~collapse_clean =
    String.concat ""
      (List.map
         (fun (h, b, ev) ->
           if ev || not collapse_clean then h ^ "\n" ^ b
           else h ^ " - completed on the first attempt, nothing notable\n")
         sections)
  in
  let full = render ~collapse_clean:false in
  let text = if String.length full <= cap then full else render ~collapse_clean:true in
  let text = if String.length text > cap then String.sub text 0 cap else text in
  (* Agent output is untrusted: it can carry a credential. Nothing
     credential-shaped goes to the judge. *)
  Redact.scrub text

(* ---- verification ------------------------------------------------------- *)

(* Four independent judgments decide whether a candidate becomes memory, and
   which kind. A proposer (mechanical or LLM) can be wrong in four different
   ways: it can invent, it can misread, it can mistake a moment for a rule,
   and it can recommend the very shortcut that caused the failure. *)
type verdict =
  | Deny of string (* harmful | contradicted | unsupported *)
  | Keep of Lesson.layer

let questions : Effects.noul_question list =
  [
    {
      Effects.qid = "supported";
      instructions =
        "Read the run record in `evidence`. Is the statement in `candidate` \
         directly supported by what that record shows happened, rather than \
         adding causes, facts or names the record does not contain?";
      yes = "The record shows it: the relevant output, check result or harness note is there.";
      no = "The record does not show it, or the statement adds something the record does not contain.";
    };
    {
      qid = "contradicted";
      instructions =
        "Read the run record in `evidence`. Does the record show that the \
         statement in `candidate` is itself wrong - a fact it asserts is \
         false, or the course of action it recommends was tried in the record \
         and failed? An agent in the record doing the opposite of what the \
         statement advises does NOT contradict it; if that opposite behaviour \
         failed, that is evidence for the statement.";
      yes = "The record shows a fact in the statement is false, or shows the action it recommends failing.";
      no = "Nothing in the record shows the statement to be wrong - including when the record shows an agent ignoring this advice and failing.";
    };
    {
      qid = "durable";
      instructions =
        "Is the statement in `candidate` a lasting property of the codebase, \
         its tools or how work must be done here - something that stays true \
         until someone changes the code or the rules - rather than a \
         description of a temporary state at the time of this run?";
      yes = "Lasting: a rule, a fact about the code or schema, or a way of working that will still hold next month.";
      no = "Temporary: a quota that is currently used up, which files are currently unfinished, a one-off outage or what happened in this particular run.";
    };
    {
      qid = "harmful";
      instructions =
        "Does the statement in `candidate` ADVISE or INSTRUCT an agent to \
         weaken, skip or work around a check, test, lint rule, policy or \
         review, or to reuse code the record marks as frozen or forbidden? A \
         statement that only describes what happened, or that warns against \
         such a shortcut, does not.";
      yes = "It tells the agent to defeat a safeguard or reuse forbidden code.";
      no = "It describes an event, states a fact, or tells the agent to keep safeguards intact.";
    };
  ]

let hypothesis_floor = 0.3

let route ~(threshold : float) (p : (string * float) list) : verdict =
  let get k = Option.value ~default:0.0 (List.assoc_opt k p) in
  if get "harmful" >= threshold then Deny "harmful"
  else if get "contradicted" >= threshold then Deny "contradicted"
  else if get "supported" >= threshold then
    Keep (if get "durable" >= threshold then Lesson.Full else Lesson.Immediate)
  else if get "supported" >= hypothesis_floor then Keep Lesson.Hypothesis
  else Deny "unsupported"

let probabilities_json p : Yojson.Safe.t =
  `Assoc (List.map (fun (k, v) -> (k, `Float v)) p)

(* Returns None when the judge is unavailable: the candidate then keeps the
   layer its proposer hinted, exactly as before verification existed. *)
let verify_candidate ~model ~threshold ~evidence (c : candidate) : verdict option =
  let req =
    {
      Effects.model;
      state = `Assoc [ ("evidence", `String evidence); ("candidate", `String c.guidance) ];
      questions;
    }
  in
  match Effect.perform (Effects.Judge req) with
  | (res : Effects.judge_result) ->
      let verdict = route ~threshold res.probabilities in
      Effect.perform
        (Effects.Note
           ( (match verdict with Deny _ -> "memory_denied" | Keep _ -> "memory_kept"),
             `Assoc
               [
                 ("candidate", `String c.id);
                 ( "verdict",
                   `String
                     (match verdict with
                     | Deny why -> why
                     | Keep layer -> Lesson.layer_to_string layer) );
                 ("probabilities", probabilities_json res.probabilities);
               ] ));
      Some verdict
  | exception (Effects.Policy_denied _ | Failure _) ->
      Effect.perform
        (Effects.Note ("memory_unverified", `Assoc [ ("candidate", `String c.id) ]));
      None

(* A promoted lesson that was injected into this run and that the run's own
   record contradicts goes back to probation: a direct observation outranks a
   remembered rule, and the gate has to earn it its place again. *)
let demote_contradicted ~repo_root ~model ~threshold ~evidence
    (entries : Yojson.Safe.t list) : string list =
  let open Yojson.Safe.Util in
  let injected =
    List.concat_map
      (fun e ->
        if member "kind" e = `String "recall" then
          match member "lessons" (member "data" e) with
          | `List l -> List.filter_map (function `String s -> Some s | _ -> None) l
          | _ -> []
        else [])
      entries
    |> List.sort_uniq compare
  in
  if injected = [] then []
  else
    let lessons, _ = Lesson.load_all ~repo_root in
    List.filter_map
      (fun (l : Lesson.t) ->
        if l.status <> Lesson.Promoted || not (List.mem l.id injected) then None
        else
          let req =
            {
              Effects.model;
              state = `Assoc [ ("evidence", `String evidence); ("candidate", `String l.guidance) ];
              questions = List.filter (fun (q : Effects.noul_question) -> q.qid = "contradicted") questions;
            }
          in
          match Effect.perform (Effects.Judge req) with
          | (res : Effects.judge_result) ->
              let p = Option.value ~default:0.0 (List.assoc_opt "contradicted" res.probabilities) in
              if p >= threshold then (
                ignore (Lesson.set_status ~repo_root l Lesson.Probation);
                Effect.perform
                  (Effects.Note
                     ( "lesson_contradicted",
                       `Assoc [ ("lesson", `String l.id); ("probability", `Float p) ] ));
                Some l.id)
              else None
          | exception (Effects.Policy_denied _ | Failure _) -> None)
      lessons

(* ---- driver ------------------------------------------------------------- *)

let immediate_ttl_days = 7

let dedupe (cands : candidate list) : candidate list =
  List.fold_left
    (fun acc (c : candidate) ->
      if List.exists (fun (k : candidate) -> k.id = c.id) acc then acc else acc @ [ c ])
    [] cands

let write_candidates ~repo_root ~origin_run ~(now : int)
    (cands : (candidate * Lesson.layer) list) : string list * string list =
  (* returns (written ids, skipped-existing ids) *)
  List.fold_left
    (fun (written, skipped) ((c : candidate), layer) ->
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
               layer;
               expires =
                 (if layer = Lesson.Immediate then
                    Some (Effects.date_of_epoch (now + (immediate_ttl_days * 86_400)))
                  else None);
               evidence = [ origin_run ];
               matchers = c.matchers;
               origin_run;
               created = Effects.date_of_epoch now;
               guidance = c.guidance;
               path;
             });
        (written @ [ c.id ], skipped)))
    ([], []) cands

let run ~repo_root ~work_dir ~run_id ~(llm_runner : Runners.t option)
    ~(verify : Recall.judge) ~(timeout_s : int) : int =
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
              let candidates = dedupe (mech @ llm) in
              let now = Effect.perform Effects.Clock in
              let evidence = evidence_digest entries in
              let routed, denied =
                List.fold_left
                  (fun (kept, denied) (c : candidate) ->
                    if Redact.contains_secret c.guidance || Redact.contains_secret c.id
                    then (
                      (* Deterministic, and independent of any verifier: a
                         credential is never written into memory. *)
                      Effect.perform
                        (Effects.Note
                           ( "memory_denied",
                             `Assoc
                               [
                                 ("candidate", `String (Redact.scrub c.id));
                                 ("verdict", `String "secret");
                               ] ));
                      (kept, denied @ [ (Redact.scrub c.id, "secret") ]))
                    else
                    match verify with
                    | Recall.Substring -> (kept @ [ (c, c.hint) ], denied)
                    | Recall.Jev { model; threshold } -> (
                        match verify_candidate ~model ~threshold ~evidence c with
                        | None -> (kept @ [ (c, c.hint) ], denied)
                        | Some (Keep layer) -> (kept @ [ (c, layer) ], denied)
                        | Some (Deny why) -> (kept, denied @ [ (c.id, why) ])))
                  ([], []) candidates
              in
              let demoted =
                match verify with
                | Recall.Substring -> []
                | Recall.Jev { model; threshold } ->
                    demote_contradicted ~repo_root ~model ~threshold ~evidence entries
              in
              let written, skipped =
                write_candidates ~repo_root ~origin_run:run_id ~now routed
              in
              let layer_of id =
                match List.find_opt (fun ((c : candidate), _) -> c.id = id) routed with
                | Some (_, layer) -> Lesson.layer_to_string layer
                | None -> "full"
              in
              Printf.printf "distilled run %s: %d failures, %d parked\n%!" run_id
                (List.length failures) (List.length parked);
              List.iter
                (fun id -> Printf.printf "  kept     %-12s %s\n%!" (layer_of id) id)
                written;
              List.iter (fun id -> Printf.printf "  known    %s\n%!" id) skipped;
              List.iter
                (fun (id, why) -> Printf.printf "  denied   %-12s %s\n%!" why id)
                denied;
              List.iter
                (fun id ->
                  Printf.printf "  demoted  %s (contradicted by this run; back on probation)\n%!" id)
                demoted;
              let unrecognized =
                List.filter
                  (fun f ->
                    not
                      (List.exists
                         (fun (c : candidate) ->
                           contains ~needle:(String.sub f.signature 0 (min 20 (String.length f.signature))) c.guidance)
                         candidates))
                  failures
              in
              if unrecognized <> [] && written = [] && denied = [] then
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
