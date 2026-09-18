(* Disjoint-ownership validation: two concurrent tasks may never own
   overlapping paths, because all agents in a run share one checkout. *)

let overlap a b =
  let a = Filename.concat "" a and b = Filename.concat "" b in
  let a = String.trim a and b = String.trim b in
  let strip s =
    if String.length s > 0 && s.[String.length s - 1] = '/' then
      String.sub s 0 (String.length s - 1)
    else s
  in
  let a = strip a and b = strip b in
  a = b
  || String.starts_with ~prefix:(b ^ "/") a
  || String.starts_with ~prefix:(a ^ "/") b

let check_disjoint (tasks : Task_spec.t list) : (unit, string) result =
  let rec go seen = function
    | [] -> Ok ()
    | (task : Task_spec.t) :: rest ->
        let clash =
          List.find_map
            (fun owned ->
              List.find_map
                (fun (other_path, other_id) ->
                  if overlap owned other_path then
                    Some (task.id, other_id, owned, other_path)
                  else None)
                seen)
            task.owns
        in
        (match clash with
        | Some (id_a, id_b, path_a, path_b) ->
            Error
              (Printf.sprintf
                 "ownership overlap: %s and %s both cover '%s' / '%s'" id_a
                 id_b path_a path_b)
        | None ->
            go (List.map (fun p -> (p, task.id)) task.owns @ seen) rest)
  in
  go [] tasks
