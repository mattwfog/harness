open Dispobench_core

let tool_call ?(arguments = `Assoc []) ?(result = `Assoc []) () : Record.tool_call =
  { name = "lookup"; arguments; result; status = "ok"; duration_ms = 1 }

let record ?(key = "record") ?(family = "row") ?(terminal = true) ?reply
    ?(system_prompt = "") ?(history = []) ?(tool_calls = []) () : Record.t =
  {
    key;
    scenario_id = key;
    family;
    rep = 0;
    variant = "baseline";
    model = "fixture";
    base_url = "echo://fixture";
    prompt_hash = String.make 64 'a';
    system_prompt;
    history;
    tool_calls;
    result = { terminal; action = None; reply };
    usage = { input = 0; cached = 0; output = 0 };
    nudges = 0;
    seed = 0;
    wall_ms = 0;
    finished_at = "1970-01-01T00:00:00Z";
    manifest_ref = "fixture";
  }

let check_verdict label expected actual =
  Alcotest.(check (option bool)) label expected actual

let test_protocol_no_terminal () =
  check_verdict "terminal" (Some false)
    (Detectors.protocol_no_terminal (record ~terminal:true ()));
  check_verdict "not terminal" (Some true)
    (Detectors.protocol_no_terminal (record ~terminal:false ()))

let test_empty_reply () =
  check_verdict "empty" (Some true) (Detectors.empty_reply (record ~reply:"" ()));
  check_verdict "whitespace" (Some true)
    (Detectors.empty_reply (record ~reply:" \n\t" ()));
  check_verdict "Unicode whitespace" (Some true)
    (Detectors.empty_reply (record ~reply:"\194\160\226\128\131" ()));
  check_verdict "content" (Some false) (Detectors.empty_reply (record ~reply:"ok" ()));
  check_verdict "not applicable" None (Detectors.empty_reply (record ()))

let test_reply_over_cap () =
  let detect = Detectors.reply_over_cap 3 in
  check_verdict "boundary" (Some false) (detect (record ~reply:"abc" ()));
  check_verdict "over" (Some true) (detect (record ~reply:"abcd" ()));
  check_verdict "unicode code points" (Some false) (detect (record ~reply:"ééé" ()));
  check_verdict "not applicable" None (detect (record ()));
  Alcotest.check_raises "negative cap" (Invalid_argument "max_length must be non-negative")
    (fun () ->
      let (_ : Record.t -> Detectors.verdict) = Detectors.reply_over_cap (-1) in
      ())

let test_markdown_in_reply () =
  let markdown =
    [
      "# Heading";
      "- item";
      "1. item";
      "> quote";
      "Use `code` now";
      "This is **important**.";
      "This is *emphasized*.";
      "See [the docs](https://example.test).";
      "```python\npass\n```";
      "Name | Value\n--- | ---\nAda | 3";
      "---";
    ]
  in
  List.iter
    (fun reply ->
      check_verdict reply (Some true)
        (Detectors.markdown_in_reply (record ~reply ())))
    markdown;
  check_verdict "plain" (Some false)
    (Detectors.markdown_in_reply (record ~reply:"Plain text - with punctuation." ()));
  check_verdict "not applicable" None (Detectors.markdown_in_reply (record ()))

let test_placeholder_echoed () =
  let detect = Detectors.placeholder_echoed [ {|\{\{customer_name\}\}|}; {|<ID>|} ] in
  check_verdict "case insensitive" (Some true)
    (detect (record ~reply:"Hello {{CUSTOMER_NAME}}" ()));
  check_verdict "second expression" (Some true)
    (detect (record ~reply:"Reference <ID>" ()));
  check_verdict "clean" (Some false) (detect (record ~reply:"Hello Ada" ()));
  check_verdict "not applicable" None (detect (record ()))

