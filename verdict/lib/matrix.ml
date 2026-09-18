open Json_util

let schema_version = "1"

type row = {
  name : string;
  scenario_labels : string list;
  tags : string list;
  origin : string;
}

type column = {
  name : string;
  detector_prefixes : string list;
  tags : string list;
  origin : string;
}

type t = { name : string; rows : row list; columns : column list }

let optional_string fields name ~default path =
  match member fields name with None -> default | Some value -> require_string path value

let optional_string_list fields name path =
  match member fields name with None -> [] | Some value -> require_string_list path value

let row_of_yojson value =
  let fields = require_object "matrix_row" value in
  require_exact_keys ~required:[ "name"; "scenario_labels" ]
    ~optional:[ "tags"; "origin" ] "matrix_row" fields;
  {
    name = require_string "matrix_row.name" (required_member "matrix_row" fields "name");
    scenario_labels =
      require_string_list ~nonempty:true "matrix_row.scenario_labels"
        (required_member "matrix_row" fields "scenario_labels");
    tags = optional_string_list fields "tags" "matrix_row.tags";
    origin = optional_string fields "origin" ~default:"portable" "matrix_row.origin";
  }

let column_of_yojson value =
  let fields = require_object "matrix_column" value in
  require_exact_keys ~required:[ "name"; "detector_prefixes" ]
    ~optional:[ "tags"; "origin" ] "matrix_column" fields;
  {
    name = require_string "matrix_column.name" (required_member "matrix_column" fields "name");
    detector_prefixes =
      require_string_list ~nonempty:true "matrix_column.detector_prefixes"
        (required_member "matrix_column" fields "detector_prefixes");
    tags = optional_string_list fields "tags" "matrix_column.tags";
    origin = optional_string fields "origin" ~default:"portable" "matrix_column.origin";
  }

let ensure_unique_names path names =
  if List.length names <> List.length (sorted_unique names) then
    fail path "names must be unique"

let of_yojson value =
  validate_json ~root:"matrix" value;
  let fields = require_object "matrix" value in
  require_exact_keys ~required:[ "rows"; "columns" ]
    ~optional:[ "schema_version"; "name" ] "matrix" fields;
  let version =
    match member fields "schema_version" with
    | None -> schema_version
    | Some value -> require_string "matrix.schema_version" value
  in
  if version <> schema_version then
    fail "matrix.schema_version"
      (Printf.sprintf "unsupported version %S; expected %S" version schema_version);
  let rows =
    require_array "matrix.rows" (required_member "matrix" fields "rows")
    |> List.map row_of_yojson
  in
  let columns =
    require_array "matrix.columns" (required_member "matrix" fields "columns")
    |> List.map column_of_yojson
  in
  if rows = [] then fail "matrix.rows" "must not be empty";
  if columns = [] then fail "matrix.columns" "must not be empty";
  ensure_unique_names "matrix.rows" (List.map (fun (row : row) -> row.name) rows);
  ensure_unique_names "matrix.columns"
    (List.map (fun (column : column) -> column.name) columns);
  {
    name = optional_string fields "name" ~default:"matrix" "matrix.name";
    rows;
    columns;
  }

let of_string payload = parse_string ~path:"matrix" payload |> of_yojson
let of_file path = read_file path |> of_string

