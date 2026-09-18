type record_ref = { key : string; family : string }
type column_group = { name : string; detectors : string list }
type worst_example = { record_key : string; fired_detectors : string list }

type cell = {
  row : string;
  column_group : string;
  fires : int;
  n : int;
  fire_rate : float option;
  ci95 : (float * float) option;
  record_keys : string list;
  fire_record_keys : string list;
  worst_examples : worst_example list;
}

type t = {
  rows : string list;
  column_groups : column_group list;
  record_count : int;
  unscored_record_keys : string list;
  cells : cell list;
}

type detector_results = (string * (string * Detectors.verdict) list) list

let ensure_nonempty label value =
  if value = "" then invalid_arg (label ^ " names must be non-empty strings")

let has_duplicates values =
  List.length values <> List.length (List.sort_uniq String.compare values)

let normalize_rows rows =
  if rows = [] then invalid_arg "at least one row is required";
  List.iter (ensure_nonempty "row") rows;
  if has_duplicates rows then invalid_arg "duplicate row name";
  List.sort String.compare rows

let normalize_groups groups =
  if groups = [] then invalid_arg "at least one column group is required";
  let groups =
    List.map
      (fun group ->
        ensure_nonempty "column group" group.name;
        if group.detectors = [] then
          invalid_arg (Printf.sprintf "column group %S has no detectors" group.name);
        List.iter (ensure_nonempty "detector") group.detectors;
        { group with detectors = List.sort String.compare group.detectors })
      groups
    |> List.sort (fun left right -> String.compare left.name right.name)
  in
  let group_names = List.map (fun group -> group.name) groups in
  if has_duplicates group_names then invalid_arg "duplicate column group name";
  let detector_homes = Hashtbl.create 16 in
  List.iter
    (fun group ->
      List.iter
        (fun detector ->
          match Hashtbl.find_opt detector_homes detector with
          | None -> Hashtbl.add detector_homes detector group.name
          | Some prior ->
              invalid_arg
                (Printf.sprintf "detector %S has multiple column homes: %S and %S"
                   detector prior group.name))
        group.detectors)
    groups;
  (groups, detector_homes)

let normalize_records records rows =
  let known_rows = List.sort_uniq String.compare rows in
  List.iter
    (fun record ->
      ensure_nonempty "record key" record.key;
      if record.family = "" then
        invalid_arg (Printf.sprintf "record %S must have a non-empty string family" record.key);
      if not (List.mem record.family known_rows) then
        invalid_arg
          (Printf.sprintf "record %S has undeclared family %S" record.key record.family))
    records;
  let records = List.sort (fun left right -> String.compare left.key right.key) records in
  let keys = List.map (fun record -> record.key) records in
  if has_duplicates keys then (
    let rec duplicate = function
      | left :: (right :: _ as rest) -> if left = right then left else duplicate rest
      | _ -> "<unknown>"
    in
    invalid_arg (Printf.sprintf "duplicate record key: %S" (duplicate keys)));
  records

let normalize_results results records detector_homes =
  let record_keys = List.map (fun record -> record.key) records in
  let seen_records = Hashtbl.create 16 in
  List.iter
    (fun (record_key, verdicts) ->
      if not (List.mem record_key record_keys) then
        invalid_arg
          (Printf.sprintf "detector results reference unknown record %S" record_key);
      if Hashtbl.mem seen_records record_key then
        invalid_arg (Printf.sprintf "duplicate detector result record: %S" record_key);
      Hashtbl.add seen_records record_key ();
      let seen_detectors = Hashtbl.create 16 in
      List.iter
        (fun (detector, _) ->
          if not (Hashtbl.mem detector_homes detector) then
            invalid_arg (Printf.sprintf "result references ungrouped detector %S" detector);
          if Hashtbl.mem seen_detectors detector then
            invalid_arg
              (Printf.sprintf "duplicate detector result for %S/%S" record_key detector);
          Hashtbl.add seen_detectors detector ())
        verdicts)
    results;
  List.map
    (fun (record_key, verdicts) ->
      (record_key, List.sort (fun (left, _) (right, _) -> String.compare left right) verdicts))
    results
  |> List.sort (fun (left, _) (right, _) -> String.compare left right)

let verdict_for results record_key detector =
  match List.assoc_opt record_key results with
  | None -> None
  | Some verdicts -> List.assoc_opt detector verdicts |> Option.join

let take count values =
  let rec loop remaining taken = function
    | _ when remaining = 0 -> List.rev taken
    | [] -> List.rev taken
    | value :: rest -> loop (remaining - 1) (value :: taken) rest
  in
  loop count [] values

