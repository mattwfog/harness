open Dispobench_core

let record_json =
  {|{"base_url":"echo://local","family":"alpha","finished_at":"1970-01-01T00:00:00Z","history":[{"content":"Alpha","role":"user"}],"key":"alpha-1:r0:fixture","manifest_ref":"fixture","model":"echo","nudges":0,"prompt_hash":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","rep":0,"result":{"action":null,"reply":"Alpha","terminal":true},"scenario_id":"alpha-1","schema_version":"1","seed":0,"system_prompt":"","tool_calls":[],"usage":{"cached":0,"input":0,"output":0},"variant":"baseline","wall_ms":0}|}

let corpus_json =
  {|{"leak_census":0,"metadata":{},"name":"cli-fixture","scenarios":[{"family":"alpha","history":[{"content":"Alpha","role":"user"}],"metadata":{},"reference":{"reply":"Alpha"},"scenario_id":"alpha-1","system_prompt":""}],"schema_version":"1"}|}

let matrix_json =
  {|{"columns":[{"detector_prefixes":["protocol."],"name":"protocol","origin":"portable","tags":[]}],"name":"cli-fixture","rows":[{"name":"alpha","origin":"portable","scenario_labels":["alpha"],"tags":[]}],"schema_version":"1"}|}

let write_file path payload =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel payload)

let read_file = Json_util.read_file

let run executable arguments =
  let stdout_path = Filename.temp_file "dispobench-cli-out-" "" in
  let stderr_path = Filename.temp_file "dispobench-cli-err-" "" in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ())
        [ stdout_path; stderr_path ])
    (fun () ->
      let stdout_fd = Unix.openfile stdout_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
      let argv = Array.of_list (executable :: arguments) in
      let pid =
        try Unix.create_process executable argv Unix.stdin stdout_fd stderr_fd
        with error ->
          Unix.close stdout_fd;
          Unix.close stderr_fd;
          raise error
      in
      Unix.close stdout_fd;
      Unix.close stderr_fd;
      let _, status = Unix.waitpid [] pid in
      let code =
        match status with
        | Unix.WEXITED code -> code
        | Unix.WSIGNALED signal | Unix.WSTOPPED signal -> 128 + signal
      in
      (code, read_file stdout_path, read_file stderr_path))

let with_tree operation =
  let root = Filename.temp_file "dispobench-cli-" "" in
  Sys.remove root;
  Unix.mkdir root 0o700;
  let paths =
    List.map (Filename.concat root)
      [
        "record.json";
        "records.jsonl";
        "corpus.json";
        "matrix.json";
        "prompt.txt";
        "shaping.lock";
        "verdicts.json";
        "report.json";
      ]
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) paths;
      try Unix.rmdir root with Unix.Unix_error _ -> ())
    (fun () -> operation root paths)

let test_commands () =
  with_tree (fun root paths ->
      let record, records, corpus, matrix, prompt, lock_path, verdicts, report =
        match paths with
        | [ record; records; corpus; matrix; prompt; lock_path; verdicts; report ] ->
            (record, records, corpus, matrix, prompt, lock_path, verdicts, report)
        | _ -> assert false
      in
      write_file record (record_json ^ "\n");
      write_file records (record_json ^ "\n");
      write_file corpus (corpus_json ^ "\n");
      write_file matrix (matrix_json ^ "\n");
      write_file prompt "original";
      let lock =
        Lock.create ~files:[ "prompt.txt" ] ~run:"run-1" ~date:"2026-09-01" ~root
      in
      Lock.write lock lock_path;
      let executable = "../bin/main.exe" in
      let code, stdout, stderr = run executable [ "validate"; corpus; matrix ] in
      Alcotest.(check int) "validate exit" 0 code;
      Alcotest.(check string) "validate stderr" "" stderr;
      Alcotest.(check bool) "corpus diagnostic" true
        (String.starts_with ~prefix:"VALID corpus" stdout);
      let code, stdout, stderr =
        run executable [ "validate"; records; "--kind"; "records" ]
      in
      Alcotest.(check int) "records exit" 0 code;
      Alcotest.(check string) "records stderr" "" stderr;
      Alcotest.(check bool) "record count" true
        (String.starts_with ~prefix:"VALID records (1)" stdout);
      let code, stdout, stderr =
        run executable
          [ "matrix"; matrix; corpus; "--detector"; "protocol.no_terminal" ]
      in
      Alcotest.(check int) "matrix exit" 0 code;
      Alcotest.(check string) "matrix stderr" "" stderr;
      Alcotest.(check string) "matrix output" (matrix_json ^ "\n") stdout;
      let code, stdout, stderr =
        run executable [ "gate"; lock_path; "--root"; root ]
      in
      Alcotest.(check int) "gate pass exit" 0 code;
      Alcotest.(check string) "gate pass stderr" "" stderr;
      Alcotest.(check bool) "gate pass output" true
        (String.starts_with ~prefix:"PASS " stdout);
      write_file prompt "changed";
      let code, stdout, stderr =
        run executable [ "gate"; lock_path; "--root"; root ]
      in
      Alcotest.(check int) "gate fail exit" 1 code;
      Alcotest.(check string) "gate fail stdout" "" stdout;
      Alcotest.(check bool) "gate fail output" true
        (String.starts_with ~prefix:"FAIL " stderr);
      let code, stdout, stderr =
        run executable
          [
            "detect";
            records;
            "--detector";
            "protocol.no_terminal=protocol_no_terminal";
            "--output";
            verdicts;
          ]
      in
      Alcotest.(check int) "detect exit" 0 code;
      Alcotest.(check string) "detect stdout" "" stdout;
      Alcotest.(check string) "detect stderr" "" stderr;
      let verdict_json = Json_util.parse_file ~path_label:"verdicts" verdicts in
      let _, names = Report.detached_results_of_yojson verdict_json in
      Alcotest.(check (list string)) "detector alias" [ "protocol.no_terminal" ] names;
      let code, stdout, stderr =
        run executable
          [
            "report";
            records;
            matrix;
            "--verdicts";
            verdicts;
            "--format";
            "json";
            "--output";
            report;
          ]
      in
      Alcotest.(check int) "report exit" 0 code;
      Alcotest.(check string) "report stdout" "" stdout;
      Alcotest.(check string) "report stderr" "" stderr;
      let report_json = Json_util.parse_file ~path_label:"report" report in
      let fields = Json_util.require_object "report" report_json in
      Alcotest.(check int) "report record count" 1
        (Json_util.require_int "record_count" (Json_util.required_member "report" fields "record_count"));
      ignore record)

let () =
  Alcotest.run "dispobench-core-cli"
    [ ("commands", [ Alcotest.test_case "validate, matrix, gate" `Quick test_commands ]) ]
