open Cmdliner
open Dispobench_core

let error_message = function
  | Json_util.Schema_error message -> message
  | Sys_error message -> message
  | Invalid_argument message -> message
  | Unix.Unix_error (error, operation, argument) ->
      let detail = Unix.error_message error in
      if argument = "" then Printf.sprintf "%s: %s" operation detail
      else Printf.sprintf "%s %s: %s" operation argument detail
  | error -> Printexc.to_string error

let protect operation =
  try operation () with error ->
    prerr_endline ("dispobench-core: " ^ error_message error);
    2

let has_fields fields required =
  List.for_all (fun key -> List.mem_assoc key fields) required

type artifact_kind = Auto | Corpus | Matrix | Record | Records | Manifest | Lock

let kind_converter =
  Arg.enum
    [
      ("auto", Auto);
      ("corpus", Corpus);
      ("matrix", Matrix);
      ("record", Record);
      ("records", Records);
      ("manifest", Manifest);
      ("lock", Lock);
    ]

let infer_kind path value =
  match value with
  | `List _ -> Records
  | `Assoc fields when has_fields fields [ "scenarios"; "leak_census" ] -> Corpus
  | `Assoc fields when has_fields fields [ "rows"; "columns" ] -> Matrix
  | `Assoc fields when has_fields fields [ "key"; "scenario_id"; "result"; "usage" ] -> Record
  | `Assoc fields
    when has_fields fields [ "run_id"; "corpus_hash"; "matrix_hash"; "shaping_hash" ] ->
      Manifest
  | `Assoc fields when has_fields fields [ "sha256"; "files"; "run"; "date" ] -> Lock
  | _ -> raise (Invalid_argument ("cannot infer dispobench artifact type for " ^ path))

let optional_string_list fields name path =
  match Json_util.member fields name with
  | None -> []
  | Some value -> Json_util.require_string_list path value

let validate_manifest value =
  let open Json_util in
  validate_json ~root:"manifest" value;
  let fields = require_object "manifest" value in
  let required =
    [
      "run_id";
      "created_at";
      "corpus_hash";
      "matrix_hash";
      "shaping_hash";
      "seed";
      "reps";
      "variants";
      "models";
    ]
  in
  require_exact_keys ~required
    ~optional:[ "schema_version"; "stand_ins"; "contamination_risks"; "metadata" ]
    "manifest" fields;
  let version =
    match member fields "schema_version" with
    | None -> Record.schema_version
    | Some value -> require_string "manifest.schema_version" value
  in
  if version <> Record.schema_version then
    fail "manifest.schema_version"
      (Printf.sprintf "unsupported version %S; expected %S" version Record.schema_version);
  ignore (require_string "manifest.run_id" (required_member "manifest" fields "run_id"));
  ignore
    (require_datetime "manifest.created_at" (required_member "manifest" fields "created_at"));
  List.iter
    (fun name ->
      ignore
        (require_sha256 ("manifest." ^ name) (required_member "manifest" fields name)))
    [ "corpus_hash"; "matrix_hash"; "shaping_hash" ];
  ignore (require_int "manifest.seed" (required_member "manifest" fields "seed"));
  ignore (require_int ~minimum:1 "manifest.reps" (required_member "manifest" fields "reps"));
  ignore
    (require_string_list ~nonempty:true "manifest.variants"
       (required_member "manifest" fields "variants"));
  let models = require_array "manifest.models" (required_member "manifest" fields "models") in
  if models = [] then fail "manifest.models" "must not be empty";
  let identities =
    List.map
      (fun value ->
        let model_fields = require_object "model_endpoint" value in
        require_exact_keys ~required:[ "model"; "base_url" ]
          ~optional:[ "provider"; "metadata" ] "model_endpoint" model_fields;
        let model =
          require_string "model_endpoint.model" (required_member "model_endpoint" model_fields "model")
        in
        let base_url =
          require_string ~nonempty:false "model_endpoint.base_url"
            (required_member "model_endpoint" model_fields "base_url")
        in
        let provider =
          match member model_fields "provider" with
          | None -> "custom"
          | Some value -> require_string "model_endpoint.provider" value
        in
        (match member model_fields "metadata" with
        | None -> ()
        | Some value -> ignore (require_object "model_endpoint.metadata" value));
        (provider, base_url, model))
      models
  in
  if List.length identities <> List.length (List.sort_uniq compare identities) then
    fail "manifest.models" "endpoints must be unique";
  ignore (optional_string_list fields "stand_ins" "manifest.stand_ins");
  ignore (optional_string_list fields "contamination_risks" "manifest.contamination_risks");
  match member fields "metadata" with
  | None -> ()
  | Some value -> ignore (require_object "manifest.metadata" value)

