(* Person-in-command policy: the rules an agent program's effects are checked
   against before they reach the world. This governs HARNESS-performed
   effects; what an agent subprocess does internally is bounded by its
   runner's own sandbox flags plus the repo's standing orders (AGENTS.md) —
   stated honestly, not implied otherwise.

   Project git policy encoded below:
   never push, never rewrite history, never checkout/restore to unwind
   edits, pathspec-only commits. *)

type t = {
  repo_root : string;
  write_roots : string list; (* absolute dir prefixes File_write may target *)
  commit_paths : string list; (* task `owns`: Git_commit paths must be within *)
}

let normalize path =
  (* Lexical normalization only (no symlink resolution): collapse ".."
     segments so prefix checks can't be escaped with "a/../../etc". *)
  let absolute =
    if Filename.is_relative path then Filename.concat (Sys.getcwd ()) path
    else path
  in
  let parts = String.split_on_char '/' absolute in
  let stack =
    List.fold_left
      (fun acc part ->
        match (part, acc) with
        | "", _ | ".", _ -> acc
        | "..", _ :: rest -> rest
        | "..", [] -> []
        | p, _ -> p :: acc)
      [] parts
  in
  "/" ^ String.concat "/" (List.rev stack)

let under_prefix ~prefix path =
  let p = normalize prefix and c = normalize path in
  c = p || String.starts_with ~prefix:(p ^ "/") c

let banned_git_subcommands =
  [
    "push"; "rebase"; "reset"; "checkout"; "restore"; "stash"; "mv";
    "branch"; "switch"; "cherry-pick"; "am"; "apply"; "merge"; "revert";
    "commit"; "add";
    (* commit/add via Tool_exec are banned too: the ONLY sanctioned git
       write is the Git_commit effect, which enforces pathspec scope. *)
  ]

let is_git_binary arg =
  arg = "git" || Filename.basename arg = "git"

let check_tool_exec (t : t) (req : Effects.exec_req) : (unit, string) result =
  match req.argv with
  | [] -> Error "empty argv"
  | prog :: rest ->
      if not (under_prefix ~prefix:t.repo_root req.cwd) then
        Error (Printf.sprintf "cwd %s outside repo root %s" req.cwd t.repo_root)
      else if is_git_binary prog then
        let sub = match rest with s :: _ -> s | [] -> "" in
        if List.mem sub banned_git_subcommands then
          Error
            (Printf.sprintf
               "git %s is banned at the harness boundary (git writes go \
                through the Git_commit effect only)"
               sub)
        else Ok ()
      else Ok ()

let check_file_write (t : t) (req : Effects.write_req) : (unit, string) result =
  if List.exists (fun root -> under_prefix ~prefix:root req.path) t.write_roots
  then Ok ()
  else
    Error
      (Printf.sprintf "write to %s outside write roots [%s]" req.path
         (String.concat "; " t.write_roots))

let check_git_commit (t : t) (req : Effects.commit_req) : (unit, string) result
    =
  if normalize req.repo <> normalize t.repo_root then
    Error (Printf.sprintf "commit in %s but policy repo is %s" req.repo t.repo_root)
  else if t.commit_paths = [] then
    Error "no commit scope set: this task's policy allows no commits"
  else
    let out_of_scope =
      List.filter
        (fun p ->
          not
            (List.exists
               (fun owned ->
                 let abs_owned = Filename.concat t.repo_root owned in
                 under_prefix ~prefix:abs_owned (Filename.concat t.repo_root p)
                 || owned = p)
               t.commit_paths))
        req.paths
    in
    match out_of_scope with
    | [] -> Ok ()
    | bad ->
        Error
          (Printf.sprintf "commit paths outside owned scope: %s"
             (String.concat ", " bad))
