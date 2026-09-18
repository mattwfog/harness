(* Append-only JSONL journal: one line per effect request/result/denial/note,
   flushed the moment it is written (save-everything is structural — the
   capture handler cannot resume a continuation without journaling first).
   Request/result lines pair via ref_seq. *)

type t = { chan : out_channel; path : string; mutable seq : int }

let open_journal ~dir ~run_id =
  let () =
    if not (Sys.file_exists dir) then Unix.mkdir dir 0o755
  in
  let path = Filename.concat dir (run_id ^ ".jsonl") in
  let chan =
    open_out_gen [ Open_append; Open_creat; Open_wronly ] 0o644 path
  in
  { chan; path; seq = 0 }

let close t = close_out t.chan

let now_iso () =
  let t = Unix.gettimeofday () in
  let tm = Unix.gmtime t in
  Printf.sprintf "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ" (tm.Unix.tm_year + 1900)
    (tm.Unix.tm_mon + 1) tm.Unix.tm_mday tm.Unix.tm_hour tm.Unix.tm_min
    tm.Unix.tm_sec
    (int_of_float ((t -. Float.of_int (int_of_float t)) *. 1000.))

let emit t ~(phase : string) ~(kind : string) ?(ref_seq : int option)
    (data : Yojson.Safe.t) : int =
  t.seq <- t.seq + 1;
  let base =
    [
      ("seq", `Int t.seq);
      ("ts", `String (now_iso ()));
      ("phase", `String phase);
      ("kind", `String kind);
      ("data", data);
    ]
  in
  let fields =
    match ref_seq with
    | Some r -> base @ [ ("ref_seq", `Int r) ]
    | None -> base
  in
  output_string t.chan (Yojson.Safe.to_string (`Assoc fields));
  output_char t.chan '\n';
  flush t.chan;
  t.seq

let request t ~kind data = emit t ~phase:"request" ~kind data
let result t ~kind ~ref_seq data = emit t ~phase:"result" ~kind ~ref_seq data

let denied t ~kind ~ref_seq ~reason =
  ignore
    (emit t ~phase:"denied" ~kind ~ref_seq (`Assoc [ ("reason", `String reason) ]))

let note t ~label data =
  ignore (emit t ~phase:"note" ~kind:label data)

(* Read a journal back as a list of JSON lines (replay's substrate, M2). *)
let read_lines path : Yojson.Safe.t list =
  let ic = open_in path in
  let rec go acc =
    match input_line ic with
    | line -> go (Yojson.Safe.from_string line :: acc)
    | exception End_of_file ->
        close_in ic;
        List.rev acc
  in
  go []