let validate_artifact kind path ?corpus ?(detectors = []) () =
  let inferred_value, actual_kind =
    match kind with
    | Auto ->
        if String.lowercase_ascii (Filename.extension path) = ".jsonl" then (None, Records)
        else
          let value = Json_util.parse_file ~path_label:"json" path in
          (Some value, infer_kind path value)
    | selected -> (None, selected)
  in
  let parsed label =
    match inferred_value with
    | Some value -> value
    | None -> Json_util.parse_file ~path_label:label path
  in
  match actual_kind with
  | Corpus ->
      ignore (Matrix.corpus_labels_of_yojson (parsed "corpus"));
      "corpus"
  | Matrix ->
      let matrix = Matrix.of_yojson (parsed "matrix") in
      (match corpus with
      | None -> ()
      | Some corpus_path ->
          let labels = Matrix.corpus_labels_of_file corpus_path in
          ignore (Matrix.validate matrix ~corpus_labels:labels ~detector_names:detectors));
      "matrix"
  | Record ->
      ignore (Record.of_yojson (parsed "record"));
      "record"
  | Records -> Printf.sprintf "records (%d)" (Record.validate_jsonl path)
  | Manifest ->
      validate_manifest (parsed "manifest");
      "manifest"
  | Lock ->
      ignore (Lock.of_yojson (parsed "shaping_lock"));
      "lock"
  | Auto -> assert false

let validate_command paths kind corpus detectors =
  protect (fun () ->
      if paths = [] then raise (Invalid_argument "at least one path is required");
      if Option.is_some corpus && List.length paths <> 1 then
        raise
          (Invalid_argument "--corpus matrix cross-validation accepts exactly one path");
      if Option.is_some corpus <> (detectors <> []) then
        raise
          (Invalid_argument "matrix cross-validation requires both --corpus and detectors");
      List.iter
        (fun path ->
          let detail = validate_artifact kind path ?corpus ~detectors () in
          Printf.printf "VALID %s %s\n" detail path)
        paths;
      0)

let matrix_command matrix_path corpus_path detectors =
  protect (fun () ->
      let matrix = Matrix.of_file matrix_path in
      let labels = Matrix.corpus_labels_of_file corpus_path in
      ignore (Matrix.validate matrix ~corpus_labels:labels ~detector_names:detectors);
      print_endline (Matrix.to_string matrix);
      0)

let gate_command lock_path root =
  protect (fun () ->
      let shaping_lock = Lock.read lock_path in
      if Lock.compare shaping_lock ~root then (
        Printf.printf "PASS %s: shaping surface matches %s\n" lock_path shaping_lock.sha256;
        0)
      else (
        Printf.eprintf "FAIL %s: shaping surface changed or a declared file is missing\n" lock_path;
        1))

let rec make_directory path =
  if path = "" || path = "." || Sys.file_exists path then ()
  else (
    make_directory (Filename.dirname path);
    Unix.mkdir path 0o755)

let write_text path payload =
  let directory = Filename.dirname path in
  make_directory directory;
  let temporary = Filename.temp_file ~temp_dir:directory ("." ^ Filename.basename path ^ ".") "" in
  Fun.protect
    ~finally:(fun () -> try Sys.remove temporary with Sys_error _ -> ())
    (fun () ->
      let channel = open_out_bin temporary in
      Fun.protect
        ~finally:(fun () -> close_out_noerr channel)
        (fun () -> output_string channel payload);
      Unix.rename temporary path)

let split_detector_spec spec =
  match String.index_opt spec '=' with
  | None -> (spec, spec)
  | Some index ->
      let output_name = String.sub spec 0 index in
      let stdlib_name =
        String.sub spec (index + 1) (String.length spec - index - 1)
      in
      if output_name = "" || stdlib_name = "" then
        invalid_arg "detector specs must be NAME or OUTPUT_NAME=STDLIB_NAME";
      (output_name, stdlib_name)

let detector_of_spec ~reply_cap ~placeholders ~sanctioned_line ~balance_line
    ~customer_roles spec =
  let output_name, stdlib_name = split_detector_spec spec in
  let name = Some output_name in
  match stdlib_name with
  | "protocol_no_terminal" | "protocol.no_terminal" ->
      Detectors.protocol_no_terminal_detector ?name ()
  | "empty_reply" | "form.empty_reply" -> Detectors.empty_reply_detector ?name ()
  | "reply_over_cap" | "form.reply_over_cap" -> (
      match reply_cap with
      | Some cap -> Detectors.reply_over_cap_detector ?name cap
      | None -> invalid_arg "reply_over_cap requires --reply-cap")
  | "markdown_in_reply" | "form.markdown_in_reply" ->
      Detectors.markdown_in_reply_detector ?name ()
  | "placeholder_echoed" | "leakage.placeholder_echoed" ->
      if placeholders = [] then
        invalid_arg "placeholder_echoed requires at least one --placeholder";
      Detectors.placeholder_echoed_detector ?name placeholders
  | "money_not_in_context" | "grounding.money_not_in_context" ->
      Detectors.money_not_in_context_detector ?name ()
  | "unsanctioned_balance" | "grounding.unsanctioned_balance" -> (
      match sanctioned_line with
      | None -> invalid_arg "unsanctioned_balance requires --sanctioned-line-regex"
      | Some pattern ->
          Detectors.unsanctioned_balance_detector ?name ?balance_line_regex:balance_line
            ?customer_roles:(if customer_roles = [] then None else Some customer_roles)
            pattern)
  | name -> invalid_arg ("unknown stdlib detector: " ^ name)

