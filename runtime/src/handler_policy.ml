(* The middle handler: person-in-command. Checks every effect against the
   policy before letting it propagate outward to the world. A denial never
   reaches the world; it travels back inward as Policy_denied, which the
   capture handler journals. *)

open Effect
open Effect.Deep

let deny ~effect_kind ~reason =
  Effects.Policy_denied { effect_kind; reason }

let forward (type b) (k : (b, _) continuation) (eff : b Effect.t) =
  match perform eff with
  | (res : b) -> continue k res
  | exception e -> discontinue k e

let run (policy : Policy.t) (fn : unit -> 'a) : 'a =
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
                  match Policy.check_tool_exec policy req with
                  | Ok () -> forward k (Effects.Tool_exec req)
                  | Error reason ->
                      discontinue k (deny ~effect_kind:"tool_exec" ~reason))
          | Effects.File_write req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match Policy.check_file_write policy req with
                  | Ok () -> forward k (Effects.File_write req)
                  | Error reason ->
                      discontinue k (deny ~effect_kind:"file_write" ~reason))
          | Effects.Git_commit req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match Policy.check_git_commit policy req with
                  | Ok () -> forward k (Effects.Git_commit req)
                  | Error reason ->
                      discontinue k (deny ~effect_kind:"git_commit" ~reason))
          | Effects.Judge req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match Policy.check_judge policy req with
                  | Ok () -> forward k (Effects.Judge req)
                  | Error reason ->
                      discontinue k (deny ~effect_kind:"judge" ~reason))
          | Effects.File_read path ->
              (* Reads are allowed everywhere; they pass through so the
                 capture handler has already journaled them. *)
              Some (fun (k : (b, _) continuation) -> forward k (Effects.File_read path))
          | Effects.File_exists path ->
              Some
                (fun (k : (b, _) continuation) -> forward k (Effects.File_exists path))
          | Effects.Clock ->
              Some (fun (k : (b, _) continuation) -> forward k Effects.Clock)
          | Effects.Note n ->
              Some (fun (k : (b, _) continuation) -> forward k (Effects.Note n))
          | _ -> None);
    }
