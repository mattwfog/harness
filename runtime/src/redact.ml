(* Credentials do not belong in memory, and they do not belong in a request
   that leaves the machine. Both are decided here, deterministically — a
   judgment model is the wrong tool for "is this a secret". *)

let strong_prefixes =
  [ "sk-"; "ghp_"; "gho_"; "github_pat_"; "AKIA"; "xoxb-"; "xoxp-"; "apikey_"; "AIza" ]

let is_token_char c =
  match c with
  | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '_' | '-' | '.' | '+' | '/' | '=' -> true
  | _ -> false

(* Split into maximal runs of token characters and everything between. *)
let tokens (s : string) : (bool * string) list =
  let n = String.length s in
  let rec go i start in_tok acc =
    if i = n then
      List.rev (if i > start then (in_tok, String.sub s start (i - start)) :: acc else acc)
    else
      let t = is_token_char s.[i] in
      if t = in_tok then go (i + 1) start in_tok acc
      else
        go (i + 1) i t
          (if i > start then (in_tok, String.sub s start (i - start)) :: acc else acc)
  in
  if n = 0 then [] else go 0 0 (is_token_char s.[0]) []

let has_prefix tok =
  List.exists (fun p -> String.starts_with ~prefix:p tok && String.length tok >= String.length p + 8) strong_prefixes

(* A long run mixing letters and digits with no path or word structure: the
   shape of a key, a hash or a token. Paths and dotted names are left alone. *)
let looks_opaque tok =
  let n = String.length tok in
  n >= 24
  && (not (String.contains tok '/'))
  && (not (String.contains tok '.'))
  &&
  let digits = ref 0 and letters = ref 0 in
  String.iter
    (fun c ->
      match c with
      | '0' .. '9' -> incr digits
      | 'a' .. 'z' | 'A' .. 'Z' -> incr letters
      | _ -> ())
    tok;
  !digits >= 4 && !letters >= 4

let is_secret tok = has_prefix tok || looks_opaque tok

let contains_secret (s : string) : bool =
  let lower = String.lowercase_ascii s in
  let mentions needle =
    let n = String.length needle and h = String.length lower in
    let rec at i = i + n <= h && (String.sub lower i n = needle || at (i + 1)) in
    at 0
  in
  mentions "-----begin" || List.exists (fun (is_tok, t) -> is_tok && is_secret t) (tokens s)

let scrub (s : string) : string =
  String.concat ""
    (List.map (fun (is_tok, t) -> if is_tok && is_secret t then "[REDACTED]" else t) (tokens s))