let default_detector_specs ~reply_cap ~placeholders ~sanctioned_line =
  let specs =
    [
      "protocol_no_terminal";
      "empty_reply";
      "markdown_in_reply";
      "money_not_in_context";
    ]
  in
  let specs = if Option.is_some reply_cap then specs @ [ "reply_over_cap" ] else specs in
  let specs = if placeholders <> [] then specs @ [ "placeholder_echoed" ] else specs in
  if Option.is_some sanctioned_line then specs @ [ "unsanctioned_balance" ] else specs

let detect_command records_path detector_specs reply_cap placeholders sanctioned_line
    balance_line customer_roles output =
  protect (fun () ->
      let records = Record.read_jsonl records_path in
      let detector_specs =
        if detector_specs = [] then
          default_detector_specs ~reply_cap ~placeholders ~sanctioned_line
        else detector_specs
      in
      let detectors =
        List.map
          (detector_of_spec ~reply_cap ~placeholders ~sanctioned_line ~balance_line
             ~customer_roles)
          detector_specs
      in
      let names = List.map (fun (detector : Detectors.detector) -> detector.name) detectors in
      if List.length names <> List.length (List.sort_uniq String.compare names) then
        invalid_arg "detector output names must be unique";
      let payload =
        Detectors.run detectors records |> Detectors.results_to_yojson detectors
        |> Report.render_yojson
      in
      (match output with None -> print_string payload | Some path -> write_text path payload);
      0)

type report_format = Markdown | Json

let report_format_converter = Arg.enum [ ("markdown", Markdown); ("json", Json) ]

let report_command records_path matrix_path verdicts_path declared_detectors format output
    json_out markdown_out worst_examples =
  protect (fun () ->
      if worst_examples < 0 then invalid_arg "worst_examples must be non-negative";
      let records = Record.read_jsonl records_path in
      let matrix = Matrix.of_file matrix_path in
      let detector_results, file_detectors = Report.detached_results_of_file verdicts_path in
      let detector_names =
        List.fold_left
          (fun names name -> if List.mem name names then names else names @ [ name ])
          file_detectors declared_detectors
      in
      let column_groups = Report.column_groups_of_matrix matrix detector_names in
      let report =
        Report.build ~worst_examples ~records:(Report.records_for_matrix matrix records)
          ~detector_results ~rows:(List.map (fun (row : Matrix.row) -> row.name) matrix.rows)
          ~column_groups ()
      in
      let json_text = Report.render_json report in
      let markdown_text = Report.render_markdown report in
      Option.iter (fun path -> write_text path json_text) json_out;
      Option.iter (fun path -> write_text path markdown_text) markdown_out;
      let selected = match format with Json -> json_text | Markdown -> markdown_text in
      (match output with
      | Some path -> write_text path selected
      | None when Option.is_none json_out && Option.is_none markdown_out -> print_string selected
      | None -> ());
      0)

let detector_option =
  Arg.(
    value
    & opt_all string []
    & info [ "detector" ] ~docv:"NAME"
        ~doc:"Registered detector name. Repeat once per detector.")

let detect_cmd =
  let records =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RECORDS" ~doc:"Record JSONL.")
  in
  let detectors =
    Arg.(
      value
      & opt_all string []
      & info [ "detector" ] ~docv:"[OUTPUT_NAME=]STDLIB_NAME"
          ~doc:
            "Detector to run. Repeatable. With no values, runs all non-configurable detectors plus configured factories.")
  in
  let reply_cap =
    Arg.(
      value
      & opt (some int) None
      & info [ "reply-cap" ] ~docv:"CHARS" ~doc:"Maximum reply length for reply_over_cap.")
  in
  let placeholders =
    Arg.(
      value
      & opt_all string []
      & info [ "placeholder" ] ~docv:"REGEX"
          ~doc:"Case-insensitive placeholder regex. Repeatable.")
  in
  let sanctioned_line =
    Arg.(
      value
      & opt (some string) None
      & info [ "sanctioned-line-regex" ] ~docv:"REGEX"
          ~doc:"Approved tool-result line regex for unsanctioned_balance.")
  in
  let balance_line =
    Arg.(
      value
      & opt (some string) None
      & info [ "balance-line-regex" ] ~docv:"REGEX"
          ~doc:"Custom reply balance-line regex.")
  in
  let customer_roles =
    Arg.(
      value
      & opt_all string []
      & info [ "customer-role" ] ~docv:"ROLE" ~doc:"Sanctioned customer role. Repeatable.")
  in
  let output =
    Arg.(value & opt (some string) None & info [ "o"; "output" ] ~docv:"PATH")
  in
  let term =
    Term.(
      const detect_command $ records $ detectors $ reply_cap $ placeholders $ sanctioned_line
      $ balance_line $ customer_roles $ output)
  in
  Cmd.v (Cmd.info "detect" ~doc:"Run pure stdlib detectors over record JSONL.") term