let build ?(worst_examples = 3) ~records ~detector_results ~rows ~column_groups () =
  if worst_examples < 0 then invalid_arg "worst_examples must be non-negative";
  let rows = normalize_rows rows in
  let column_groups, detector_homes = normalize_groups column_groups in
  let records = normalize_records records rows in
  let detector_results = normalize_results detector_results records detector_homes in
  let cells =
    rows
    |> List.concat_map (fun row ->
           let row_records = List.filter (fun record -> record.family = row) records in
           List.map
             (fun group ->
               let applicable, firing =
                 List.fold_left
                   (fun (applicable, firing) record ->
                     let applicable_detectors =
                       List.filter
                         (fun detector ->
                           Option.is_some (verdict_for detector_results record.key detector))
                         group.detectors
                     in
                     if applicable_detectors = [] then (applicable, firing)
                     else
                       let fired_detectors =
                         List.filter
                           (fun detector ->
                             verdict_for detector_results record.key detector = Some true)
                           group.detectors
                       in
                       let applicable = record.key :: applicable in
                       let firing =
                         if fired_detectors = [] then firing
                         else (record.key, fired_detectors) :: firing
                       in
                       (applicable, firing))
                   ([], []) row_records
               in
               let applicable = List.rev applicable and firing = List.rev firing in
               let n = List.length applicable and fires = List.length firing in
               let fire_rate, ci95 =
                 if n = 0 then (None, None)
                 else
                   ( Some (float_of_int fires /. float_of_int n),
                     Some (Wilson.interval ~fires ~n) )
               in
               let ranked =
                 List.sort
                   (fun (left_key, left_detectors) (right_key, right_detectors) ->
                     let by_count =
                       Int.compare (List.length right_detectors) (List.length left_detectors)
                     in
                     if by_count <> 0 then by_count else String.compare left_key right_key)
                   firing
               in
               {
                 row;
                 column_group = group.name;
                 fires;
                 n;
                 fire_rate;
                 ci95;
                 record_keys = applicable;
                 fire_record_keys = List.map fst firing;
                 worst_examples =
                   take worst_examples ranked
                   |> List.map (fun (record_key, fired_detectors) ->
                          { record_key; fired_detectors });
               })
             column_groups)
  in
  let scored_keys =
    cells |> List.concat_map (fun cell -> cell.record_keys)
    |> List.sort_uniq String.compare
  in
  {
    rows;
    column_groups;
    record_count = List.length records;
    unscored_record_keys =
      records
      |> List.filter_map (fun record ->
             if List.mem record.key scored_keys then None else Some record.key);
    cells;
  }

let build_report ?(worst_examples = 3) ~(records : Record.t list) ~detector_results ~rows
    ~column_groups () =
  let records =
    List.map (fun (record : Record.t) -> { key = record.key; family = record.family }) records
  in
  build ~worst_examples ~records ~detector_results ~rows ~column_groups ()

let wilson_interval fires n = Wilson.interval ~fires ~n

let string_list_to_yojson values =
  `List (List.map (fun value -> `String value) values)

let worst_example_to_yojson example =
  `Assoc
    [
      ("record_key", `String example.record_key);
      ("fired_detectors", string_list_to_yojson example.fired_detectors);
    ]

let cell_to_yojson cell =
  let ci95 =
    match cell.ci95 with
    | None -> `Null
    | Some (low, high) -> `Assoc [ ("low", `Float low); ("high", `Float high) ]
  in
  `Assoc
    [
      ("row", `String cell.row);
      ("column_group", `String cell.column_group);
      ("fires", `Int cell.fires);
      ("n", `Int cell.n);
      ("fire_rate", Option.fold ~none:`Null ~some:(fun value -> `Float value) cell.fire_rate);
      ("ci95", ci95);
      ("record_keys", string_list_to_yojson cell.record_keys);
      ("fire_record_keys", string_list_to_yojson cell.fire_record_keys);
      ("worst_examples", `List (List.map worst_example_to_yojson cell.worst_examples));
    ]