let test_money_not_in_context () =
  let grounded =
    record ~reply:"The totals are $1,000.00, $25, $30, and $40."
      ~system_prompt:"The approved limit is $1000."
      ~history:[ `Assoc [ ("role", `String "user"); ("content", `String "I mentioned $25.00 and $30.0.") ] ]
      ~tool_calls:
        [
          tool_call ~arguments:(`Assoc [ ("untrusted", `String "$999") ])
            ~result:(`Assoc [ ("lines", `List [ `String "Approved: $40.00" ]) ]) ();
        ]
      ()
  in
  check_verdict "equivalent decimal forms" (Some false)
    (Detectors.money_not_in_context grounded);
  check_verdict "arguments excluded" (Some true)
    (Detectors.money_not_in_context
       { grounded with result = { grounded.result with reply = Some "The fee is $999." } });
  check_verdict "no amounts" None
    (Detectors.money_not_in_context (record ~reply:"No amount here." ()));
  check_verdict "ungrouped trailing comma" (Some false)
    (Detectors.money_not_in_context
       (record ~reply:"The fee is $123,abc" ~system_prompt:"Approved: $123" ()));
  check_verdict "malformed grouping" None
    (Detectors.money_not_in_context (record ~reply:"The fee is $1,00" ()));
  check_verdict "not applicable" None (Detectors.money_not_in_context (record ()))

let test_unsanctioned_balance () =
  let detect =
    Detectors.unsanctioned_balance ~customer_roles:[ "client" ]
      {|^VERIFIED BALANCE:|}
  in
  let sanctioned =
    record ~reply:"Your balance is $1000 and the amount due is $25.00."
      ~history:[ `Assoc [ ("role", `String "client"); ("content", `String "I believe I owe $25.") ] ]
      ~tool_calls:
        [ tool_call ~result:(`String "noise: $9000\nVERIFIED BALANCE: $1,000.00") () ]
      ()
  in
  check_verdict "tool and customer sanctioned" (Some false) (detect sanctioned);
  check_verdict "unsanctioned" (Some true)
    (detect
       { sanctioned with result = { sanctioned.result with reply = Some "Your balance is $9,000." } });
  let nested =
    record ~reply:"Your balance is $81."
      ~history:
        [
          `Assoc
            [
              ("role", `String "client");
              ("parts", `List [ `Assoc [ ("text", `String "I have $81.") ] ]);
            ];
        ]
      ()
  in
  check_verdict "nested customer content" (Some false) (detect nested);
  let custom =
    Detectors.unsanctioned_balance ~balance_line_regex:{|\bcredit limit\b|}
      ~sanctioned_case_insensitive:true {|^approved:|}
  in
  check_verdict "custom regex" (Some false)
    (custom
       (record ~reply:"Your credit limit is $70."
          ~tool_calls:[ tool_call ~result:(`String "APPROVED: $70.00") () ] ()));
  check_verdict "conditional" None (custom (record ~reply:"A widget costs $70." ()))

let test_wilson () =
  let low, high = Wilson.interval ~fires:1 ~n:2 in
  Alcotest.(check (float 1e-15)) "low" 0.09453120573423074 low;
  Alcotest.(check (float 1e-15)) "high" 0.9054687942657693 high;
  Alcotest.check_raises "positive n" (Invalid_argument "n must be positive") (fun () ->
      ignore (Wilson.interval ~fires:0 ~n:0));
  Alcotest.check_raises "fires range" (Invalid_argument "fires must be in [0, n]")
    (fun () -> ignore (Wilson.interval ~fires:3 ~n:2))

let write_file path payload =
  let channel = open_out_bin path in
  Fun.protect
    ~finally:(fun () -> close_out_noerr channel)
    (fun () -> output_string channel payload)

let read_file = Json_util.read_file

let rec find_repo_root path =
  let marker = Filename.concat path "python/src/dispobench/report/report.py" in
  if Sys.file_exists marker then path
  else
    let parent = Filename.dirname path in
    if parent = path then Alcotest.fail "could not locate repository root"
    else find_repo_root parent

