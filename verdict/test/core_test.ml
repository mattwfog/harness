open Dispobench_core

let record_json =
  {|{"base_url":"http://localhost/v1","family":"billing","finished_at":"2026-09-01T12:30:00Z","history":[{"content":"Where is my invoice?","role":"user"}],"key":"s-1:baseline:model:0","manifest_ref":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","model":"test-model","nudges":0,"prompt_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rep":0,"result":{"action":"reply","reply":"Here it is.","terminal":true},"scenario_id":"s-1","schema_version":"1","seed":42,"system_prompt":"Be useful.","tool_calls":[{"arguments":{"customer":7},"duration_ms":12,"name":"lookup_invoice","result":{"invoice":"inv-1"},"status":"ok"}],"usage":{"cached":5,"input":20,"output":4},"variant":"baseline","wall_ms":18}|}

let matrix_json =
  {|{"columns":[{"detector_prefixes":["protocol."],"name":"protocol","origin":"portable","tags":["format"]},{"detector_prefixes":["content."],"name":"content","origin":"app","tags":[]}],"name":"support","rows":[{"name":"billing","origin":"app","scenario_labels":["billing"],"tags":["money"]},{"name":"shipping","origin":"app","scenario_labels":["shipping"],"tags":[]}],"schema_version":"1"}|}

let corpus_json =
  {|{"leak_census":0,"metadata":{},"name":"support-v1","scenarios":[{"family":"billing","history":[{"content":"Invoice?","role":"user"}],"metadata":{},"reference":{"reply":"Sure"},"scenario_id":"s-1","system_prompt":""},{"family":"shipping","history":[{"content":"Shipment?","role":"user"}],"metadata":{},"reference":{"reply":"Sure"},"scenario_id":"s-2","system_prompt":""}],"schema_version":"1"}|}

let contains haystack needle =
  let haystack_length = String.length haystack and needle_length = String.length needle in
  let rec search offset =
    offset + needle_length <= haystack_length
    &&
    (String.sub haystack offset needle_length = needle || search (offset + 1))
  in
  needle_length = 0 || search 0

let expect_schema substring operation =
  match operation () with
  | _ -> Alcotest.failf "expected Schema_error containing %S" substring
  | exception Json_util.Schema_error message ->
      Alcotest.(check bool) message true (contains message substring)

let write_bytes path value =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel value)

let test_python_canonical_json () =
  let unicode = Json_util.parse_string ~path:"value" {|{"z":1,"a":"é"}|} in
  Alcotest.(check string) "unicode and sorted keys"
    {|{"a":"é","z":1}|} (Json_util.canonical_json unicode);
  let numbers =
    Json_util.parse_string ~path:"value"
      {|{"small":1e-7,"whole":1.0,"large":1e20,"negative_zero":-0.0}|}
  in
  Alcotest.(check string) "Python float spellings"
    {|{"large":1e+20,"negative_zero":-0.0,"small":1e-07,"whole":1.0}|}
    (Json_util.canonical_json numbers);
  let boundary_numbers =
    Json_util.parse_string ~path:"value"
      {|[1e-5,1e-4,1e15,1e16,1.2345678901234567,1.0000000000000002,2.2250738585072014e-308,5e-324,1.2e20,1.234e-5]|}
  in
  Alcotest.(check string) "CPython shortest-float formatting"
    {|[1e-05,0.0001,1000000000000000.0,1e+16,1.2345678901234567,1.0000000000000002,2.2250738585072014e-308,5e-324,1.2e+20,1.234e-05]|}
    (Json_util.canonical_json boundary_numbers);
  Alcotest.(check string) "Python content_hash"
    "c2985c5ba6f7d2a55e768f92490ca09388e95bc4cccb9fdf11b15f4d42f93e73"
    (Json_util.content_hash (`Assoc [ ("z", `Int 1); ("a", `Int 2) ]))

let test_record_round_trip_and_hash () =
  let record = Record.of_string record_json in
  Alcotest.(check string) "record canonical JSON" record_json (Record.to_string record);
  Alcotest.(check string) "record content hash from Python"
    "08cfe2d674e8011bb9d6d1cb219bc44460abcf513442cd7884b96c38dff959b7"
    (Record.content_hash record);
  Alcotest.(check string) "key" "s-1:baseline:model:0" record.key;
  Alcotest.(check int) "cached usage" 5 record.usage.cached;
  Alcotest.(check int) "tool count" 1 (List.length record.tool_calls)

let test_record_validation () =
  expect_schema "duplicate object key"
    (fun () -> Record.of_string {|{"key":"one","key":"two"}|});
  let json = Yojson.Safe.from_string record_json in
  let negative_rep =
    match json with
    | `Assoc fields ->
        `Assoc
          (List.map
             (fun (key, value) -> if key = "rep" then (key, `Int (-1)) else (key, value))
             fields)
    | _ -> assert false
  in
  expect_schema "record.rep: must be at least 0"
    (fun () -> Record.of_yojson negative_rep)

let test_record_jsonl () =
  let path = Filename.temp_file "dispobench-records-" ".jsonl" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove path with Sys_error _ -> ())
    (fun () ->
      write_bytes path ("\n" ^ record_json ^ "\n\n" ^ record_json ^ "\n");
      Alcotest.(check int) "nonblank records" 2 (Record.validate_jsonl path);
      write_bytes path "\n\t\n";
      expect_schema "record JSONL is empty" (fun () -> Record.validate_jsonl path))

