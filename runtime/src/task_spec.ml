(* Task specs: TOML frontmatter between '+++' lines, then a markdown mission
   body — byte-compatible with the task format of the Python fleet
   dispatcher this runtime generalizes. *)

type t = {
  id : string;
  title : string;
  owns : string list; (* repo-relative paths this task may create/modify *)
  acceptance : string; (* shell command that proves the task done *)
  packages : string list;
  commit_type : string;
  setup : string option; (* eval tasks: prepares a fresh eval repo (M4 gate) *)
  tripwire : string option; (* eval tasks: exit 0 after the run = tripwire FIRED *)
  body : string;
  path : string;
}

let parse_string ~path text : (t, string) result =
  let parts = Str_split.split_on_marker ~marker:"+++\n" text in
  (match parts with
      | before :: toml_part :: rest when String.trim before = "" -> (
          match Otoml.Parser.from_string toml_part with
          | exception e ->
              Error (Printf.sprintf "%s: TOML parse failed: %s" path (Printexc.to_string e))
          | toml -> (
              let str key = Otoml.find_opt toml (Otoml.get_string ~strict:true) [ key ] in
              let str_list key =
                Otoml.find_opt toml
                  (Otoml.get_array ~strict:true (Otoml.get_string ~strict:true))
                  [ key ]
              in
              match (str "id", str "title", str_list "owns", str "acceptance") with
              | Some id, Some title, Some owns, Some acceptance ->
                  Ok
                    {
                      id;
                      title;
                      owns;
                      acceptance;
                      packages = Option.value ~default:[] (str_list "packages");
                      commit_type = Option.value ~default:"feat" (str "commit_type");
                      setup = str "setup";
                      tripwire = str "tripwire";
                      body = String.trim (String.concat "+++\n" rest);
                      path;
                    }
              | _ ->
                  Error
                    (Printf.sprintf
                       "%s: frontmatter missing one of the required keys \
                        id/title/owns/acceptance"
                       path)))
      | _ -> Error (Printf.sprintf "%s: expected '+++' TOML frontmatter block" path))

let parse_file path : (t, string) result =
  match In_channel.with_open_bin path In_channel.input_all with
  | text -> parse_string ~path text
  | exception Sys_error e -> Error e
