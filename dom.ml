(*
 * (c) 2007-2008 Anastasia Gornostaeva <ermine@ermine.pp.ru>
 *)

open Xml

exception Error of string

type 'a data =
  | Continue of
      (Xmlparser.production * Xmlparser.parser_t -> 'a data) *
        Xmlparser.parser_t
  | Result of 'a * Xmlparser.parser_t
  
type ns_mapping = prefix * namespace

type qname = ns_mapping * cdata

type node =
  | Root of nodeset ref
  | Element of node ref
      * qname
      * nodeset ref
      * nodeset ref
      * nodeset ref
  | Attribute of node ref * qname * cdata
  | NS of node ref * ns_mapping
  | Text of node ref * cdata
  | Comment of node ref * cdata
  | ProcessingInstruction of node ref * ncname * cdata
and nodeset = node list

let split_attrs attrs =
  List.fold_left (fun (nss, attrs) (name, value) ->
                    let prefix, lname = Xmlparser.split_name name in
                      if prefix = "" && lname = "xmlns" then
                        (("", `URI value) :: nss), attrs
                      else if prefix = "xmlns" && lname <> "" then
                        ((lname, `URI value) :: nss) , attrs
                      else
                        nss, (((prefix, lname), value) :: attrs)
                 ) ([], []) attrs

let add_namespaces namespaces nss =
  List.iter (fun (prefix, ns) -> Hashtbl.add namespaces prefix ns) nss

let remove_namespaces namespaces nss =
  List.iter (fun (prefix, ns) -> Hashtbl.remove namespaces prefix) nss

let parse_qname nss (prefix, lname) =
  try
    let ns_mapping = Hashtbl.find nss prefix in
      (prefix, ns_mapping), lname
  with Not_found ->
    (prefix, `None), lname

let parse_attrs nss attrs =
  List.map (fun (name, value) -> parse_qname nss name, value) attrs

let null_noderef () = ref (Root (ref []))

let bind_child parent child =
  match child with
    | Attribute (p, _, _)
    | Element (p, _, _, _, _)
    | Text (p, _)
    | Comment (p, _)
    | ProcessingInstruction (p, _, _)
    | NS (p, _) ->
        p := parent
    | Root (nodes) ->
        raise (Error "Root node cannot be bound to any parent")

let bind_children parent children =
  List.iter (bind_child parent) children;;

let add_child stack newel =
  if Stack.length stack > 0 then
    let el = Stack.pop stack in
      match el with
        | Element (parent, _qname, _nss, _attrs, els) ->
            bind_child el newel;
            els := newel :: !els;
            Stack.push el stack
        | Root nodes ->
            bind_child el newel;
            nodes := newel :: !nodes;
            Stack.push el stack
        | _ -> ()

let reparent refel node =
  match refel with
    | Element (elemp, name, nss, attrs, children) ->
        bind_child refel node;
        (match node with
           | Attribute (p, name, value) ->
               attrs := node::!attrs;
           | Text (p, str) ->
               children := node::!children;
           | Element (p, name, nss, attrs, ch) ->
               children := node::!children;
           | Comment (p, str) ->
               children := node::!children;
           | ProcessingInstruction (p, pi, str) ->
               children := node::!children;
           | NS (p, ns) ->
               nss := node::!nss
           | Root (nodes) ->
               failwith
                 "Element node cannot have a root node in its children"
        )
    | Root (oldnodes) ->
        bind_child refel node;
        (match node with
             Text (p, str) ->
               oldnodes := node::!oldnodes
           | Element (p, name, nss, attrs, ch) ->
               oldnodes := node::!oldnodes
           | Comment (p, str) ->
               oldnodes := node::!oldnodes
           | ProcessingInstruction (p, pi, str) ->
               oldnodes := node::!oldnodes
           | _ ->
               failwith "Cannot make node a children of root"
        )
    | _ ->
        failwith "Node cannot be a parent of any other"

let reparent_nodes refel nodes =
  List.iter (reparent refel) (List.rev nodes)


let create = Xmlparser.create
let reset = Xmlparser.reset

let make_parser ?(whitespace_preserve=false)
    ~unknown_encoding_handler ~entity_resolver =

  let namespaces = Hashtbl.create 1 in
  let root = Root(ref []) in
  let parse_attributes =
    List.map (fun (qname,value) -> Attribute (null_noderef (), qname, value))
  in
  let parse_namespaces =
    List.map (fun map -> NS (null_noderef (), map))
  in
  let new_element qname namespaces attributes children =
    let el = Element (null_noderef (),
                      qname,
                      ref namespaces,
                      ref attributes,
                      ref children)
    in
      (match el with
         | Element (newp, nname, nnss, nattrs, nch) ->
             bind_children el !nnss;
             bind_children el !nattrs;
             bind_children el !nch;
         | _ -> ()
      );
      el
  in
  let new_comment str =
    Comment (null_noderef (), str)
  in
  let new_pi name str =
    ProcessingInstruction (null_noderef (), name, str)
  in
  let new_text str =
    Text (null_noderef (), str)
  in

  let rec process_epiloque nodes (tag, state) =
    match tag with
      | Xmlparser.Comment comment ->
          let node = new_comment comment in
            process_epiloque (node :: nodes) (Xmlparser.parse state)
      | Xmlparser.Pi (target, data) ->
          let node = new_pi target data in
            process_epiloque (node :: nodes) (Xmlparser.parse state)
      | Xmlparser.Whitespace spaces ->
          if whitespace_preserve then
            let node = new_text spaces in
              process_epiloque (node :: nodes) (Xmlparser.parse state)
          else
            process_epiloque nodes (Xmlparser.parse state)
      | Xmlparser.EndOfBuffer ->
          Continue ((process_epiloque nodes), state)
      | Xmlparser.EndOfData ->
          reparent_nodes root (List.rev nodes);
          Result (root, state)
      | _ ->
          failwith "Invalid epiloque"

  and get_node qname nodes nextf (tag, state) =
    match tag with
      | Xmlparser.Comment comment ->
          let node = new_comment comment in
            get_node qname (node :: nodes) nextf (Xmlparser.parse state)
      | Xmlparser.Pi (target, data) ->
          let node = new_pi target data in
            get_node qname (node :: nodes) nextf (Xmlparser.parse state)
   | Xmlparser.Whitespace spaces ->
       if whitespace_preserve then
         let node = new_text spaces  in
           get_node qname (node :: nodes) nextf (Xmlparser.parse state)
       else
         get_node qname nodes nextf (Xmlparser.parse state)
   | Xmlparser.Text str ->
       let node = new_text str in
         get_node qname (node :: nodes) nextf (Xmlparser.parse state)
   | Xmlparser.StartElement (name, attrs) ->
       let lnss, attrs = split_attrs attrs in
         add_namespaces namespaces lnss;
         let attrs =  parse_attrs namespaces attrs in
         let qname' = parse_qname namespaces (Xmlparser.split_name name) in
         let newnextf childs (tag, state) =
           let node = new_element qname'
             (parse_namespaces lnss)
             (parse_attributes attrs)
             (List.rev childs)
           in
             remove_namespaces namespaces lnss;
             get_node qname (node :: nodes) nextf (Xmlparser.parse state)
         in
           get_node qname' [] newnextf (Xmlparser.parse state)
   | Xmlparser.EndElement name ->
       let qname' = parse_qname namespaces (Xmlparser.split_name name) in
         if qname = qname' then
           nextf nodes (tag, state)
         else
           let (_, expected) = qname in
             failwith (Printf.sprintf
                         "Bad end tag: expected %s, was %s"
                         expected name)
   | Xmlparser.EmptyElement (name, attrs) ->
       let lnss, attrs = split_attrs attrs in
         add_namespaces namespaces lnss;
         let attrs =  parse_attrs namespaces attrs in
         let qname' = parse_qname namespaces (Xmlparser.split_name name) in
         let node = new_element qname'
           (parse_namespaces lnss)
           (parse_attributes attrs)
           []
         in
           remove_namespaces namespaces lnss;
           get_node qname (node :: nodes) nextf (Xmlparser.parse state)
   | Xmlparser.Cdata cdata ->
       let node = new_text cdata in
         get_node qname (node :: nodes) nextf (Xmlparser.parse state)
   | Xmlparser.Doctype _dtd ->
       failwith "Doctype declaration inside of element"
   | Xmlparser.EndOfBuffer ->
       Continue ((get_node qname nodes nextf), state)
   | Xmlparser.EndOfData ->
       raise End_of_file

  and process_prolog nodes (tag, state) =
    match tag with
      | Xmlparser.Comment comment ->
          let node = new_comment comment in
            process_prolog (node :: nodes) (Xmlparser.parse state)
      | Xmlparser.Doctype _dtd ->
          (* todo *)
          process_prolog nodes (Xmlparser.parse state)
      | Xmlparser.Pi (target, data) ->
          let node = new_pi target data in
            process_prolog (node :: nodes) (Xmlparser.parse state)
      | Xmlparser.StartElement (name, attrs) ->
          let lnss, attrs = split_attrs attrs in
            add_namespaces namespaces lnss;
            let attrs =  parse_attrs namespaces attrs in
            let qname = parse_qname namespaces (Xmlparser.split_name name) in
            let newnextf childs (tag, state) =
              let node = new_element qname
                (parse_namespaces lnss)
                (parse_attributes attrs)
                (List.rev childs)
              in
                remove_namespaces namespaces lnss;
                process_epiloque (node :: nodes) (Xmlparser.parse state)
            in
              get_node qname [] newnextf (Xmlparser.parse state)
      | Xmlparser.EmptyElement (name, attrs) ->
          let lnss, attrs = split_attrs attrs in
            add_namespaces namespaces lnss;
            let attrs =  parse_attrs namespaces attrs in
            let qname = parse_qname namespaces (Xmlparser.split_name name) in
            let node = new_element qname
              (parse_namespaces lnss)
              (parse_attributes attrs)
              []
            in
              remove_namespaces namespaces lnss;
              process_epiloque (node :: nodes) (Xmlparser.parse state)
      | Xmlparser.Whitespace spaces ->
          if whitespace_preserve then
            let node = new_text spaces in
              process_prolog (node :: nodes) (Xmlparser.parse state)
          else
            process_prolog nodes (Xmlparser.parse state)
      | Xmlparser.EndOfBuffer ->
          Continue ((process_prolog nodes), state)
      | Xmlparser.EndOfData ->
          raise End_of_file
      | _ ->
          failwith ("Unexpected tag " ^ Xmlparser.string_of_production tag)
  in
    process_prolog []
    
let equal_qname qname1 qname2 =
  match qname1, qname2 with
    | ((_, ns1), name1), ((_, ns2), name2) when ns1 = ns2 && name1 = name2 ->
        true
    | _ -> false

let string_of_list f sep list =
  match list with
    | [] -> ""
    | x :: [] -> f x
    | x :: xs -> List.fold_left (fun res x -> res ^ sep ^ (f x)) (f x) xs

let string_of_qname = function
  | (("", _), lname) -> lname
  | ((prefix, _), lname) -> prefix ^ ":" ^ lname

let string_of_attr = function
  | Attribute (_parent, qname, value) ->
      (string_of_qname qname) ^ "='" ^ encode value ^ "'"
  | _ -> raise (Error "node is not an attribute in string_of_attr")

let string_of_ns = function
  | NS (p, (prefix, ns)) ->
      (match ns with
         | `None -> ""
         | `URI str ->
             if prefix = "" then
               "xmlns='" ^ encode str ^ "'"
             else
               "xmlns:" ^ prefix ^ "='" ^encode  str ^ "'"
      )
  | _ -> ""

let rec serialize out = function
  | Root nodes ->
      List.iter (serialize out) !nodes
  | Element (parent, qname, nss, attrs, children) ->
      out "<";
      out (string_of_qname qname);
      if List.length !attrs != 0 then (
        out " ";
        out (string_of_list string_of_attr " " !attrs)
      );
      if List.length !nss != 0 then (
        out " ";
        out (string_of_list string_of_ns " " !nss)
      );
      if !children = [] then
        out "/>"
      else (
        out ">";
        List.iter (serialize out) !children;
        out "</";
        out (string_of_qname qname);
        out ">"
      )
  | Text (parent, text) ->
      out (encode text)
  | Comment (parent, comment) ->
      out "<!--";
      out comment;
      out "-->"
  | ProcessingInstruction (parent, target, pi) ->
      out "<?";
      out target;
      out " ";
      out pi;
      out "?>"
  | _ -> ()
