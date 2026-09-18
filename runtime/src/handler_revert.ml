(* M3: revert — temporal composability for harness-mediated writes (the
   Cordis shape: an effect carries its inverse; a failed scope's side
   effects roll back as a unit).

   Placement: INNERMOST, inside capture — so the snapshots it takes
   (File_exists/File_read) and the rollback writes it performs are
   themselves journaled, policy-checked effects, and replay reproduces
   reverts exactly like any other trajectory.

   Honest scope: this reverts File_write effects only. Tool_exec side
   effects (an agent subprocess's own writes) are not harness-mediated and
   are NOT reverted — that boundary is the runner sandbox's. Git commits
   are never reverted (house law: fix forward); a Git_commit inside the
   scope CLEARS the undo log — committed work is kept. *)

open Effect
open Effect.Deep

type undo = { path : string; prior : string option (* None = did not exist *) }

let run (fn : unit -> 'a) : 'a =
  let undo_log : undo list ref = ref [] in
  let rollback () =
    List.iter
      (fun { path; prior } ->
        match prior with
        | Some content -> perform (Effects.File_write { path; content })
        | None -> (
            (* No File_delete effect yet; restore-to-empty is the closest
               journaled inverse. Recorded distinctly in the note below. *)
            perform (Effects.File_write { path; content = "" })))
      !undo_log;
    perform
      (Effects.Note
         ( "revert",
           `Assoc
             [
               ( "rolled_back",
                 `List
                   (List.map
                      (fun u ->
                        `Assoc
                          [
                            ("path", `String u.path);
                            ("existed", `Bool (u.prior <> None));
                          ])
                      !undo_log) );
             ] ));
    undo_log := []
  in
  match_with fn ()
    {
      retc = Fun.id;
      exnc =
        (fun e ->
          if !undo_log <> [] then rollback ();
          raise e);
      effc =
        (fun (type b) (eff : b Effect.t) ->
          match eff with
          | Effects.File_write req ->
              Some
                (fun (k : (b, _) continuation) ->
                  let prior =
                    if perform (Effects.File_exists req.path) then
                      Some (perform (Effects.File_read req.path))
                    else None
                  in
                  match perform (Effects.File_write req) with
                  | () ->
                      undo_log := { path = req.path; prior } :: !undo_log;
                      continue k ()
                  | exception e -> discontinue k e)
          | Effects.Git_commit req ->
              Some
                (fun (k : (b, _) continuation) ->
                  match perform (Effects.Git_commit req) with
                  | res ->
                      (* Committed work is kept forward, never reverted. *)
                      undo_log := [];
                      continue k res
                  | exception e -> discontinue k e)
          | _ -> None);
    }