let with_temp_files operation =
  let paths =
    List.init 5 (fun _ -> Filename.temp_file "dispobench-parity-" ".json")
  in
  Fun.protect
    ~finally:(fun () ->
      List.iter (fun path -> try Sys.remove path with Sys_error _ -> ()) paths)
    (fun () -> operation paths)

let python_report repo_root records_path verdicts_path markdown_path stdout_path stderr_path =
  let script =
    {|import json, sys
from dispobench.report import build_report, render_json, render_markdown
with open(sys.argv[1], encoding="utf-8") as handle:
    records = [json.loads(line) for line in handle if line.strip()]
with open(sys.argv[2], encoding="utf-8") as handle:
    verdicts = json.load(handle)["detector_results"]
report = build_report(
    records,
    verdicts,
    rows=["support", "empty", "sales"],
    column_groups={
        "protocol": ["protocol.no_terminal"],
        "form": ["form.markdown_in_reply", "form.empty_reply"],
        "grounding": ["grounding.money_not_in_context"],
    },
    worst_examples=2,
)
with open(sys.argv[3], "w", encoding="utf-8", newline="") as handle:
    handle.write(render_markdown(report))
sys.stdout.write(render_json(report))|}
  in
  let env =
    Unix.environment () |> Array.to_list
    |> List.filter (fun value -> not (String.starts_with ~prefix:"PYTHONPATH=" value))
    |> fun values -> Array.of_list (("PYTHONPATH=" ^ Filename.concat repo_root "python/src") :: values)
  in
  let stdout_fd = Unix.openfile stdout_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let stderr_fd = Unix.openfile stderr_path [ Unix.O_WRONLY; Unix.O_TRUNC ] 0o600 in
  let old_cwd = Sys.getcwd () in
  Fun.protect
    ~finally:(fun () ->
      Unix.chdir old_cwd;
      Unix.close stdout_fd;
      Unix.close stderr_fd)
    (fun () ->
      Unix.chdir repo_root;
      let argv = [| "python3"; "-c"; script; records_path; verdicts_path; markdown_path |] in
      let pid = Unix.create_process_env "python3" argv env Unix.stdin stdout_fd stderr_fd in
      match snd (Unix.waitpid [] pid) with
      | Unix.WEXITED 0 -> ()
      | Unix.WEXITED code ->
          Alcotest.failf "Python report oracle exited %d: %s" code (read_file stderr_path)
      | Unix.WSIGNALED signal | Unix.WSTOPPED signal ->
          Alcotest.failf "Python report oracle stopped by signal %d" signal)

let rec check_json_equal path expected actual =
  match (expected, actual) with
  | (`Int left, `Float right) | (`Float right, `Int left) ->
      Alcotest.(check (float 1e-9)) path (float_of_int left) right
  | `Float left, `Float right -> Alcotest.(check (float 1e-9)) path left right
  | `Assoc left, `Assoc right ->
      let left = List.sort compare left and right = List.sort compare right in
      Alcotest.(check (list string)) (path ^ " keys") (List.map fst left) (List.map fst right);
      List.iter2
        (fun (key, left) (_, right) -> check_json_equal (path ^ "." ^ key) left right)
        left right
  | `List left, `List right ->
      Alcotest.(check int) (path ^ " length") (List.length left) (List.length right);
      List.iteri
        (fun index left -> check_json_equal (Printf.sprintf "%s[%d]" path index) left (List.nth right index))
        left
  | left, right ->
      Alcotest.(check string) path (Yojson.Safe.to_string left) (Yojson.Safe.to_string right)

let parity_detectors =
  [
    Detectors.protocol_no_terminal_detector ~name:"protocol.no_terminal" ();
    Detectors.empty_reply_detector ~name:"form.empty_reply" ();
    Detectors.markdown_in_reply_detector ~name:"form.markdown_in_reply" ();
    Detectors.money_not_in_context_detector ~name:"grounding.money_not_in_context" ();
  ]

