(* Prompt assembly (dispatch.py build_prompt, generalized): mission + owned
   paths + acceptance + repo standing orders + recalled lessons + failure
   context from a prior failed attempt. The lessons slot is the recall wire
   the M3 learning loop feeds; it exists (and is journaled) from day one. *)

let standing_orders_cap = 20_000

let build ~(task : Task_spec.t) ~(checks : string list)
    ~(standing_orders : string option) ~(lessons : string list)
    ~(failure_context : string option) : string =
  let section title lines = ("## " ^ title) :: lines in
  let orders =
    match standing_orders with
    | Some text ->
        let text =
          if String.length text > standing_orders_cap then
            String.sub text 0 standing_orders_cap ^ "\n… [truncated]"
          else text
        in
        section "Standing orders (repo AGENTS.md — obey it; modify ONLY your owned paths; NEVER run git)"
          [ text ]
    | None ->
        [
          "You are one agent in a fleet sharing one checkout. Modify ONLY \
           your owned paths. NEVER run git.";
        ]
  in
  let mission =
    section (Printf.sprintf "Task %s: %s" task.id task.title) [ task.body ]
  in
  let owns =
    section "Owned paths (the ONLY paths you may create or modify)"
      (List.map (fun p -> "- " ^ p) task.owns)
  in
  let accept =
    section "Acceptance (must pass before you finish; run it yourself)"
      (Printf.sprintf "    %s" task.acceptance
      ::
      (match checks with
      | [] -> []
      | cs -> "Also required to pass:" :: List.map (fun c -> "    " ^ c) cs))
  in
  let lessons_block =
    match lessons with
    | [] -> []
    | ls ->
        section "Lessons from previous runs (each one was paid for; heed them)"
          (List.map (fun l -> "- " ^ l) ls)
  in
  let failure_block =
    match failure_context with
    | None -> []
    | Some ctx ->
        let cap = 6000 in
        let ctx =
          if String.length ctx > cap then
            String.sub ctx (String.length ctx - cap) cap
          else ctx
        in
        section "PREVIOUS ATTEMPT FAILED VERIFICATION"
          [ "Fix the following and re-verify. Failure output:"; "```"; ctx; "```" ]
  in
  String.concat "\n"
    (List.concat
       [ orders; [ "" ]; mission; [ "" ]; owns; [ "" ]; accept; lessons_block; failure_block ])
