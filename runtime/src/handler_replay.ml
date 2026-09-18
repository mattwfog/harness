(* M2: deterministic replay. Re-interprets a recorded journal: every effect
   the program performs is matched against the next journal entry — same
   kind, same canonical request payload, in the same order — and answered
   from the recorded result (or the recorded denial), never from the world.
   Any difference — an extra effect, a missing one, a changed argv, a
   drifted prompt — raises Divergence naming the sequence point.

   A replayed trajectory that completes with the journal fully consumed is
   the proof that the program, as code exists TODAY, still takes exactly
   the recorded path — which is what turns every journal (production
   successes and failures alike) into a permanent regression eval. *)

open Effect.Deep

exception Divergence of { seq : int; expected : string; got : string }

exception
  Unreplayable of { seq : int; reason : string }
(* e.g. a journal from before file_read content capture *)

type cursor = { mutable remaining : Yojson.Safe.t list; mutable last_seq : int }

let of_journal_file path =
  { remaining = Journal.read_lines path; last_seq = 0 }

let fully_consumed c = c.remaining = []

let field name entry = Yojson.Safe.Util.member name entry

let str name entry =
  match field name entry with `String s -> s | _ -> ""

let int_field name entry =
  match field name entry with `Int i -> i | _ -> 0

let next c ~(got : string) =
  match c.remaining with
  | [] ->
      raise
        (Divergence
           { seq = c.last_seq + 1; expected = "end of journal"; got })
  | e :: rest ->
      c.remaining <- rest;
      c.last_seq <- int_field "seq" e;
      e

(* Match a performed effect's request against the journal, then return the
   recorded outcome entry (result or denied). *)
let match_request c ~kind ~(req_json : Yojson.Safe.t) : Yojson.Safe.t =
  let got = Printf.sprintf "%s %s" kind (Yojson.Safe.to_string req_json) in
  let entry = next c ~got in
  let e_phase = str "phase" entry and e_kind = str "kind" entry in
  if e_phase <> "request" || e_kind <> kind then
    raise
      (Divergence
         {
           seq = int_field "seq" entry;
           expected = Printf.sprintf "%s %s" e_phase e_kind;
           got;
         });
  let recorded = Yojson.Safe.to_string (field "data" entry) in
  let performed = Yojson.Safe.to_string req_json in
  if recorded <> performed then
    raise
      (Divergence
         { seq = int_field "seq" entry; expected = recorded; got = performed });
  let outcome = next c ~got:(kind ^ " <awaiting result>") in
  let o_phase = str "phase" outcome in
  if o_phase <> "result" && o_phase <> "denied" then
    raise
      (Divergence
         {
           seq = int_field "seq" outcome;
           expected = "result|denied";
           got = o_phase;
         });
  outcome

let match_note c ~label ~(data : Yojson.Safe.t) =
  let got = Printf.sprintf "note %s" label in
  let entry = next c ~got in
  if str "phase" entry <> "note" || str "kind" entry <> label then
    raise
      (Divergence
         {
           seq = int_field "seq" entry;
           expected = Printf.sprintf "%s %s" (str "phase" entry) (str "kind" entry);
           got;
         });
  let recorded = Yojson.Safe.to_string (field "data" entry) in
  let performed = Yojson.Safe.to_string data in
  if recorded <> performed then
    raise
      (Divergence
         { seq = int_field "seq" entry; expected = recorded; got = performed })

let denial_of outcome =
  Effects.Policy_denied
    {
      effect_kind = str "kind" outcome;
      reason = (match field "data" outcome with
               | `Assoc fields -> (
                   match List.assoc_opt "reason" fields with
                   | Some (`String r) -> r
                   | _ -> "")
               | _ -> "");
    }

let answer (type b) c ~kind ~req_json ~(decode : Yojson.Safe.t -> b)
    (k : (b, _) continuation) =
  let outcome = match_request c ~kind ~req_json in
  if str "phase" outcome = "denied" then discontinue k (denial_of outcome)
  else continue k (decode (field "data" outcome))

let run (c : cursor) (fn : unit -> 'a) : 'a =
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
                  answer c ~kind:"tool_exec"
                    ~req_json:(Effects.exec_req_json req)
                    ~decode:(fun d ->
                      {
                        Effects.exit_code = int_field "exit_code" d;
                        output = str "output" d;
                        log_path = str "log_path" d;
                        duration_ms = int_field "duration_ms" d;
                      })
                    k)
          | Effects.File_read path ->
              Some
                (fun (k : (b, _) continuation) ->
                  answer c ~kind:"file_read"
                    ~req_json:(Effects.file_read_req_json path)
                    ~decode:(fun d ->
                      match Yojson.Safe.Util.member "content" d with
                      | `String s ->
                          if
                            Yojson.Safe.Util.member "content_truncated" d
                            = `Bool true
                          then
                            raise
                              (Unreplayable
                                 {
                                   seq = c.last_seq;
                                   reason =
                                     "file_read content was truncated at \
                                      capture time";
                                 })
                          else s
                      | _ ->
                          raise
                            (Unreplayable
                               {
                                 seq = c.last_seq;
                                 reason =
                                   "journal predates file_read content \
                                    capture";
                               }))
                    k)
          | Effects.File_exists path ->
              Some
                (fun (k : (b, _) continuation) ->
                  answer c ~kind:"file_exists"
                    ~req_json:(Effects.file_exists_req_json path)
                    ~decode:(fun d ->
                      Yojson.Safe.Util.member "exists" d = `Bool true)
                    k)
          | Effects.File_write req ->
              Some
                (fun (k : (b, _) continuation) ->
                  answer c ~kind:"file_write"
                    ~req_json:(Effects.file_write_req_json req)
                    ~decode:(fun _ -> ())
                    k)
          | Effects.Git_commit req ->
              Some
                (fun (k : (b, _) continuation) ->
                  answer c ~kind:"git_commit"
                    ~req_json:(Effects.git_commit_req_json req)
                    ~decode:(fun d -> { Effects.sha = str "sha" d })
                    k)
          | Effects.Judge req ->
              Some
                (fun (k : (b, _) continuation) ->
                  answer c ~kind:"judge"
                    ~req_json:(Effects.judge_req_json req)
                    ~decode:Effects.judge_result_of_json k)
          | Effects.Note (label, data) ->
              Some
                (fun (k : (b, _) continuation) ->
                  match match_note c ~label ~data with
                  | () -> continue k ()
                  | exception e -> discontinue k e)
          | _ -> None);
    }