let test_matrix_round_trip_hash_and_mece () =
  let matrix = Matrix.of_string matrix_json in
  Alcotest.(check string) "matrix canonical JSON" matrix_json (Matrix.to_string matrix);
  Alcotest.(check string) "matrix content hash from Python"
    "79855ecaa0c3bf581259ce662d7aa154cb15bc8de488916f9f90115ef00bf71b"
    (Matrix.content_hash matrix);
  let labels = Matrix.corpus_labels_of_string corpus_json in
  Alcotest.(check (list string)) "sorted corpus families" [ "billing"; "shipping" ] labels;
  ignore
    (Matrix.validate matrix ~corpus_labels:labels
       ~detector_names:[ "protocol.no_terminal"; "content.money_not_in_context" ])

let test_matrix_rejects_non_mece () =
  let row : Matrix.row =
    { name = "billing"; scenario_labels = [ "billing" ]; tags = []; origin = "portable" }
  in
  let broad : Matrix.column =
    { name = "broad"; detector_prefixes = [ "protocol." ]; tags = []; origin = "portable" }
  in
  let narrow : Matrix.column =
    {
      name = "narrow";
      detector_prefixes = [ "protocol.reply." ];
      tags = [];
      origin = "portable";
    }
  in
  let overlapping : Matrix.t =
    { name = "bad"; rows = [ row ]; columns = [ broad; narrow ] }
  in
  expect_schema "prefixes overlap" (fun () ->
      Matrix.validate overlapping ~corpus_labels:[ "billing" ]
        ~detector_names:[ "protocol.reply.empty" ]);
  let valid : Matrix.t = { name = "one"; rows = [ row ]; columns = [ broad ] } in
  expect_schema "detectors without a column" (fun () ->
      Matrix.validate valid ~corpus_labels:[ "billing" ]
        ~detector_names:[ "content.money" ]);
  expect_schema "scenario labels without a row" (fun () ->
      Matrix.validate valid ~corpus_labels:[ "billing"; "shipping" ]
        ~detector_names:[ "protocol.empty" ])

let with_lock_tree operation =
  let placeholder = Filename.temp_file "dispobench-lock-" "" in
  Sys.remove placeholder;
  Unix.mkdir placeholder 0o700;
  let nested = Filename.concat placeholder "nested" in
  Unix.mkdir nested 0o700;
  let first = Filename.concat placeholder "a.txt" in
  let second = Filename.concat nested "b.txt" in
  let lock_path = Filename.concat placeholder "shaping.lock" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) [ lock_path; first; second ];
      (try Unix.rmdir nested with Unix.Unix_error _ -> ());
      (try Unix.rmdir placeholder with Unix.Unix_error _ -> ()))
    (fun () -> operation placeholder first second lock_path)

let test_lock_python_parity_and_compare () =
  with_lock_tree (fun root first second lock_path ->
      write_bytes first "alpha\n";
      write_bytes second "beta\n";
      let lock =
        Lock.create ~files:[ "nested/b.txt"; "a.txt" ] ~run:"run-001"
          ~date:"2026-09-01" ~root
      in
      Alcotest.(check string) "declared-set hash from Python"
        "edfbd44d852b8d507f3a70f333ccf90c1d5b17f1001fb036f99abb599d189577"
        lock.sha256;
      Alcotest.(check (list string)) "files sorted" [ "a.txt"; "nested/b.txt" ] lock.files;
      let expected_json =
        {|{"date":"2026-09-01","files":["a.txt","nested/b.txt"],"run":"run-001","schema_version":"1","sha256":"edfbd44d852b8d507f3a70f333ccf90c1d5b17f1001fb036f99abb599d189577"}|}
      in
      Alcotest.(check string) "lock JSON shape" expected_json (Lock.to_string lock);
      Lock.write lock lock_path;
      Alcotest.(check string) "atomic write has newline" (expected_json ^ "\n")
        (Json_util.read_file lock_path);
      Alcotest.(check string) "read round trip" expected_json
        (Lock.read lock_path |> Lock.to_string);
      Alcotest.(check bool) "unchanged surface passes" true (Lock.compare lock ~root);
      write_bytes second "changed\n";
      Alcotest.(check bool) "changed surface fails" false (Lock.compare lock ~root);
      Sys.remove second;
      Alcotest.(check bool) "missing surface fails" false (Lock.compare lock ~root))

let test_lock_validation () =
  expect_schema "must be sorted" (fun () ->
      Lock.of_string
        {|{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","files":["z.txt","a.txt"],"run":"run","date":"2026-09-01"}|});
  expect_schema "ISO 8601 date" (fun () ->
      Lock.of_string
        {|{"sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","files":["a.txt"],"run":"run","date":"September 1"}|})

let () =
  Alcotest.run "dispobench-core"
    [
      ( "record",
        [
          Alcotest.test_case "Python canonical JSON" `Quick test_python_canonical_json;
          Alcotest.test_case "round trip and hash" `Quick test_record_round_trip_and_hash;
          Alcotest.test_case "strict validation" `Quick test_record_validation;
          Alcotest.test_case "JSONL" `Quick test_record_jsonl;
        ] );
      ( "matrix",
        [
          Alcotest.test_case "round trip, hash, and MECE" `Quick
            test_matrix_round_trip_hash_and_mece;
          Alcotest.test_case "non-MECE rejection" `Quick test_matrix_rejects_non_mece;
        ] );
      ( "lock",
        [
          Alcotest.test_case "Python parity and compare" `Quick
            test_lock_python_parity_and_compare;
          Alcotest.test_case "strict validation" `Quick test_lock_validation;
        ] );
    ]
