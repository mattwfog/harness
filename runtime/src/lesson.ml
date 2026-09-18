(* M3: lessons — the distilled, versioned facts the learning loop produces.
   One file per lesson under <repo>/lessons/, TOML frontmatter + guidance
   body, mirroring the task-spec format so the whole corpus is greppable and
   git-reviewable. Lessons are born on PROBATION and only reach prompts
   after PROMOTION (M4's gate) — a copy-on-write shape: a lesson
   changes state, never content. *)

type status = Probation | Promoted | Retired

let status_to_string = function
  | Probation -> "probation"
  | Promoted -> "promoted"
  | Retired -> "retired"

let status_of_string = function
  | "probation" -> Ok Probation
  | "promoted" -> Ok Promoted
  | "retired" -> Ok Retired
  | s -> Error (Printf.sprintf "unknown lesson status %s" s)

type t = {
  id : string;
  status : status;
  matchers : string list; (* case-insensitive substrings; any hit = recall *)
  origin_run : string;
  created : string;
  guidance : string; (* the text injected into matching prompts *)
  path : string;
}

let lessons_dir repo_root = Filename.concat repo_root "lessons"

let render (l : t) : string =
  String.concat "\n"
    [
      "+++";
      Printf.sprintf "id = %S" l.id;
      Printf.sprintf "status = %S" (status_to_string l.status);
      Printf.sprintf "matchers = [%s]"
        (String.concat ", " (List.map (Printf.sprintf "%S") l.matchers));
      Printf.sprintf "origin_run = %S" l.origin_run;
      Printf.sprintf "created = %S" l.created;
      "+++";
      "";
      l.guidance;
      "";
    ]

let parse_string ~path text : (t, string) result =
  match Str_split.split_on_marker ~marker:"+++\n" text with
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
          match (str "id", str "status", str_list "matchers") with
          | Some id, Some status_s, Some matchers -> (
              match status_of_string status_s with
              | Error e -> Error (Printf.sprintf "%s: %s" path e)
              | Ok status ->
                  Ok
                    {
                      id;
                      status;
                      matchers;
                      origin_run = Option.value ~default:"" (str "origin_run");
                      created = Option.value ~default:"" (str "created");
                      guidance = String.trim (String.concat "+++\n" rest);
                      path;
                    })
          | _ ->
              Error
                (Printf.sprintf "%s: lesson missing id/status/matchers" path)))
  | _ -> Error (Printf.sprintf "%s: expected '+++' frontmatter" path)

(* Reads go through effects so recall itself is journaled and replayable. *)
let load_all ~repo_root : t list * string list =
  let dir = lessons_dir repo_root in
  if not (Effect.perform (Effects.File_exists dir)) then ([], [])
  else
    let files =
      Sys.readdir dir |> Array.to_list
      |> List.filter (fun f -> Filename.check_suffix f ".md")
      |> List.sort compare
      |> List.map (Filename.concat dir)
    in
    List.fold_left
      (fun (ok, errs) path ->
        let text = Effect.perform (Effects.File_read path) in
        match parse_string ~path text with
        | Ok l -> (ok @ [ l ], errs)
        | Error e -> (ok, errs @ [ e ]))
      ([], []) files

(* Writes go through effects: journaled, policy-checked, revertible. *)
let save ~repo_root (l : t) : string =
  let dir = lessons_dir repo_root in
  let path = Filename.concat dir (l.id ^ ".md") in
  Effect.perform
    (Effects.File_write { path; content = render { l with path } });
  path

let set_status ~repo_root (l : t) (status : status) : t =
  let updated = { l with status } in
  ignore (save ~repo_root updated);
  updated