let row_to_yojson (row : row) =
  `Assoc
    [
      ("name", `String row.name);
      ("scenario_labels", `List (List.map (fun value -> `String value) row.scenario_labels));
      ("tags", `List (List.map (fun value -> `String value) row.tags));
      ("origin", `String row.origin);
    ]

let column_to_yojson (column : column) =
  `Assoc
    [
      ("name", `String column.name);
      ( "detector_prefixes",
        `List (List.map (fun value -> `String value) column.detector_prefixes) );
      ("tags", `List (List.map (fun value -> `String value) column.tags));
      ("origin", `String column.origin);
    ]

let to_yojson (value : t) =
  `Assoc
    [
      ("schema_version", `String schema_version);
      ("name", `String value.name);
      ("rows", `List (List.map row_to_yojson value.rows));
      ("columns", `List (List.map column_to_yojson value.columns));
    ]

let to_string value = canonical_json (to_yojson value)
let content_hash value = Json_util.content_hash (to_yojson value)

let scenario_of_yojson value =
  let fields = require_object "scenario" value in
  require_exact_keys ~required:[ "scenario_id"; "family"; "history"; "reference" ]
    ~optional:[ "system_prompt"; "metadata" ] "scenario" fields;
  let scenario_id =
    require_string "scenario.scenario_id" (required_member "scenario" fields "scenario_id")
  in
  let family = require_string "scenario.family" (required_member "scenario" fields "family") in
  let history = require_array "scenario.history" (required_member "scenario" fields "history") in
  List.iteri
    (fun index message ->
      ignore (require_object (Printf.sprintf "scenario.history[%d]" index) message))
    history;
  ignore (required_member "scenario" fields "reference");
  (match member fields "system_prompt" with
  | None -> ()
  | Some value -> ignore (require_string ~nonempty:false "scenario.system_prompt" value));
  (match member fields "metadata" with
  | None -> ()
  | Some value -> ignore (require_object "scenario.metadata" value));
  (scenario_id, family)

let corpus_labels_of_yojson value =
  validate_json ~root:"corpus" value;
  let fields = require_object "corpus" value in
  require_exact_keys ~required:[ "scenarios"; "leak_census" ]
    ~optional:[ "schema_version"; "name"; "metadata" ] "corpus" fields;
  let version =
    match member fields "schema_version" with
    | None -> schema_version
    | Some value -> require_string "corpus.schema_version" value
  in
  if version <> schema_version then
    fail "corpus.schema_version"
      (Printf.sprintf "unsupported version %S; expected %S" version schema_version);
  let leak_census =
    require_int "corpus.leak_census" (required_member "corpus" fields "leak_census")
  in
  if leak_census <> 0 then
    fail "corpus.leak_census" "must be 0 before a corpus is accepted";
  (match member fields "name" with
  | None -> ()
  | Some value -> ignore (require_string "corpus.name" value));
  (match member fields "metadata" with
  | None -> ()
  | Some value -> ignore (require_object "corpus.metadata" value));
  let scenarios =
    require_array "corpus.scenarios" (required_member "corpus" fields "scenarios")
    |> List.map scenario_of_yojson
  in
  if scenarios = [] then fail "corpus.scenarios" "must not be empty";
  let ids = List.map fst scenarios in
  if List.length ids <> List.length (sorted_unique ids) then
    fail "corpus.scenarios" "scenario_id values must be unique";
  List.map snd scenarios |> sorted_unique

let corpus_labels_of_string payload =
  parse_string ~path:"corpus" payload |> corpus_labels_of_yojson

let corpus_labels_of_file path = read_file path |> corpus_labels_of_string

let starts_with ~prefix value =
  let prefix_length = String.length prefix in
  String.length value >= prefix_length
  && String.sub value 0 prefix_length = prefix

let validate_rows matrix corpus_labels =
  if corpus_labels = [] then fail "corpus labels" "must not be empty";
  if List.length corpus_labels <> List.length (sorted_unique corpus_labels) then
    fail "corpus labels" "must not contain duplicates";
  List.iter (fun label -> ignore (require_string "corpus label" (`String label))) corpus_labels;
  let homes = Hashtbl.create 16 in
  List.iter
    (fun (row : row) ->
      List.iter
        (fun label ->
          let prior = Option.value ~default:[] (Hashtbl.find_opt homes label) in
          Hashtbl.replace homes label (prior @ [ row.name ]))
        row.scenario_labels)
    matrix.rows;
  let expected = sorted_unique corpus_labels in
  let declared = Hashtbl.to_seq_keys homes |> List.of_seq |> List.sort String.compare in
  let missing = List.filter (fun label -> not (List.mem label declared)) expected in
  let extra = List.filter (fun label -> not (List.mem label expected)) declared in
  let duplicates =
    declared
    |> List.filter_map (fun label ->
           let row_homes = Hashtbl.find homes label in
           if List.length row_homes = 1 then None else Some (label, row_homes))
  in
  let problems = ref [] in
  if missing <> [] then
    problems := !problems @ [ "scenario labels without a row: " ^ String.concat ", " missing ];
  if extra <> [] then
    problems := !problems @ [ "row labels absent from corpus: " ^ String.concat ", " extra ];
  if duplicates <> [] then
    problems :=
      !problems
      @ [
          "scenario labels with multiple rows: "
          ^ (duplicates
            |> List.map (fun (label, row_homes) ->
                   Printf.sprintf "%s (%s)" label (String.concat "/" row_homes))
            |> String.concat ", ");
        ];
  if !problems <> [] then fail "matrix.rows" (String.concat "; " !problems)

let validate_prefixes matrix =
  let prefixes =
    matrix.columns
    |> List.concat_map (fun (column : column) ->
           List.map (fun prefix -> (prefix, column.name)) column.detector_prefixes)
  in
  let rec compare_remaining = function
    | [] -> ()
    | (left, left_home) :: rest ->
        List.iter
          (fun (right, right_home) ->
            if starts_with ~prefix:left right || starts_with ~prefix:right left then
              fail "matrix.columns"
                (Printf.sprintf "detector prefixes overlap: %S (%s) and %S (%s)" left
                   left_home right right_home))
          rest;
        compare_remaining rest
  in
  compare_remaining prefixes

let validate_detectors matrix detector_names =
  if detector_names = [] then fail "detector_names" "must not be empty";
  List.iter (fun name -> ignore (require_string "detector name" (`String name))) detector_names;
  if List.length detector_names <> List.length (sorted_unique detector_names) then
    fail "detector_names" "must not contain duplicates";
  let homes detector =
    matrix.columns
    |> List.filter_map (fun (column : column) ->
           if List.exists (fun prefix -> starts_with ~prefix detector) column.detector_prefixes
           then Some column.name
           else None)
  in
  let no_home, multiple_homes =
    detector_names
    |> List.sort String.compare
    |> List.fold_left
         (fun (none, multiple) detector ->
           match homes detector with
           | [] -> (detector :: none, multiple)
           | [ _ ] -> (none, multiple)
           | columns -> (none, (detector, columns) :: multiple))
         ([], [])
  in
  let no_home = List.rev no_home and multiple_homes = List.rev multiple_homes in
  let problems = ref [] in
  if no_home <> [] then
    problems := !problems @ [ "detectors without a column: " ^ String.concat ", " no_home ];
  if multiple_homes <> [] then
    problems :=
      !problems
      @ [
          "detectors with multiple columns: "
          ^ (multiple_homes
            |> List.map (fun (detector, columns) ->
                   Printf.sprintf "%s (%s)" detector (String.concat "/" columns))
            |> String.concat ", ");
        ];
  if !problems <> [] then fail "matrix.columns" (String.concat "; " !problems)

let validate matrix ~corpus_labels ~detector_names =
  validate_rows matrix corpus_labels;
  validate_prefixes matrix;
  validate_detectors matrix detector_names;
  matrix
