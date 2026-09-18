(* M3: recall — the wire from the lesson corpus into prompts. Promoted
   lessons whose matchers hit the task are injected; probation lessons are
   recalled only when explicitly forced (M4's gate does this to measure a
   candidate before promotion). The recall decision itself is journaled. *)

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

let for_task ~repo_root ~(task : Task_spec.t) ~(runner : string) ~(mode : mode)
    : Lesson.t list =
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
      let selected =
        List.filter
          (fun (l : Lesson.t) ->
            (match l.status with
            | Lesson.Promoted -> matches l ~haystack
            | Lesson.Probation -> List.mem l.id forced
            | Lesson.Retired -> false))
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
