(* Scope audit. Policy bounds what the HARNESS does; the agent itself is an
   opaque subprocess that can write anywhere in the checkout. Pathspec
   commits keep its stray edits out of history, but a stray edit left in a
   shared working tree is still damage — and a task that made one did not
   stay in scope, whatever its acceptance command says.

   The audit snapshots the dirty set (path -> kind, content hash) before a
   task's first attempt and after every attempt, and looks at what changed
   outside the task's owned paths:

   - a TRACKED file modified or deleted is a violation: the attempt is
     rejected, the agent is told which paths to restore, and an unrepaired
     violation parks the task;
   - a NEW untracked file is a stray: journaled, never committed (commits
     are pathspec-only), and not blocking — agents leave scratch files, and
     ignored build output is already excluded.

   Snapshots are Tool_exec effects, so the audit is journaled and replayable
   like everything else. *)

type kind = Tracked | Untracked

let snapshot_script =
  {|emit() { while IFS= read -r f; do if [ -f "$f" ]; then printf '%s\t%s\t%s\n' "$1" "$(git hash-object -- "$f")" "$f"; else printf '%s\tdeleted\t%s\n' "$1" "$f"; fi; done; }; git ls-files -m -d | sort -u | emit T; git ls-files -o --exclude-standard | emit U|}

let parse (output : string) : (string * (kind * string)) list =
  String.split_on_char '\n' output
  |> List.filter_map (fun line ->
         match String.split_on_char '\t' line with
         | k :: hash :: rest when rest <> [] ->
             let kind = if k = "T" then Tracked else Untracked in
             Some (String.concat "\t" rest, (kind, hash))
         | _ -> None)

let snapshot ~repo_root ~timeout_s ~log_hint : (string * (kind * string)) list =
  let res =
    Effect.perform
      (Effects.Tool_exec
         {
           argv = [ "sh"; "-c"; snapshot_script ];
           cwd = repo_root;
           timeout_s;
           log_hint;
           env_extra = [];
         })
  in
  if res.exit_code <> 0 then
    failwith (Printf.sprintf "scope snapshot failed (exit %d)" res.exit_code)
  else parse res.output

let under ~prefix path =
  let prefix =
    if String.ends_with ~suffix:"/" prefix then
      String.sub prefix 0 (String.length prefix - 1)
    else prefix
  in
  path = prefix || String.starts_with ~prefix:(prefix ^ "/") path

type audit = {
  violations : string list; (* tracked files changed outside scope: blocking *)
  strays : string list; (* new untracked files outside scope: reported *)
}

(* [ignore_prefixes] are repo-relative dirs the harness itself writes to
   (its work dir), which change between snapshots by design. *)
let audit ~(owns : string list) ~(ignore_prefixes : string list)
    ~(before : (string * (kind * string)) list)
    ~(after : (string * (kind * string)) list) : audit =
  let out_of_scope path =
    (not (List.exists (fun o -> under ~prefix:o path) owns))
    && not (List.exists (fun p -> under ~prefix:p path) ignore_prefixes)
  in
  let changed_now =
    List.filter
      (fun (path, state) -> List.assoc_opt path before <> Some state)
      after
  in
  (* dirty before, clean now: a tracked file the agent reverted to HEAD. That
     is a change to someone else's uncommitted work. *)
  let cleaned =
    List.filter_map
      (fun (path, (kind, _)) ->
        if kind = Tracked && not (List.mem_assoc path after) then Some path
        else None)
      before
  in
  let pick kind =
    List.filter_map
      (fun (path, (k, _)) -> if k = kind then Some path else None)
      changed_now
  in
  {
    violations =
      List.sort_uniq compare (List.filter out_of_scope (pick Tracked @ cleaned));
    strays = List.sort_uniq compare (List.filter out_of_scope (pick Untracked));
  }

let relative_to ~root path =
  let root = if String.ends_with ~suffix:"/" root then root else root ^ "/" in
  if String.starts_with ~prefix:root path then
    Some (String.sub path (String.length root) (String.length path - String.length root))
  else None
