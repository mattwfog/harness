(* Resumable run state, persisted atomically (tmp + rename) on every task
   transition — a killed run resumes without re-spending agent quota on
   finished work. *)

type t = {
  run_id : string;
  path : string option; (* None = ephemeral (replay): never touches disk *)
  mutable data : Yojson.Safe.t;
}

let state_dir work_dir = Filename.concat work_dir "state"

let fresh_data run_id =
  `Assoc
    [
      ("run_id", `String run_id);
      ("started", `Float (Unix.gettimeofday ()));
      ("tasks", `Assoc []);
    ]

let create_ephemeral ~run_id = { run_id; path = None; data = fresh_data run_id }

let create ~work_dir ~run_id =
  let dir = state_dir work_dir in
  if not (Sys.file_exists dir) then Unix.mkdir dir 0o755;
  {
    run_id;
    path = Some (Filename.concat dir (run_id ^ ".json"));
    data = fresh_data run_id;
  }

let load ~work_dir ~run_id =
  let path = Filename.concat (state_dir work_dir) (run_id ^ ".json") in
  { run_id; path = Some path; data = Yojson.Safe.from_file path }

let persist t =
  match t.path with
  | None -> ()
  | Some path ->
      let tmp = path ^ ".tmp" in
      Yojson.Safe.to_file tmp t.data;
      Sys.rename tmp path

let tasks t =
  match Yojson.Safe.Util.member "tasks" t.data with
  | `Assoc l -> l
  | _ -> []

let task_entry t task_id =
  match List.assoc_opt task_id (tasks t) with
  | Some (`Assoc fields) -> fields
  | _ -> []

let status_of t task_id =
  match List.assoc_opt "status" (task_entry t task_id) with
  | Some (`String s) -> s
  | _ -> "pending"

let attempts_of t task_id =
  match List.assoc_opt "attempts" (task_entry t task_id) with
  | Some (`Int n) -> n
  | _ -> 0

let set_task t task_id (fields : (string * Yojson.Safe.t) list) =
  let others = List.remove_assoc task_id (tasks t) in
  let data =
    match t.data with
    | `Assoc top ->
        `Assoc
          (List.map
             (fun (k, v) ->
               if k = "tasks" then (k, `Assoc ((task_id, `Assoc fields) :: others))
               else (k, v))
             top)
    | other -> other
  in
  t.data <- data;
  persist t

let transition t task_id ~status ?(extra : (string * Yojson.Safe.t) list = [])
    () =
  let entry = task_entry t task_id in
  let keep k = not (List.mem_assoc k extra) && k <> "status" && k <> "updated" in
  let carried = List.filter (fun (k, _) -> keep k) entry in
  set_task t task_id
    (("status", `String status)
    :: ("updated", `Float (Unix.gettimeofday ()))
    :: (extra @ carried))

let bump_attempts t task_id =
  let n = attempts_of t task_id + 1 in
  let entry = List.remove_assoc "attempts" (task_entry t task_id) in
  set_task t task_id (("attempts", `Int n) :: entry);
  n