let to_yojson report =
  `Assoc
    [
      ("report_version", `Int 1);
      ("aggregation", `String "record_any_detector");
      ("confidence_interval", `String "wilson_95");
      ("rows", string_list_to_yojson report.rows);
      ( "column_groups",
        `List
          (List.map
             (fun group ->
               `Assoc
                 [
                   ("name", `String group.name);
                   ("detectors", string_list_to_yojson group.detectors);
                 ])
             report.column_groups) );
      ("record_count", `Int report.record_count);
      ("unscored_record_keys", string_list_to_yojson report.unscored_record_keys);
      ("cells", `List (List.map cell_to_yojson report.cells));
    ]

let add_indent buffer count = Buffer.add_string buffer (String.make count ' ')

let rec add_pretty_json buffer indent = function
  | `Null -> Buffer.add_string buffer "null"
  | `Bool true -> Buffer.add_string buffer "true"
  | `Bool false -> Buffer.add_string buffer "false"
  | `Int value -> Buffer.add_string buffer (string_of_int value)
  | `Intlit value -> Buffer.add_string buffer value
  | `Float value -> Buffer.add_string buffer (Json_util.python_float_to_string value)
  | `String value -> Json_util.add_json_string buffer value
  | `List [] -> Buffer.add_string buffer "[]"
  | `List values ->
      Buffer.add_string buffer "[\n";
      List.iteri
        (fun index value ->
          if index > 0 then Buffer.add_string buffer ",\n";
          add_indent buffer (indent + 2);
          add_pretty_json buffer (indent + 2) value)
        values;
      Buffer.add_char buffer '\n';
      add_indent buffer indent;
      Buffer.add_char buffer ']'
  | `Assoc [] -> Buffer.add_string buffer "{}"
  | `Assoc fields ->
      Buffer.add_string buffer "{\n";
      fields
      |> List.sort (fun (left, _) (right, _) -> String.compare left right)
      |> List.iteri (fun index (key, value) ->
             if index > 0 then Buffer.add_string buffer ",\n";
             add_indent buffer (indent + 2);
             Json_util.add_json_string buffer key;
             Buffer.add_string buffer ": ";
             add_pretty_json buffer (indent + 2) value);
      Buffer.add_char buffer '\n';
      add_indent buffer indent;
      Buffer.add_char buffer '}'
  | `Tuple _ | `Variant _ -> invalid_arg "render_json: non-JSON value"

let render_yojson value =
  Json_util.validate_json ~root:"report" value;
  let buffer = Buffer.create 4096 in
  add_pretty_json buffer 0 value;
  Buffer.add_char buffer '\n';
  Buffer.contents buffer

let render_json report = render_yojson (to_yojson report)

let replace_all ~pattern ~replacement value =
  let pattern_length = String.length pattern in
  if pattern_length = 0 then value
  else
    let buffer = Buffer.create (String.length value) in
    let rec loop offset =
      if offset >= String.length value then ()
      else if offset + pattern_length <= String.length value
              && String.sub value offset pattern_length = pattern
      then (
        Buffer.add_string buffer replacement;
        loop (offset + pattern_length))
      else (
        Buffer.add_char buffer value.[offset];
        loop (offset + 1))
    in
    loop 0;
    Buffer.contents buffer

let escape_table value =
  value |> replace_all ~pattern:"\\" ~replacement:"\\\\"
  |> replace_all ~pattern:"|" ~replacement:"\\|"
  |> replace_all ~pattern:"\r\n" ~replacement:"<br>"
  |> replace_all ~pattern:"\r" ~replacement:"<br>"
  |> replace_all ~pattern:"\n" ~replacement:"<br>"

let format_keys values =
  match List.map escape_table values with [] -> "—" | values -> String.concat ", " values

let format_cell cell =
  match (cell.n, cell.fire_rate, cell.ci95) with
  | 0, _, _ -> "— (n=0)"
  | _, Some rate, Some (low, high) ->
      Printf.sprintf "%.1f%% (%d/%d; 95%% CI %.1f%%–%.1f%%)" (rate *. 100.0)
        cell.fires cell.n (low *. 100.0) (high *. 100.0)
  | _ -> assert false

let render_markdown report =
  let cells =
    List.map (fun cell -> ((cell.row, cell.column_group), cell)) report.cells
  in
  let cell row group = List.assoc (row, group) cells in
  let group_names = List.map (fun group -> group.name) report.column_groups in
  let lines = ref [] in
  let add line = lines := line :: !lines in
  List.iter add
    [
      "# dispobench report";
      "";
      "Fire rate is the share of applicable records for which any detector in the column group fired. Intervals are Wilson 95% confidence intervals.";
      "";
      Printf.sprintf "Records: %d" report.record_count;
      "";
      "## Fire-rate grid";
      "";
      "| Row | " ^ String.concat " | " (List.map escape_table group_names) ^ " |";
      "| --- | " ^ String.concat " | " (List.map (Fun.const "---") group_names) ^ " |";
    ];
  List.iter
    (fun row ->
      let rendered = List.map (fun group -> format_cell (cell row group)) group_names in
      add ("| " ^ escape_table row ^ " | " ^ String.concat " | " rendered ^ " |"))
    report.rows;
  List.iter add
    [
      "";
      "## Cell provenance";
      "";
      "| Row | Column group | Applicable record keys | Fire record keys |";
      "| --- | --- | --- | --- |";
    ];
  List.iter
    (fun cell ->
      add
        ("| "
        ^ String.concat " | "
            [
              escape_table cell.row;
              escape_table cell.column_group;
              format_keys cell.record_keys;
              format_keys cell.fire_record_keys;
            ]
        ^ " |"))
    report.cells;
  List.iter add
    [
      "";
      "## Worst examples";
      "";
      "| Row | Column group | Record key | Fired detectors |";
      "| --- | --- | --- | --- |";
    ];
  let example_count = ref 0 in
  List.iter
    (fun cell ->
      List.iter
        (fun example ->
          incr example_count;
          add
            ("| "
            ^ String.concat " | "
                [
                  escape_table cell.row;
                  escape_table cell.column_group;
                  escape_table example.record_key;
                  format_keys example.fired_detectors;
                ]
            ^ " |"))
        cell.worst_examples)
    report.cells;
  if !example_count = 0 then add "| — | — | — | — |";
  List.iter add
    [ ""; "## Unscored records"; ""; format_keys report.unscored_record_keys; "" ];
  String.concat "\n" (List.rev !lines)

let verdict_of_yojson path = function
  | `Null -> None
  | `Bool value -> Some value
  | _ -> Json_util.fail path "must be bool or None"

let results_object_of_yojson value =
  Json_util.require_object "detector_results" value
  |> List.map (fun (record_key, value) ->
         let verdicts =
           Json_util.require_object ("detector_results." ^ record_key) value
           |> List.map (fun (detector, verdict) ->
                  (detector, verdict_of_yojson (record_key ^ "/" ^ detector) verdict))
         in
         (record_key, verdicts))

let detached_results_of_yojson value =
  match value with
  | `Assoc fields when List.mem_assoc "detector_results" fields ->
      let declared =
        match List.assoc_opt "detectors" fields with
        | None -> []
        | Some value -> Json_util.require_string_list "verdicts.detectors" value
      in
      let results =
        List.assoc "detector_results" fields |> results_object_of_yojson
      in
      let discovered =
        results |> List.concat_map (fun (_, verdicts) -> List.map fst verdicts)
      in
      let declared =
        List.fold_left
          (fun names name -> if List.mem name names then names else names @ [ name ])
          declared discovered
      in
      (results, declared)
  | _ ->
      let results = results_object_of_yojson value in
      let declared =
        results |> List.concat_map (fun (_, verdicts) -> List.map fst verdicts)
        |> List.sort_uniq String.compare
      in
      (results, declared)

let detached_results_of_file path =
  Json_util.parse_file ~path_label:"verdicts" path |> detached_results_of_yojson

let starts_with ~prefix value =
  String.length value >= String.length prefix
  && String.sub value 0 (String.length prefix) = prefix

let column_groups_of_matrix (matrix : Matrix.t) detector_names =
  let groups =
    List.map (fun (column : Matrix.column) -> (column.name, ref [])) matrix.columns
  in
  List.iter
    (fun detector ->
      let homes =
        matrix.columns
        |> List.filter (fun (column : Matrix.column) ->
               List.exists (fun prefix -> starts_with ~prefix detector) column.detector_prefixes)
      in
      match homes with
      | [ home ] ->
          let names = List.assoc home.name groups in
          names := !names @ [ detector ]
      | [] -> invalid_arg (Printf.sprintf "detector %S has no matrix column homes" detector)
      | _ ->
          invalid_arg (Printf.sprintf "detector %S has multiple matrix column homes" detector))
    detector_names;
  let empty =
    groups |> List.filter_map (fun (name, detectors) -> if !detectors = [] then Some name else None)
    |> List.sort String.compare
  in
  if empty <> [] then
    invalid_arg ("matrix columns contain no detectors: " ^ String.concat ", " empty);
  List.map (fun (name, detectors) -> { name; detectors = !detectors }) groups

let row_for_family (matrix : Matrix.t) family =
  let declared_rows = List.map (fun (row : Matrix.row) -> row.name) matrix.rows in
  let homes =
    matrix.rows
    |> List.filter (fun (row : Matrix.row) -> List.mem family row.scenario_labels)
    |> List.map (fun (row : Matrix.row) -> row.name)
  in
  match homes with
  | [ row ] -> row
  | [] when List.mem family declared_rows -> family
  | [] -> invalid_arg (Printf.sprintf "record family %S has no matrix row" family)
  | _ -> invalid_arg (Printf.sprintf "scenario label %S has multiple matrix rows" family)

let records_for_matrix matrix records =
  List.map
    (fun (record : Record.t) -> { key = record.key; family = row_for_family matrix record.family })
    records
