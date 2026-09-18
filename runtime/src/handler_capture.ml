(* The innermost handler: capture. Sees every effect FIRST — including ones
   policy will go on to deny — journals the request, forwards outward, then
   journals the result or the denial before resuming the program. An agent
   action that isn't journaled is unrepresentable: there is no path to the
   world that skips this handler. *)

open Effect
open Effect.Deep

let output_cap = 200_000

let run (j : Journal.t) (fn : unit -> 'a) : 'a =
  let captured (type b) ~kind ~(req_json : Yojson.Safe.t)
      ~(res_json : b -> Yojson.Safe.t) (eff : b Effect.t)
      (k : (b, _) continuation) =
    let seq = Journal.request j ~kind req_json in
    match perform eff with
    | (res : b) ->
        ignore (Journal.result j ~kind ~ref_seq:seq (res_json res));
        continue k res
    | exception (Effects.Policy_denied { reason; _ } as e) ->
        Journal.denied j ~kind ~ref_seq:seq ~reason;
        discontinue k e
    | exception e ->
        Journal.denied j ~kind ~ref_seq:seq ~reason:(Printexc.to_string e);
        discontinue k e
  in
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
                  captured ~kind:"tool_exec"
                    ~req_json:(Effects.exec_req_json req)
                    ~res_json:(Effects.exec_result_json ~cap:output_cap)
                    eff k)
          | Effects.File_read path ->
              Some
                (fun (k : (b, _) continuation) ->
                  captured ~kind:"file_read"
                    ~req_json:(Effects.file_read_req_json path)
                    ~res_json:(fun s ->
                      (* Full content (capped) — replay's answer substrate. *)
                      let truncated = String.length s > output_cap in
                      `Assoc
                        [
                          ("bytes", `Int (String.length s));
                          ( "content",
                            `String
                              (if truncated then String.sub s 0 output_cap
                               else s) );
                          ("content_truncated", `Bool truncated);
                        ])
                    eff k)
          | Effects.File_exists path ->
              Some
                (fun (k : (b, _) continuation) ->
                  captured ~kind:"file_exists"
                    ~req_json:(Effects.file_exists_req_json path)
                    ~res_json:(fun b -> `Assoc [ ("exists", `Bool b) ])
                    eff k)
          | Effects.File_write req ->
              Some
                (fun (k : (b, _) continuation) ->
                  captured ~kind:"file_write"
                    ~req_json:(Effects.file_write_req_json req)
                    ~res_json:(fun () -> `Assoc [])
                    eff k)
          | Effects.Git_commit req ->
              Some
                (fun (k : (b, _) continuation) ->
                  captured ~kind:"git_commit"
                    ~req_json:(Effects.git_commit_req_json req)
                    ~res_json:(fun (r : Effects.commit_result) ->
                      `Assoc [ ("sha", `String r.sha) ])
                    eff k)
          | Effects.Judge req ->
              Some
                (fun (k : (b, _) continuation) ->
                  captured ~kind:"judge"
                    ~req_json:(Effects.judge_req_json req)
                    ~res_json:Effects.judge_result_json eff k)
          | Effects.Note (label, data) ->
              Some
                (fun (k : (b, _) continuation) ->
                  Journal.note j ~label data;
                  match perform eff with
                  | () -> continue k ()
                  | exception e -> discontinue k e)
          | _ -> None);
    }
