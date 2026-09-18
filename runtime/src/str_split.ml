(* Split a string on an exact multi-character marker (no regex). *)

let split_on_marker ~marker text =
  let mlen = String.length marker in
  let tlen = String.length text in
  let rec go acc start pos =
    if pos + mlen > tlen then List.rev (String.sub text start (tlen - start) :: acc)
    else if String.sub text pos mlen = marker then
      go (String.sub text start (pos - start) :: acc) (pos + mlen) (pos + mlen)
    else go acc start (pos + 1)
  in
  go [] 0 0
