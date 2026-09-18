type verdict = bool option

type kind =
  | Protocol_no_terminal
  | Empty_reply
  | Reply_over_cap of int
  | Markdown_in_reply
  | Placeholder_echoed of string list
  | Money_not_in_context
  | Unsanctioned_balance of {
      sanctioned_line_regex : string;
      balance_line_regex : string option;
      customer_roles : string list;
      sanctioned_case_insensitive : bool;
    }

type detector = {
  kind : kind;
  name : string;
  column_home : string;
  detect : Record.t -> verdict;
}

let default_name = function
  | Protocol_no_terminal -> "protocol_no_terminal"
  | Empty_reply -> "empty_reply"
  | Reply_over_cap _ -> "reply_over_cap"
  | Markdown_in_reply -> "markdown_in_reply"
  | Placeholder_echoed _ -> "placeholder_echoed"
  | Money_not_in_context -> "money_not_in_context"
  | Unsanctioned_balance _ -> "unsanctioned_balance"

let column_home = function
  | Protocol_no_terminal -> "protocol"
  | Empty_reply | Reply_over_cap _ | Markdown_in_reply -> "form"
  | Placeholder_echoed _ -> "leakage"
  | Money_not_in_context | Unsanctioned_balance _ -> "grounding"

let protocol_no_terminal (record : Record.t) = Some (not record.result.terminal)

let utf8_codepoint_at value index =
  let length = String.length value in
  let first = Char.code value.[index] in
  if first land 0x80 = 0 then (first, index + 1)
  else if first land 0xe0 = 0xc0 && index + 1 < length then
    (((first land 0x1f) lsl 6) lor (Char.code value.[index + 1] land 0x3f), index + 2)
  else if first land 0xf0 = 0xe0 && index + 2 < length then
    ( ((first land 0x0f) lsl 12)
      lor ((Char.code value.[index + 1] land 0x3f) lsl 6)
      lor (Char.code value.[index + 2] land 0x3f),
      index + 3 )
  else if first land 0xf8 = 0xf0 && index + 3 < length then
    ( ((first land 0x07) lsl 18)
      lor ((Char.code value.[index + 1] land 0x3f) lsl 12)
      lor ((Char.code value.[index + 2] land 0x3f) lsl 6)
      lor (Char.code value.[index + 3] land 0x3f),
      index + 4 )
  else (first, index + 1)

let python_whitespace codepoint =
  (codepoint >= 0x0009 && codepoint <= 0x000d)
  || (codepoint >= 0x001c && codepoint <= 0x0020)
  || (codepoint >= 0x2000 && codepoint <= 0x200a)
  || List.mem codepoint
       [ 0x0085; 0x00a0; 0x1680; 0x2028; 0x2029; 0x202f; 0x205f; 0x3000 ]

let empty_reply (record : Record.t) =
  match record.result.reply with
  | None -> None
  | Some reply ->
      let length = String.length reply in
      let rec only_whitespace index =
        if index >= length then true
        else
          let codepoint, next = utf8_codepoint_at reply index in
          python_whitespace codepoint && only_whitespace next
      in
      Some (only_whitespace 0)

let utf8_length value =
  let count = ref 0 in
  String.iter
    (fun character ->
      if Char.code character land 0xc0 <> 0x80 then incr count)
    value;
  !count

let reply_over_cap max_length =
  if max_length < 0 then invalid_arg "max_length must be non-negative";
  fun (record : Record.t) ->
    match record.result.reply with
    | None -> None
    | Some reply -> Some (utf8_length reply > max_length)

let compile_regex ?(opts = []) label pattern =
  if pattern = "" then invalid_arg (label ^ " must not be empty");
  try Re.Perl.compile_pat ~opts pattern with
  | Re.Perl.Parse_error | Re.Perl.Not_supported ->
      invalid_arg (label ^ " is not a supported regular expression")

let matches regex text = Re.execp regex text

