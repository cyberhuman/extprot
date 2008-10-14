
open Printf
open Ptypes
open Gencode
open Camlp4
open PreCast
open Ast
open ExtList

type container = {
  c_name : string;
  c_types : Ast.str_item option;
  c_reader : Ast.str_item option;
  c_writer : Ast.str_item option;
}

let (|>) x f = f x
let (@@) f x = f x

let foldl1 msg f g = function
    [] -> invalid_arg ("foldl1: empty list -- " ^ msg)
  | hd::tl -> List.fold_left g (f hd) tl

let foldr1 msg f g = function
    [] -> invalid_arg ("foldr1: empty list -- " ^ msg)
  | l -> match List.rev l with
        [] -> assert false
      | hd::tl -> List.fold_left (fun s x -> g x s) (f hd) tl

let generate_container bindings =
  let _loc = Loc.mk "gen_OCaml" in

  let typedecl name ?(params = []) ctyp =
    Ast.TyDcl (_loc, name, params, ctyp, []) in

  let typedef name ?(params = []) ctyp =
      <:str_item< type $typedecl name ~params ctyp $ >> in

  let rec message_types msgname = function
      `Record l ->
        let ctyp (name, mutabl, texpr) =
          let ty = ctyp_of_texpr texpr in match mutabl with
              true -> <:ctyp< $lid:name$ : mutable $ty$ >>
            | false -> <:ctyp< $lid:name$ : $ty$ >> in
        let fields =
          foldl1 "message_types `Record" ctyp
            (fun ct field -> <:ctyp< $ct$; $ctyp field$ >>) l
        (* no quotations for type, wtf? *)
        (* in <:str_item< type $msgname$ = { $fields$ } >> *)
        in typedef msgname <:ctyp< { $fields$ } >>

   | `Sum l ->
       let tydef_of_msg_branch (const, mexpr) =
         message_types (msgname ^ "_" ^ const) (mexpr :> message_expr) in
       let record_types =
         foldl1 "message_types `Sum" tydef_of_msg_branch
           (fun s b -> <:str_item< $s$; $tydef_of_msg_branch b$ >>) l in

       let variant (const, _) =
         <:ctyp< $uid:const$ of ($lid: msgname ^ "_" ^ const $) >> in
       let consts = foldl1 "message_types `Sum" variant
                      (fun vars c -> <:ctyp< $vars$ | $variant c$ >>) l

       in <:str_item< $record_types$; $typedef msgname <:ctyp< [$consts$] >>$ >>

  and ctyp_of_texpr expr =
    type_expr expr |> reduce_to_poly_texpr_core bindings |> ctyp_of_poly_texpr_core

  and ctyp_of_poly_texpr_core = function
      `Bool -> <:ctyp< bool >>
    | `Byte -> <:ctyp< char >>
    | `Int _ -> <:ctyp< int >>
    | `Long_int -> <:ctyp< Int64.t >>
    | `Float -> <:ctyp< float >>
    | `String -> <:ctyp< string >>
    | `List ty -> <:ctyp< list $ctyp_of_poly_texpr_core ty$ >>
    | `Array ty -> <:ctyp< array $ctyp_of_poly_texpr_core ty$ >>
    | `Tuple l ->
        foldr1 "ctyp_of_poly_texpr_core `Tuple" ctyp_of_poly_texpr_core
          (fun ptexpr tup -> <:ctyp< ( $ ctyp_of_poly_texpr_core ptexpr $ * $tup$ ) >>)
          l
    | `Type (name, args) ->
        let t = List.fold_left (* apply *)
                  (fun ty ptexpr -> <:ctyp< $ty$ $ctyp_of_poly_texpr_core ptexpr$ >>)
                  <:ctyp< $uid:String.capitalize name$.$lid:name$ >>
                  args
        in (try <:ctyp< $id:Ast.ident_of_ctyp t$ >> with Invalid_argument _ -> t)
    | `Type_arg n -> <:ctyp< '$n$ >>

  in function
      Message_decl (msgname, mexpr) ->
        Some {
          c_name = msgname;
          c_types = Some (message_types msgname mexpr);
          c_reader = None;
          c_writer = None
        }
    | Type_decl (name, params, texpr) ->
        let ty = match poly_beta_reduce_texpr bindings texpr with
            `Sum s -> begin
              let ty_of_const_texprs (const, ptexprs) =
                let tys = List.map ctyp_of_poly_texpr_core ptexprs in
                  <:ctyp< $uid:const$ of $Ast.tyAnd_of_list tys$>>

              in match s.constant with
                  [] -> foldl1 "generate_container Type_decl `Sum"
                          ty_of_const_texprs
                          (fun ctyp c -> <:ctyp< $ctyp$ | $ty_of_const_texprs c$ >>)
                          s.non_constant
                | _ ->
                    let const =
                      foldl1 "generate_container `Sum"
                        (fun tyn -> <:ctyp< $uid:tyn$ >>)
                        (fun ctyp tyn -> <:ctyp< $ctyp$ | $uid:tyn$ >>)
                        s.constant

                    in List.fold_left
                         (fun ctyp c -> <:ctyp< $ctyp$ | $ty_of_const_texprs c$ >>)
                         const s.non_constant
            end
          | #poly_type_expr_core ->
              reduce_to_poly_texpr_core bindings texpr |> ctyp_of_poly_texpr_core in
        let params =
          List.map (fun n -> <:ctyp< '$lid:type_param_name n$ >>) params
        in
          Some {
            c_name = name;
            c_types = Some <:str_item< type $typedecl name ~params ty$ >>;
            c_reader = None;
            c_writer = None
          }

let loc = Camlp4.PreCast.Loc.mk

let maybe_str_item =
  let _loc = loc "<generated code>" in
    Option.default <:str_item< >>

module PrOCaml =Camlp4.Printers.OCaml.Make(Camlp4.PreCast.Syntax)

let string_of_ast f ast =
  let b = Buffer.create 256 in
  let fmt = Format.formatter_of_buffer b in
  let o = new PrOCaml.printer () in
    Format.fprintf fmt "@[<v0>%a@]@." (f o) ast;
    Buffer.contents b

let generate_code containers =
  let _loc = loc "<generated code>" in
  let container_of_str_item c =
    <:str_item<
       module $String.capitalize c.c_name$ = struct
         $maybe_str_item c.c_types$;
         $maybe_str_item c.c_reader$;
         $maybe_str_item c.c_writer$
       end >>
  in string_of_ast (fun o -> o#implem)
       (List.fold_left
          (fun s c -> <:str_item< $s$; $container_of_str_item c$ >>)
          <:str_item< >>
          containers)

let list_mapi f l =
  let i = ref (-1) in
    List.map (fun x -> incr i; f !i x) l

let make_list f n = Array.to_list (Array.init f n)

let read_field msgname constr_name name llty =
  let _loc = loc "<generated code @ field_match_cases>" in

  let rec read_tuple_elms lltys_and_defs =
    (* TODO: handle missing elms *)
    let vars = List.rev @@ Array.to_list @@
               Array.init (List.length lltys_and_defs) (sprintf "v%d") in
    let tup = exCom_of_list @@ List.rev_map (fun v -> <:expr< $lid:v$ >>) vars in
      List.fold_right
        (fun (n, llty, default) e ->
           let varname = sprintf "v%d" n in
             match default with
                 None ->
                   <:expr<
                     let $lid:varname$ =
                       if nelms >= $int:string_of_int (n+1)$ then
                         $read llty$
                       else
                         Extprot.missing_element
                           $str:msgname$ $str:constr_name$ $str:name$
                           $int:string_of_int n$
                     in $e$
                   >>
               | Some expr ->
                   <:expr<
                     let $lid:varname$ =
                       if nelms >= $int:string_of_int (n+1)$ then
                         $read llty$
                       else $expr$
                     in $e$
                   >>)
        (list_mapi (fun i (ty, default) -> (i, ty, default)) lltys_and_defs)
        tup

  and lltys_without_defaults = List.map (fun x -> (x, None))

  and read = function
      Vint Bool -> <:expr< Extprot.Codec.read_bool s >>
    | Vint Int -> <:expr< Extprot.Codec.read_rel_int s >>
    | Vint Positive_int -> <:expr< Extprot.Codec.read_positive_int s>>
    | Bitstring32 -> <:expr< Extprot.Codec.read_i32 s >>
    | Bitstring64 Long -> <:expr< Extprot.Codec.read_i64 s >>
    | Bitstring64 Float -> <:expr< Extprot.Codec.read_float s >>
    | Bytes -> <:expr< Extprot.Codec.read_string s >>
    | Tuple lltys ->
        <:expr<
          let t = Extprot.Codec.read_prefix s in
            match Extprot.Codec.ll_type with [
                Extprot.Codec.Tuple ->
                  let len = Extprot.Codec.read_vint s in
                  let nelms = Extprot.Codec.read_vint s in
                    $read_tuple_elms (lltys_without_defaults lltys)$
              | _ -> Extprot.bad_field_format
                       $str:msgname$ $str:constr_name$ $str:name$
            ]
        >>
    | Sum (constant, non_constant) ->
        let constant_match_cases =
          List.map
            (fun c ->
               <:match_case<
                 $int:string_of_int c.const_tag$ ->
                   $uid:String.capitalize c.const_type$.$lid:c.const_name$
               >>)
            constant
          @ [ <:match_case<
                tag -> Extprot.unknown_field_tag
                       $str:msgname$ $str:constr_name$ $str:name$ tag >> ] in

        let nonconstant_match_cases =
          let mc (c, lltys) =
            <:match_case<
               $int:string_of_int c.const_tag$ ->
                 $uid:String.capitalize c.const_type$.$lid:c.const_name$
                 $read_tuple_elms (lltys_without_defaults lltys)$ >>
          in List.map mc non_constant @
             [ <:match_case<
                 tag -> Extprot.unknown_field_tag
                        $str:msgname$ $str:constr_name$ $str:name$ tag >> ]
        in

        let maybe_match_case (constr, l) = match l with
            [] | [_] (* catch-all *)-> None
          | l ->
              Some <:match_case<
                      Extprot.Codec.$uid:constr$ ->
                        match Extprot.Codec.ll_tag t with [ $Ast.mcOr_of_list l$ ] >> in

        let match_cases =
          List.filter_map maybe_match_case
            ["Vint", constant_match_cases; "Tuple", nonconstant_match_cases]
        in

          <:expr< let t = Extprot.Codec.read_prefix s in
            match Extprot.Codec.ll_type t with [
              $Ast.mcOr_of_list match_cases$
              | _ -> Extprot.bad_field_format
                       $str:msgname$ $str:constr_name$ $str:name$
            ]
          >>
    | Message name ->
        <:expr< $uid:String.capitalize name$.$lid:"read_" ^ name$ s >>
    | Htuple (kind, llty) ->
        let e = match kind with
            List ->
              <:expr<
                let rec loop acc = fun [
                    0 -> List.rev acc
                  | n -> let v = $read llty$ in loop [v :: acc] (n - 1)
                ] in loop [] nelms
              >>
            | Array ->
                <:expr<
                  match nelms with [
                      0 -> [||]
                    | n ->
                        let elm = $read llty$ in
                        let a = Array.make nelms elm in
                          for i = 1 to nelms - 1 do
                            a.(i) := $read llty$
                          done
                  ]
                >>
        in <:expr<
              let t = Extprot.Codec.read_prefix s in
                match Extprot.Codec.ll_type with [
                    Extprot.Codec.Htuple ->
                      let len = Extprot.Codec.read_vint s in
                      let nelms = Extprot.Codec.read_vint s in
                        $e$
                  | _ -> Extprot.bad_field_format
                           $str:msgname$ $str:constr_name$ $str:name$
                ]
            >>
  in
    read llty

let record_case msgname ?constr tag fields =
  let _loc = Loc.mk "<generated code @ record_case>" in
  let constr_name = Option.default "<default>" constr in

  let read_field fieldno (name, mutabl, llty) ?default expr =
    let rescue_match_case = match default with
        None ->
          <:match_case<
            Extprot.Bad_format _  e -> raise e
          >>
      | Some expr ->
          <:match_case<
            Extprot.Bad_format _ ->
              do {
                Extprot.Codec.skip_to s end_of_field;
                $expr$
              } >> in
    let default_value = match default with
        Some expr -> expr
      | None ->
          <:expr< Extprot.missing_field
                    $str:msgname$ $str:constr_name$ $str:name$ >> in
    let end_of_field_expr = match default with
        Some _ -> <:expr< Extprot.Codec.value_endpos s >>
      | None -> <:expr< () >>
    in
      <:expr<
         let $lid:name$ =
           if nelms >= $int:string_of_int (fieldno + 1)$ then
             let end_of_field = $end_of_field_expr$ in
             try
               $read_field msgname constr_name name llty$
             with [$rescue_match_case$]
           else
               $default_value$
         in $expr$
      >> in

  let field_assigns =
    List.map
      (fun (name, _, _) -> <:rec_binding< $lid:name$ = $lid:name$ >>)
      fields in
  let e =
    List.fold_right
      (fun (i, fieldinfo) e -> read_field i fieldinfo e)
      (list_mapi (fun i x -> (i, x)) fields)
      <:expr< { $Ast.rbSem_of_list field_assigns$ } >>
  in
    <:match_case<
      $int:string_of_int tag$ ->
        let len = Extprot.Codec.read_vint s in
        let nelms = Extprot.Codec.read_vint s in
          $e$
          >>

let rec read_message msgname =
  let _loc = Loc.mk "<generated code @ read_message>" in
  let wrap match_cases =
    <:expr<
      let t = Extprot.Codec.read_prefix s in begin
        if Extprot.Codec.ll_type <> Extprot.Codec.Tuple then
          Extprot.bad_message_type $str:msgname$ else ();
        match Extprot.Codec.ll_tag t with [
          $match_cases$
          | tag -> Extprot.unknown_message_tag $str:msgname$ tag
        ]
      end
    >>
  in
    function
      Record_single fields -> wrap (record_case msgname 0 fields)
    | Record_sum l ->
        list_mapi (fun tag (constr, fields) -> record_case msgname ~constr tag fields) l |>
          Ast.mcOr_of_list |> wrap


let add_message_reader bindings msgname mexpr c =
  let _loc = Loc.mk "<generated code @ add_message_reader>" in
  let llrec = Gencode.low_level_msg_def bindings mexpr in
  let read_expr = read_message msgname llrec in
  let reader = <:str_item< value $lid:"read_" ^ msgname$ = fun s -> $read_expr$>> in
    { c with c_reader = Some reader }

let vint_length = function
    n when n < 128 -> 1
  | n when n < 13384 -> 2
  | n when n < 2097152 -> 3
  | n when n < 268435456 -> 4
  | _ -> 5 (* FIXME: checking for 64-bit and 32-bit archs *)

let rec write_field fname =
  let _loc = Loc.mk "<generated code @ write>" in
  let simple_write_func = function
      Vint Bool -> "write_bool"
    | Vint Int -> "write_rel_int"
    | Vint Positive_int -> "write_positive_int"
    | Bitstring32 -> "write_int32"
    | Bitstring64 Long -> "write_int64"
    | Bitstring64 Float -> "write_float"
    | Bytes -> "write_string"
    | Tuple _ | Sum _ | Htuple _ | Message _ -> assert false in

  let rec write_tuple tag v lltys =
    let nelms = List.length lltys in
    let var_tys = list_mapi (fun i ty -> (sprintf "v%d" i, ty)) lltys in
    let write_elms =
      List.map (fun (v, ty) -> write <:expr< $lid:v$ >> ty) var_tys in
    let patt =
      Ast.paCom_of_list @@ List.map (fun (v, _) -> <:patt< $lid:v$ >>) var_tys
    in
      <:expr<
        let $patt$ = $v$ in
        let abuf =
          let aux = Extprot.Msg_buffer.create () in do {
            $Ast.exSem_of_list write_elms$;
            aux
          }
        in do {
          Extprot.Msg_buffer.add_tuple_prefix aux 0;
          Extprot.Msg_buffer.add_vint aux
            (Extprot.Msg_buffer.length abuf +
             $int:string_of_int @@ vint_length nelms$);
          Extprot.Msg_buffer.add_vint aux $int:string_of_int nelms$;
          Extprot.Msg_buffer.add_buffer aux abuf
        }
      >>

  and write v = function
      Vint _ | Bitstring32 | Bitstring64 _ | Bytes as llty ->
          <:expr< Extprot.Msg_buffer.$lid:simple_write_func llty$ aux $v$ >>
    | Message name ->
        <:expr< $uid:String.capitalize name$.$lid:"write_" ^ name$ aux $v$ >>
    | Tuple lltys -> write_tuple 0 v lltys
    | Htuple (kind, llty) ->
        let iter_f = match kind with
            Array -> <:expr< Array.iter >>
          | List -> <:expr< List.iter >>
        in
          <:expr<
            let write_elm aux v = $write <:expr< v >> llty$ in
            let nelms = ref 0 in
            let abuf = Extprot.Msg_buffer.create () in do {
                $iter_f$ (fun v -> do { write_elm abuf v; incr nelms } ) $v$;
                Extprot.Msg_buffer.add_htuple_prefix aux 0;
                Extprot.Msg_buffer.add_vint aux
                  (Extprot.Msg_buffer.length abuf +
                   Extprot.Codec.vint_length nelms.contents);
                Extprot.Msg_buffer.add_vint aux nelms.contents;
                Extprot.Msg_buffer.add_buffer aux abuf
              }
         >>
    | Sum (constant, non_constant) ->
        let constant_match_cases =
          List.map
            (fun c ->
               <:match_case<
                 $uid:String.capitalize c.const_type$.$lid:c.const_name$ ->
                   Extprot.Msg_buffer.add_const_prefix aux $int:string_of_int c.const_tag$
               >>)
            constant in
        let non_constant_cases =
          List.map
            (fun (c, lltys) ->
               <:match_case<
                   $uid:String.capitalize c.const_type$.$uid:c.const_name$ v ->
                     $write_tuple c.const_tag <:expr<v>> lltys$
               >>)
            non_constant in
        let match_cases = constant_match_cases @ non_constant_cases in
          <:expr< match $v$ with [ $Ast.mcOr_of_list match_cases$ ] >>

  in write <:expr< msg.$lid:fname$ >>

let write_fields fs =
  Ast.exSem_of_list @@ List.map (fun (name, _, llty) -> write_field name llty) fs

let rec write_message msgname =
  let _loc = Loc.mk "<generated code @ write_message>" in
  let dump_fields tag fields =
    let nelms = List.length fields in
      <:expr<
         let aux = Extprot.Msg_buffer.create () in
         let nelms = $int:string_of_int nelms$ in do {
           Extprot.Msg_buffer.add_tuple_prefix b 0;
           $write_fields fields$;
           Extprot.Msg_buffer.add_vint b
             (Extprot.Msg_buffer.length aux +
              $int:string_of_int @@ vint_length nelms$);
           Extprot.Msg_buffer.add_vint b $int:string_of_int nelms$;
           Extprot.Msg_buffer.add_buffer b aux
         }
      >>

  in function
      Record_single fields -> dump_fields 0 fields
    | Record_sum l ->
        let match_case (tag, constr, fields) =
          <:match_case< $uid:constr$ msg -> $dump_fields tag fields$ >> in
        let match_cases =
          Ast.mcOr_of_list @@ List.map match_case @@
          List.mapi (fun i (c, fs) -> (i, c, fs)) l
        in <:expr< match msg with [ $match_cases$ ] >>

let add_message_writer bindings msgname mexpr c =
  let _loc = Loc.mk "<generated code @ add_message_writer>" in
  let llrec = Gencode.low_level_msg_def bindings mexpr in
  let write_expr = write_message msgname llrec in
  let writer = <:str_item< value $lid:"write_" ^ msgname$ b msg = $write_expr$ >> in
    { c with c_writer = Some writer }

