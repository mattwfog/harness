(* The catcher: verification after every agent attempt. Runs the task's
   acceptance command, then the run-level checks. Agents never self-certify
   — a claim of done that the catcher can't reproduce is a failed attempt. *)

let run_check ~repo_root ~timeout_s ~log_hint cmd : Effects.exec_result =
  Effect.perform
    (Effects.Tool_exec
       {
         argv = [ "bash"; "-c"; cmd ];
         cwd = repo_root;
         timeout_s;
         log_hint;
         env_extra = [];
       })

let verify ~(task : Task_spec.t) ~repo_root ~(checks : string list)
    ~(timeout_s : int) : (unit, string) result =
  let named =
    ("acceptance", task.acceptance)
    :: List.mapi (fun i c -> (Printf.sprintf "check%d" i, c)) checks
  in
  let rec go = function
    | [] -> Ok ()
    | (name, cmd) :: rest ->
        let res =
          run_check ~repo_root ~timeout_s
            ~log_hint:(Printf.sprintf "%s.%s" task.id name)
            cmd
        in
        if res.exit_code = 0 then go rest
        else
          Error
            (Printf.sprintf "[%s] exit %d\n%s" name res.exit_code res.output)
  in
  go named