let markdown_line_patterns =
  List.map (compile_regex "markdown pattern")
    [
      {|^[ \t]{0,3}(#{1,6}[ \t]+[^ \t]|>[ \t]+[^ \t]|([-+*]|[0-9]+[.)])[ \t]+[^ \t])|};
      {|^[ \t]{0,3}(`{3,}|~{3,})|};
      {|^[ \t]{0,3}((\*[ \t]*){3,}|(-[ \t]*){3,}|(_[ \t]*){3,})$|};
      {|^[ \t]*\|?[ \t]*:?-{3,}:?[ \t]*(\|[ \t]*:?-{3,}:?[ \t]*)+\|?[ \t]*$|};
    ]

let markdown_inline_patterns =
  List.map (compile_regex "markdown pattern")
    [
      {|!?\[[^]\n]+\]\([^)\n]+\)|};
      {|`[^`\n]+`|};
      {|(\*\*|__|~~)[^ \t\r\n](.*?[^ \t\r\n])?(\*\*|__|~~)|};
      {|(^|[^A-Za-z0-9_])(\*[^*\n]+\*|_[^_\n]+_)($|[^A-Za-z0-9_])|};
    ]

let raw_lines text = String.split_on_char '\n' text

let lines text =
  String.split_on_char '\n' text
  |> List.map (fun line ->
         let length = String.length line in
         if length > 0 && line.[length - 1] = '\r' then String.sub line 0 (length - 1)
         else line)

let markdown_in_reply (record : Record.t) =
  match record.result.reply with
  | None -> None
  | Some reply ->
      let line_match =
        List.exists
          (fun line -> List.exists (fun regex -> matches regex line) markdown_line_patterns)
          (raw_lines reply)
      in
      Some
        (line_match
        || List.exists (fun regex -> matches regex reply) markdown_inline_patterns)

let placeholder_echoed patterns =
  if patterns = [] then invalid_arg "at least one placeholder pattern is required";
  let patterns =
    List.map (compile_regex ~opts:[ `Caseless ] "placeholder pattern") patterns
  in
  fun (record : Record.t) ->
    match record.result.reply with
    | None -> None
    | Some reply -> Some (List.exists (fun regex -> matches regex reply) patterns)

let is_digit = function '0' .. '9' -> true | _ -> false

let substring_all predicate value start finish =
  let rec loop index =
    index >= finish || (predicate value.[index] && loop (index + 1))
  in
  loop start

let trim_leading_zeroes value =
  let length = String.length value in
  let rec first_nonzero index =
    if index >= length || value.[index] <> '0' then index else first_nonzero (index + 1)
  in
  let offset = first_nonzero 0 in
  if offset = length then "0" else String.sub value offset (length - offset)

let trim_trailing_zeroes value =
  let rec finish index =
    if index <= 0 || value.[index - 1] <> '0' then index else finish (index - 1)
  in
  String.sub value 0 (finish (String.length value))

let normalize_decimal integer fraction =
  let integer =
    integer |> String.to_seq |> Seq.filter (fun character -> character <> ',')
    |> String.of_seq |> trim_leading_zeroes
  in
  match fraction |> Option.map trim_trailing_zeroes with
  | None | Some "" -> integer
  | Some digits -> integer ^ "." ^ digits

let dollar_amounts text =
  let length = String.length text in
  let rec digits_end index =
    if index < length && is_digit text.[index] then digits_end (index + 1) else index
  in
  let boundary_ok index =
    index >= length
    || (not (is_digit text.[index])
       && not
            ((text.[index] = ',' || text.[index] = '.')
            && index + 1 < length && is_digit text.[index + 1]))
  in
  let parse_at dollar =
    let rec skip_space index =
      if index >= length then index
      else
        let codepoint, next = utf8_codepoint_at text index in
        if python_whitespace codepoint then skip_space next else index
    in
    let start = skip_space (dollar + 1) in
    if start >= length then None
    else if text.[start] = '.' then
      let finish = digits_end (start + 1) in
      if finish = start + 1 || not (boundary_ok finish) then None
      else
        let fraction = String.sub text (start + 1) (finish - start - 1) in
        Some (normalize_decimal "0" (Some fraction))
    else if not (is_digit text.[start]) then None
    else
      let plain_finish = digits_end start in
      let grouped_finish =
        let initial_length = plain_finish - start in
        if initial_length > 3 || plain_finish >= length || text.[plain_finish] <> ',' then None
        else
          let rec groups position consumed =
            if position < length && text.[position] = ',' && position + 3 < length
               && substring_all is_digit text (position + 1) (position + 4)
            then groups (position + 4) true
            else if consumed then Some position else None
          in
          groups plain_finish false
      in
      let finish_candidate integer_finish =
        let integer = String.sub text start (integer_finish - start) in
        let finish, fraction =
          if integer_finish < length && text.[integer_finish] = '.'
             && integer_finish + 1 < length && is_digit text.[integer_finish + 1]
          then
            let finish = digits_end (integer_finish + 1) in
            ( finish,
              Some
                (String.sub text (integer_finish + 1)
                   (finish - integer_finish - 1)) )
          else (integer_finish, None)
        in
        if not (boundary_ok finish) then None
        else Some (normalize_decimal integer fraction)
      in
      match grouped_finish with
      | Some finish -> (
          match finish_candidate finish with
          | Some _ as amount -> amount
          | None -> finish_candidate plain_finish)
      | None -> finish_candidate plain_finish
  in
  let rec scan index found =
    if index >= length then List.sort_uniq String.compare found
    else if text.[index] = '$' then
      let found = match parse_at index with None -> found | Some amount -> amount :: found in
      scan (index + 1) found
    else scan (index + 1) found
  in
  scan 0 []

let rec text_fragments = function
  | `String value -> [ value ]
  | `Assoc fields -> List.concat_map (fun (_, value) -> text_fragments value) fields
  | `List values -> List.concat_map text_fragments values
  | _ -> []

let tool_result_fragments (record : Record.t) =
  record.tool_calls
  |> List.concat_map (fun (call : Record.tool_call) -> text_fragments call.result)

let subset left right = List.for_all (fun value -> List.mem value right) left

let money_not_in_context (record : Record.t) =
  match record.result.reply with
  | None -> None
  | Some reply ->
      let reply_amounts = dollar_amounts reply in
      if reply_amounts = [] then None
      else
        let context_fragments =
          record.system_prompt
          :: (List.concat_map text_fragments record.history @ tool_result_fragments record)
        in
        let context_amounts =
          context_fragments |> List.concat_map dollar_amounts
          |> List.sort_uniq String.compare
        in
        Some (not (subset reply_amounts context_amounts))

let default_balance_line =
  compile_regex ~opts:[ `Caseless ] "balance_line_regex"
    {|\b(balance|amount\s+due|total\s+due|owe|owing|available\s+(funds?|credit)|account\s+(has|holds|contains)|you\s+(currently\s+)?have)\b|}

let normalized_roles roles =
  if roles = [] then invalid_arg "at least one customer role is required";
  List.map
    (fun role ->
      let role = String.trim role |> String.lowercase_ascii in
      if role = "" then invalid_arg "customer roles must not be empty";
      role)
    roles
  |> List.sort_uniq String.compare

let history_role message =
  match message with
  | `Assoc fields -> (
      match List.assoc_opt "role" fields with Some (`String role) -> Some role | _ -> None)
  | _ -> None

let customer_stated_amounts (record : Record.t) roles =
  record.history
  |> List.filter_map (fun message ->
         match (history_role message, message) with
         | Some role, `Assoc fields when List.mem (String.lowercase_ascii role) roles ->
             fields
             |> List.filter (fun (key, _) -> key <> "role")
             |> List.concat_map (fun (_, value) -> text_fragments value)
             |> List.concat_map dollar_amounts |> Option.some
         | _ -> None)
  |> List.concat |> List.sort_uniq String.compare

let unsanctioned_balance ?balance_line_regex ?(customer_roles = [ "user"; "customer"; "human" ])
    ?(sanctioned_case_insensitive = false) sanctioned_line_regex =
  let sanctioned_line =
    compile_regex
      ~opts:(if sanctioned_case_insensitive then [ `Caseless ] else [])
      "sanctioned_line_regex" sanctioned_line_regex
  in
  let balance_line =
    match balance_line_regex with
    | None -> default_balance_line
    | Some pattern -> compile_regex "balance_line_regex" pattern
  in
  let roles = normalized_roles customer_roles in
  fun (record : Record.t) ->
    match record.result.reply with
    | None -> None
    | Some reply ->
        let claimed_amounts =
          lines reply
          |> List.filter (matches balance_line)
          |> List.concat_map dollar_amounts |> List.sort_uniq String.compare
        in
        if claimed_amounts = [] then None
        else
          let sanctioned_tool_amounts =
            tool_result_fragments record |> List.concat_map lines
            |> List.filter (matches sanctioned_line)
            |> List.concat_map dollar_amounts
          in
          let sanctioned_amounts =
            customer_stated_amounts record roles @ sanctioned_tool_amounts
            |> List.sort_uniq String.compare
          in
          Some (not (subset claimed_amounts sanctioned_amounts))

let make ?name kind detect =
  {
    kind;
    name = Option.value ~default:(default_name kind) name;
    column_home = column_home kind;
    detect;
  }

let protocol_no_terminal_detector ?name () =
  make ?name Protocol_no_terminal protocol_no_terminal

let empty_reply_detector ?name () =
  make ?name Empty_reply empty_reply

let reply_over_cap_detector ?name max_length =
  make ?name (Reply_over_cap max_length) (reply_over_cap max_length)

let markdown_in_reply_detector ?name () =
  make ?name Markdown_in_reply markdown_in_reply

let placeholder_echoed_detector ?name patterns =
  make ?name (Placeholder_echoed patterns) (placeholder_echoed patterns)

let money_not_in_context_detector ?name () =
  make ?name Money_not_in_context money_not_in_context

let unsanctioned_balance_detector ?name ?balance_line_regex ?customer_roles
    ?sanctioned_case_insensitive sanctioned_line_regex =
  let customer_roles =
    Option.value ~default:[ "user"; "customer"; "human" ] customer_roles
  in
  let sanctioned_case_insensitive =
    Option.value ~default:false sanctioned_case_insensitive
  in
  make ?name
    (Unsanctioned_balance
       {
         sanctioned_line_regex;
         balance_line_regex;
         customer_roles;
         sanctioned_case_insensitive;
       })
    (unsanctioned_balance ?balance_line_regex ~customer_roles
       ~sanctioned_case_insensitive sanctioned_line_regex)

let run detectors records =
  List.map
    (fun (record : Record.t) ->
      ( record.key,
        List.map (fun detector -> (detector.name, detector.detect record)) detectors ))
    records

let results_to_yojson detectors results =
  let verdict_to_yojson = function None -> `Null | Some value -> `Bool value in
  `Assoc
    [
      ("detectors", `List (List.map (fun detector -> `String detector.name) detectors));
      ( "detector_results",
        `Assoc
          (List.map
             (fun (record_key, verdicts) ->
               ( record_key,
                 `Assoc
                   (List.map
                      (fun (name, verdict) -> (name, verdict_to_yojson verdict))
                      verdicts) ))
             results) );
    ]