let parity_records () =
  [
    record ~key:"sales-1" ~family:"sales" ~terminal:false ~reply:"" ();
    record ~key:"support-1" ~family:"support" ();
    record ~key:"sales-2" ~family:"sales" ~reply:"# Total: $10"
      ~tool_calls:[ tool_call ~result:(`String "Total: $10.00") () ] ();
    record ~key:"sales-3" ~family:"sales" ~reply:"The fee is $999." ();
  ]

let parity_groups =
  [
    Report.{ name = "protocol"; detectors = [ "protocol.no_terminal" ] };
    Report.{
      name = "form";
      detectors = [ "form.markdown_in_reply"; "form.empty_reply" ];
    };
    Report.{ name = "grounding"; detectors = [ "grounding.money_not_in_context" ] };
  ]

let test_python_report_parity () =
  with_temp_files (function
    | [ records_path; verdicts_path; markdown_path; stdout_path; stderr_path ] ->
        let records = parity_records () in
        let records_jsonl =
          records |> List.map Record.to_string |> String.concat "\n" |> fun value -> value ^ "\n"
        in
        let results = Detectors.run parity_detectors records in
        let verdicts_json =
          Detectors.results_to_yojson parity_detectors results |> Report.render_yojson
        in
        write_file records_path records_jsonl;
        write_file verdicts_path verdicts_json;
        let report =
          Report.build ~worst_examples:2
            ~records:(List.map (fun (value : Record.t) -> Report.{ key = value.key; family = value.family }) records)
            ~detector_results:results ~rows:[ "support"; "empty"; "sales" ]
            ~column_groups:parity_groups ()
        in
        let ocaml_json = Report.render_json report in
        python_report (find_repo_root (Sys.getcwd ())) records_path verdicts_path markdown_path
          stdout_path stderr_path;
        let python_json = read_file stdout_path in
        let expected = Yojson.Safe.from_string python_json in
        let actual = Yojson.Safe.from_string ocaml_json in
        check_json_equal "$" expected actual;
        Alcotest.(check string) "byte-identical JSON emitter" python_json ocaml_json;
        Alcotest.(check string) "byte-identical Markdown emitter" (read_file markdown_path)
          (Report.render_markdown report);
        let reordered =
          Report.build ~worst_examples:2
            ~records:
              (List.rev records
              |> List.map (fun (value : Record.t) -> Report.{ key = value.key; family = value.family }))
            ~detector_results:(List.rev results) ~rows:[ "sales"; "empty"; "support" ]
            ~column_groups:(List.rev parity_groups) ()
        in
        Alcotest.(check string) "JSON deterministic" ocaml_json (Report.render_json reordered);
        Alcotest.(check string) "Markdown deterministic" (Report.render_markdown report)
          (Report.render_markdown reordered)
    | _ -> assert false)

let () =
  Alcotest.run "dispobench-core-rung3"
    [
      ( "detectors",
        [
          Alcotest.test_case "protocol_no_terminal" `Quick test_protocol_no_terminal;
          Alcotest.test_case "empty_reply" `Quick test_empty_reply;
          Alcotest.test_case "reply_over_cap" `Quick test_reply_over_cap;
          Alcotest.test_case "markdown_in_reply" `Quick test_markdown_in_reply;
          Alcotest.test_case "placeholder_echoed" `Quick test_placeholder_echoed;
          Alcotest.test_case "money_not_in_context" `Quick test_money_not_in_context;
          Alcotest.test_case "unsanctioned_balance" `Quick test_unsanctioned_balance;
        ] );
      ("wilson", [ Alcotest.test_case "Python known values" `Quick test_wilson ]);
      ( "report",
        [ Alcotest.test_case "Python semantic and byte parity" `Quick test_python_report_parity ] );
    ]
