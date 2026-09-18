(* Agent runtimes. kimi is the default lane (`kimi -p` is its
   autonomous agentic mode);
   codex is the second supported runner; Cmd is a scriptable runner for
   tests and smoke runs — it receives the prompt in $HARNESS_PROMPT. *)

type t = Kimi | Codex | Cmd of string

let of_string s =
  match s with
  | "kimi" -> Ok Kimi
  | "codex" -> Ok Codex
  | _ when String.starts_with ~prefix:"cmd:" s ->
      Ok (Cmd (String.sub s 4 (String.length s - 4)))
  | _ -> Error (Printf.sprintf "unknown runner %s (kimi | codex | cmd:<shell>)" s)

let to_string = function Kimi -> "kimi" | Codex -> "codex" | Cmd _ -> "cmd"

let kimi_bin () =
  Filename.concat (Sys.getenv "HOME") ".kimi-code/bin/kimi"

(* Fail fast at startup, not mid-run (validate at the boundary). *)
let preflight = function
  | Kimi ->
      if Sys.getenv_opt "KIMI_API_KEY" = None then
        Error "KIMI_API_KEY is not set (kimi runner needs it)"
      else if not (Sys.file_exists (kimi_bin ())) then
        Error (Printf.sprintf "kimi binary not found at %s" (kimi_bin ()))
      else Ok ()
  | Codex | Cmd _ -> Ok ()

let exec_req (t : t) ~prompt ~repo_root ~timeout_s ~log_hint : Effects.exec_req
    =
  match t with
  | Kimi ->
      {
        argv = [ kimi_bin (); "-p"; prompt ];
        cwd = repo_root;
        timeout_s;
        log_hint;
        env_extra = [];
      }
  | Codex ->
      {
        argv =
          [ "codex"; "exec"; "--sandbox"; "workspace-write"; "-C"; repo_root; prompt ];
        cwd = repo_root;
        timeout_s;
        log_hint;
        env_extra = [];
      }
  | Cmd shell ->
      {
        argv = [ "bash"; "-c"; shell ];
        cwd = repo_root;
        timeout_s;
        log_hint;
        env_extra = [ ("HARNESS_PROMPT", prompt) ];
      }
