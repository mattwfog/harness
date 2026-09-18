open Json_util

let schema_version = "1"

type t = {
  sha256 : string;
  files : string list;
  run : string;
  date : string;
}

type file_entry = { path : string; sha256 : string }

let is_directory path =
  match (Unix.stat path).st_kind with Unix.S_DIR -> true | _ -> false

let is_regular_file path =
  match (Unix.stat path).st_kind with Unix.S_REG -> true | _ -> false

let relative_to_root ~root path =
  if root = "/" then
    if String.length path > 1 && path.[0] = '/' then
      Some (String.sub path 1 (String.length path - 1))
    else None
  else
    let prefix = root ^ "/" in
    if String.length path > String.length prefix
       && String.sub path 0 (String.length prefix) = prefix
    then Some (String.sub path (String.length prefix) (String.length path - String.length prefix))
    else None

let declared_file_entries paths ~root =
  let resolved_root = Unix.realpath root in
  if not (is_directory resolved_root) then raise (Sys_error (resolved_root ^ ": not a directory"));
  let seen = Hashtbl.create (List.length paths) in
  let entries =
    List.map
      (fun declared ->
        let candidate =
          if Filename.is_relative declared then Filename.concat resolved_root declared else declared
        in
        let resolved = Unix.realpath candidate in
        let label =
          match relative_to_root ~root:resolved_root resolved with
          | Some label -> label
          | None -> raise (Invalid_argument ("declared file is outside root: " ^ declared))
        in
        if not (is_regular_file resolved) then
          raise (Invalid_argument ("declared path is not a file: " ^ declared));
        if Hashtbl.mem seen label then
          raise (Invalid_argument ("duplicate declared file: " ^ label));
        Hashtbl.add seen label ();
        { path = label; sha256 = hash_file resolved })
      paths
  in
  if entries = [] then raise (Invalid_argument "at least one declared file is required");
  List.sort (fun left right -> String.compare left.path right.path) entries

let entry_to_yojson entry =
  `Assoc [ ("path", `String entry.path); ("sha256", `String entry.sha256) ]

let hash_entries entries =
  Json_util.content_hash (`List (List.map entry_to_yojson entries))

let hash_files paths ~root = declared_file_entries paths ~root |> hash_entries

let of_yojson value =
  validate_json ~root:"shaping_lock" value;
  let fields = require_object "shaping_lock" value in
  require_exact_keys ~required:[ "sha256"; "files"; "run"; "date" ]
    ~optional:[ "schema_version" ] "shaping_lock" fields;
  let version =
    match member fields "schema_version" with
    | None -> schema_version
    | Some value -> require_string "shaping_lock.schema_version" value
  in
  if version <> schema_version then
    fail "shaping_lock.schema_version"
      (Printf.sprintf "unsupported version %S; expected %S" version schema_version);
  let files =
    require_string_list ~nonempty:true "shaping_lock.files"
      (required_member "shaping_lock" fields "files")
  in
  if List.sort String.compare files <> files then fail "shaping_lock.files" "must be sorted";
  {
    sha256 =
      require_sha256 "shaping_lock.sha256" (required_member "shaping_lock" fields "sha256");
    files;
    run = require_string "shaping_lock.run" (required_member "shaping_lock" fields "run");
    date = require_date "shaping_lock.date" (required_member "shaping_lock" fields "date");
  }

let of_string payload = parse_string ~path:"shaping_lock" payload |> of_yojson
let read path = read_file path |> of_string

let to_yojson (value : t) =
  `Assoc
    [
      ("schema_version", `String schema_version);
      ("sha256", `String value.sha256);
      ("files", `List (List.map (fun path -> `String path) value.files));
      ("run", `String value.run);
      ("date", `String value.date);
    ]

let to_string value = canonical_json (to_yojson value)

let create ~files ~run ~date ~root =
  ignore (require_string "shaping_lock.run" (`String run));
  ignore (require_date "shaping_lock.date" (`String date));
  let entries = declared_file_entries files ~root in
  {
    sha256 = hash_entries entries;
    files = List.map (fun entry -> entry.path) entries;
    run;
    date;
  }

let rec make_directory path =
  if path = "" || path = "." || path = Filename.dirname path then ()
  else
    try
      if not (is_directory path) then raise (Sys_error (path ^ ": not a directory"))
    with
    | Unix.Unix_error (Unix.ENOENT, _, _) | Sys_error _ when not (Sys.file_exists path) ->
        make_directory (Filename.dirname path);
        Unix.mkdir path 0o777

let write (value : t) path =
  (* Revalidate the public record before persisting it. *)
  ignore (of_yojson (to_yojson value));
  let parent = Filename.dirname path in
  make_directory parent;
  let temporary = Filename.temp_file ~temp_dir:parent ("." ^ Filename.basename path ^ ".") "" in
  try
    let channel = open_out_bin temporary in
    (try
       output_string channel (to_string value ^ "\n");
       flush channel;
       Unix.fsync (Unix.descr_of_out_channel channel);
       close_out channel
     with error ->
       close_out_noerr channel;
       raise error);
    Unix.rename temporary path
  with error ->
    (try Sys.remove temporary with Sys_error _ -> ());
    raise error

let compare (value : t) ~root =
  try String.equal (hash_files value.files ~root) value.sha256 with
  | Sys_error _ | Unix.Unix_error _ | Invalid_argument _ -> false
