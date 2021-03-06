(*
 * (c) 2004-2012 Anastasia Gornostaeva
 *)

{
  type substr_t =
    | Substring of string
    | EOF
}

rule token = parse
  | [^ '&']+
      { Substring (Lexing.lexeme lexbuf) }
  | "&lt;"
      { Substring "<" }
  | "&gt;"
      { Substring ">" }
  | "&amp;"
      { Substring "&" }
  | "&quot;"
      { Substring "\"" }
  | "&apos;"
      { Substring "'" }
  | eof
	    { EOF }

{
  let decode text =
    let lexbuf = Lexing.from_string text in
    let rec aux_exec acc =
      match token lexbuf with
        | Substring substr ->
            aux_exec (substr :: acc)
        | EOF ->
		        String.concat "" (List.rev acc)
    in
      aux_exec []
}
