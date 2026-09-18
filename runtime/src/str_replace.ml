(* Replace the first occurrence of an exact substring (no regex). *)

let replace_first ~needle ~replacement hay =
  let n = String.length needle and h = String.length hay in
  let rec find i = if i + n > h then None else if String.sub hay i n = needle then Some i else find (i + 1) in
  match find 0 with
  | None -> hay
  | Some i ->
      String.sub hay 0 i ^ replacement ^ String.sub hay (i + n) (h - i - n)