let report_cmd =
  let records =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"RECORDS" ~doc:"Record JSONL.")
  in
  let matrix =
    Arg.(required & pos 1 (some string) None & info [] ~docv:"MATRIX" ~doc:"Matrix JSON.")
  in
  let verdicts =
    Arg.(
      required
      & opt (some string) None
      & info [ "verdicts"; "detector-results" ] ~docv:"PATH"
          ~doc:"Detached detector-verdict JSON from detect or another host.")
  in
  let declared_detectors =
    Arg.(
      value
      & opt_all string []
      & info [ "detector" ] ~docv:"NAME"
          ~doc:"Declare a detector absent from the verdict file. Repeatable.")
  in
  let format =
    Arg.(
      value
      & opt report_format_converter Markdown
      & info [ "format" ] ~docv:"FORMAT" ~doc:"Output format: markdown or json.")
  in
  let output =
    Arg.(value & opt (some string) None & info [ "o"; "output" ] ~docv:"PATH")
  in
  let json_out =
    Arg.(value & opt (some string) None & info [ "json-out" ] ~docv:"PATH")
  in
  let markdown_out =
    Arg.(value & opt (some string) None & info [ "markdown-out" ] ~docv:"PATH")
  in
  let worst_examples =
    Arg.(
      value
      & opt int 3
      & info [ "worst-examples" ] ~docv:"N" ~doc:"Worst examples retained per cell.")
  in
  let term =
    Term.(
      const report_command $ records $ matrix $ verdicts $ declared_detectors $ format
      $ output $ json_out $ markdown_out $ worst_examples)
  in
  Cmd.v (Cmd.info "report" ~doc:"Render a complete deterministic report grid.") term

let validate_cmd =
  let paths =
    Arg.(value & pos_all string [] & info [] ~docv:"PATH" ~doc:"Artifact path to validate.")
  in
  let kind =
    Arg.(
      value
      & opt kind_converter Auto
      & info [ "kind" ] ~docv:"KIND" ~doc:"Artifact kind (default: auto).")
  in
  let corpus =
    Arg.(
      value
      & opt (some string) None
      & info [ "corpus" ] ~docv:"PATH"
          ~doc:"Corpus used for cross-validating a matrix.")
  in
  let term = Term.(const validate_command $ paths $ kind $ corpus $ detector_option) in
  Cmd.v (Cmd.info "validate" ~doc:"Strictly validate persisted dispobench artifacts.") term

let matrix_cmd =
  let matrix_path =
    Arg.(required & pos 0 (some string) None & info [] ~docv:"MATRIX" ~doc:"Matrix JSON.")
  in
  let corpus_path =
    Arg.(required & pos 1 (some string) None & info [] ~docv:"CORPUS" ~doc:"Corpus JSON.")
  in
  let term = Term.(const matrix_command $ matrix_path $ corpus_path $ detector_option) in
  Cmd.v
    (Cmd.info "matrix" ~doc:"Validate the corpus and detector MECE partitions.")
    term

let gate_cmd =
  let lock_path =
    Arg.(
      value
      & pos 0 string "shaping.lock"
      & info [] ~docv:"LOCK" ~doc:"Shaping lock JSON (default: shaping.lock).")
  in
  let root =
    Arg.(
      value
      & opt string "."
      & info [ "root" ] ~docv:"DIR" ~doc:"Root for declared shaping files.")
  in
  let term = Term.(const gate_command $ lock_path $ root) in
  Cmd.v (Cmd.info "gate" ~doc:"Recompute and compare a shaping lock.") term

let command =
  let default = Term.(ret (const (`Help (`Pager, None)))) in
  Cmd.group
    (Cmd.info "dispobench-core" ~version:"0.1.0"
       ~doc:"Deterministic verdict core for dispobench.")
    ~default [ validate_cmd; matrix_cmd; detect_cmd; report_cmd; gate_cmd ]

let () = if not !Sys.interactive then exit (Cmd.eval' command)
