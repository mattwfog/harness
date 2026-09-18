(* M3: recall — the wire from the lesson corpus into prompts. Promoted
   lessons whose matchers hit the task are injected; probation lessons are
   recalled only when explicitly forced (M4's gate does this to measure a
   candidate before promotion). The recall decision itself is journaled. *)

(* How a substring hit becomes a recall. Substring matching alone is
   deterministic but blunt: a lesson whose matcher is "kimi" fires on every
   task that mentions kimi. [Jev] narrows the substring hits with one
   relevance judgment per candidate (the Judge effect), keeping those at or
   above [threshold]. The judgment only ever NARROWS recall; promotion and
   retirement remain the scorecard's measured decision. *)
type judge = Substring | Jev of { model : string; threshold : float }

let default_jev = Jev { model = "jev-latest"; threshold = 0.5 }

let judge_to_string = function
  | Substring -> "substring"
  | Jev { threshold; _ } -> Printf.sprintf "jev:%g" threshold

let judge_of_string s =
  match String.split_on_char ':' (String.lowercase_ascii (String.trim s)) with
  | [ "substring" ] | [ "off" ] -> Ok Substring
  | [ "jev" ] -> Ok default_jev
  | [ "jev"; t ] -> (
      match float_of_string_opt t with
      | Some threshold when threshold >= 0.0 && threshold <= 1.0 ->
          Ok (Jev { model = "jev-latest"; threshold })
      | _ -> Error (Printf.sprintf "bad jev threshold %s (want 0..1)" t))
  | _ -> Error (Printf.sprintf "unknown recall judge %s (substring | jev[:0..1])" s)

type mode =
  | Normal (* promoted lessons only *)
  | Force of string list (* Normal + these lesson ids even on probation *)
  | Suppress (* no lessons at all — the gate's baseline arm *)

let lower = String.lowercase_ascii

let contains ~needle hay =
  let needle = lower needle and hay = lower hay in
  let n = String.length needle and h = String.length hay in
  n > 0
  &&
  let rec go i = i + n <= h && (String.sub hay i n = needle || go (i + 1)) in
  go 0

let matches (l : Lesson.t) ~(haystack : string) =
  List.exists (fun m -> contains ~needle:m haystack) l.matchers

(* One request for the whole candidate set: the task and the candidate
   lessons go in as state, one yes/no question per lesson comes back as a
   probability. Lessons are keyed l0, l1, ... in the state so question text
   can name them by path; answers are keyed by lesson id. *)
let judge_request ~model ~(task : Task_spec.t) ~runner (candidates : Lesson.t list)
    : Effects.judge_req =
  let keyed = List.mapi (fun i l -> (Printf.sprintf "l%d" i, l)) candidates in
  {
    Effects.model;
    state =
      `Assoc
        [
          ( "task",
            `Assoc
              [
                ("title", `String task.title);
                ("body", `String task.body);
                ("runner", `String runner);
              ] );
          ( "lessons",
            `Assoc
              (List.map
                 (fun (key, (l : Lesson.t)) ->
                   (key, `Assoc [ ("guidance", `String l.guidance) ]))
                 keyed) );
        ];
    questions =
      List.map
        (fun (key, (l : Lesson.t)) ->
          {
            Effects.qid = l.id;
            instructions =
              Printf.sprintf
                "A lesson is a note about a specific tool, runner, constraint or \
                 failure mode. Is the lesson in `lessons.%s.guidance` about \
                 something the task in `task` actually involves — the runner in \
                 `task.runner`, or a tool or activity the task describes?"
                key;
            yes =
              "The task uses the tool or runner the lesson is about, or \
               performs the activity the lesson gives guidance for.";
            no =
              "The lesson only shares a word with the task: it is about a \
               different activity, even if it mentions the same tool name.";
          })
        keyed;
  }

(* Narrow substring hits by judged relevance. A judge that is denied or fails
   falls back to the substring selection — recall degrades, it never breaks a
   run. The fallback note carries no error text: the journal already holds
   the denial, and replay must reproduce this note byte-for-byte. *)
let narrow ~judge ~(task : Task_spec.t) ~runner (hits : Lesson.t list) :
    Lesson.t list =
  match (judge, hits) with
  | Substring, _ | _, [] -> hits
  | Jev { model; threshold }, _ -> (
      match Effect.perform (Effects.Judge (judge_request ~model ~task ~runner hits)) with
      | (res : Effects.judge_result) ->
          let p_of (l : Lesson.t) =
            Option.value ~default:0.0 (List.assoc_opt l.id res.probabilities)
          in
          Effect.perform
            (Effects.Note
               ( "recall_judged",
                 `Assoc
                   [
                     ("task", `String task.id);
                     ("threshold", `Float threshold);
                     ( "probabilities",
                       `Assoc
                         (List.map
                            (fun (l : Lesson.t) -> (l.id, `Float (p_of l)))
                            hits) );
                   ] ));
          List.filter (fun l -> p_of l >= threshold) hits
      | exception (Effects.Policy_denied _ | Failure _) ->
          Effect.perform
            (Effects.Note
               ( "recall_judge_unavailable",
                 `Assoc
                   [ ("task", `String task.id); ("fallback", `String "substring") ]
               ));
          hits)

let for_task ?(judge = Substring) ~repo_root ~(task : Task_spec.t)
    ~(runner : string) ~(mode : mode) () : Lesson.t list =
  match mode with
  | Suppress -> []
  | Normal | Force _ ->
      let forced = match mode with Force ids -> ids | _ -> [] in
      let lessons, errors = Lesson.load_all ~repo_root in
      if errors <> [] then
        Effect.perform
          (Effects.Note
             ( "lesson_parse_errors",
               `List (List.map (fun e -> `String e) errors) ));
      let haystack = String.concat "\n" [ task.title; task.body; runner ] in
      (* Forced lessons bypass the judge: the gate forces a candidate
         precisely to measure it, so nothing may filter it out. *)
      let hits =
        List.filter
          (fun (l : Lesson.t) ->
            l.status = Lesson.Promoted && matches l ~haystack
            && not (List.mem l.id forced))
          lessons
      in
      let kept = narrow ~judge ~task ~runner hits in
      let selected =
        List.filter
          (fun (l : Lesson.t) ->
            (l.status <> Lesson.Retired && List.mem l.id forced)
            || List.exists (fun (k : Lesson.t) -> k.id = l.id) kept)
          lessons
      in
      Effect.perform
        (Effects.Note
           ( "recall",
             `Assoc
               [
                 ("task", `String task.id);
                 ( "lessons",
                   `List (List.map (fun (l : Lesson.t) -> `String l.id) selected)
                 );
               ] ));
      selected
