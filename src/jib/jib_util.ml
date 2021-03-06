(**************************************************************************)
(*     Sail                                                               *)
(*                                                                        *)
(*  Copyright (c) 2013-2017                                               *)
(*    Kathyrn Gray                                                        *)
(*    Shaked Flur                                                         *)
(*    Stephen Kell                                                        *)
(*    Gabriel Kerneis                                                     *)
(*    Robert Norton-Wright                                                *)
(*    Christopher Pulte                                                   *)
(*    Peter Sewell                                                        *)
(*    Alasdair Armstrong                                                  *)
(*    Brian Campbell                                                      *)
(*    Thomas Bauereiss                                                    *)
(*    Anthony Fox                                                         *)
(*    Jon French                                                          *)
(*    Dominic Mulligan                                                    *)
(*    Stephen Kell                                                        *)
(*    Mark Wassell                                                        *)
(*                                                                        *)
(*  All rights reserved.                                                  *)
(*                                                                        *)
(*  This software was developed by the University of Cambridge Computer   *)
(*  Laboratory as part of the Rigorous Engineering of Mainstream Systems  *)
(*  (REMS) project, funded by EPSRC grant EP/K008528/1.                   *)
(*                                                                        *)
(*  Redistribution and use in source and binary forms, with or without    *)
(*  modification, are permitted provided that the following conditions    *)
(*  are met:                                                              *)
(*  1. Redistributions of source code must retain the above copyright     *)
(*     notice, this list of conditions and the following disclaimer.      *)
(*  2. Redistributions in binary form must reproduce the above copyright  *)
(*     notice, this list of conditions and the following disclaimer in    *)
(*     the documentation and/or other materials provided with the         *)
(*     distribution.                                                      *)
(*                                                                        *)
(*  THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS''    *)
(*  AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED     *)
(*  TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A       *)
(*  PARTICULAR PURPOSE ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR   *)
(*  CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,          *)
(*  SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT      *)
(*  LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF      *)
(*  USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND   *)
(*  ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY,    *)
(*  OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT    *)
(*  OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF    *)
(*  SUCH DAMAGE.                                                          *)
(**************************************************************************)

open Ast
open Ast_util
open Jib
open Value2
open PPrint

(* Define wrappers for creating bytecode instructions. Each function
   uses a counter to assign each instruction a unique identifier. *)

let instr_counter = ref 0

let instr_number () =
  let n = !instr_counter in
  incr instr_counter;
  n

let idecl ?loc:(l=Parse_ast.Unknown) ctyp id =
  I_aux (I_decl (ctyp, id), (instr_number (), l))

let ireset ?loc:(l=Parse_ast.Unknown) ctyp id =
  I_aux (I_reset (ctyp, id), (instr_number (), l))

let iinit ?loc:(l=Parse_ast.Unknown) ctyp id cval =
  I_aux (I_init (ctyp, id, cval), (instr_number (), l))

let iif ?loc:(l=Parse_ast.Unknown) cval then_instrs else_instrs ctyp =
  I_aux (I_if (cval, then_instrs, else_instrs, ctyp), (instr_number (), l))

let ifuncall ?loc:(l=Parse_ast.Unknown) clexp id cvals =
  I_aux (I_funcall (clexp, false, id, cvals), (instr_number (), l))

let iextern ?loc:(l=Parse_ast.Unknown) clexp id cvals =
  I_aux (I_funcall (clexp, true, id, cvals), (instr_number (), l))

let icall ?loc:(l=Parse_ast.Unknown) clexp extern id cvals =
  I_aux (I_funcall (clexp, extern, id, cvals), (instr_number (), l))

let icopy l clexp cval =
  I_aux (I_copy (clexp, cval), (instr_number (), l))

let iclear ?loc:(l=Parse_ast.Unknown) ctyp id =
  I_aux (I_clear (ctyp, id), (instr_number (), l))

let ireturn ?loc:(l=Parse_ast.Unknown) cval =
  I_aux (I_return cval, (instr_number (), l))

let iend ?loc:(l=Parse_ast.Unknown) () =
  I_aux (I_end, (instr_number (), l))

let iblock ?loc:(l=Parse_ast.Unknown) instrs =
  I_aux (I_block instrs, (instr_number (), l))

let itry_block ?loc:(l=Parse_ast.Unknown) instrs =
  I_aux (I_try_block instrs, (instr_number (), l))

let ithrow ?loc:(l=Parse_ast.Unknown) cval =
  I_aux (I_throw cval, (instr_number (), l))

let icomment ?loc:(l=Parse_ast.Unknown) str =
  I_aux (I_comment str, (instr_number (), l))

let ilabel ?loc:(l=Parse_ast.Unknown) label =
  I_aux (I_label label, (instr_number (), l))

let igoto ?loc:(l=Parse_ast.Unknown) label =
  I_aux (I_goto label, (instr_number (), l))

let iundefined ?loc:(l=Parse_ast.Unknown) ctyp =
  I_aux (I_undefined ctyp, (instr_number (), l))

let imatch_failure ?loc:(l=Parse_ast.Unknown) () =
  I_aux (I_match_failure, (instr_number (), l))

let iraw ?loc:(l=Parse_ast.Unknown) str =
  I_aux (I_raw str, (instr_number (), l))

let ijump ?loc:(l=Parse_ast.Unknown) cval label =
  I_aux (I_jump (cval, label), (instr_number (), l))

module Name = struct
  type t = name
  let compare id1 id2 =
    match id1, id2 with
    | Name (x, n), Name (y, m) ->
       let c1 = Id.compare x y in
       if c1 = 0 then compare n m else c1
    | Have_exception n, Have_exception m -> compare n m
    | Current_exception n, Current_exception m -> compare n m
    | Return n, Return m -> compare n m
    | Name _, _ -> 1
    | _, Name _ -> -1
    | Have_exception _, _ -> 1
    | _, Have_exception _ -> -1
    | Current_exception _, _ -> 1
    | _, Current_exception _ -> -1
end

module NameSet = Set.Make(Name)
module NameMap = Map.Make(Name)

let current_exception = Current_exception (-1)
let have_exception = Have_exception (-1)
let return = Return (-1)

let name id = Name (id, -1)

let rec frag_rename from_id to_id = function
  | F_id id when Name.compare id from_id = 0 -> F_id to_id
  | F_id id -> F_id id
  | F_ref id when Name.compare id from_id = 0 -> F_ref to_id
  | F_ref id -> F_ref id
  | F_lit v -> F_lit v
  | F_call (call, frags) -> F_call (call, List.map (frag_rename from_id to_id) frags)
  | F_op (f1, op, f2) -> F_op (frag_rename from_id to_id f1, op, frag_rename from_id to_id f2)
  | F_unary (op, f) -> F_unary (op, frag_rename from_id to_id f)
  | F_field (f, field) -> F_field (frag_rename from_id to_id f, field)
  | F_raw raw -> F_raw raw
  | F_poly f -> F_poly (frag_rename from_id to_id f)

let cval_rename from_id to_id (frag, ctyp) = (frag_rename from_id to_id frag, ctyp)

let rec clexp_rename from_id to_id = function
  | CL_id (id, ctyp) when Name.compare id from_id = 0 -> CL_id (to_id, ctyp)
  | CL_id (id, ctyp) -> CL_id (id, ctyp)
  | CL_field (clexp, field) ->
     CL_field (clexp_rename from_id to_id clexp, field)
  | CL_addr clexp ->
     CL_addr (clexp_rename from_id to_id clexp)
  | CL_tuple (clexp, n) ->
     CL_tuple (clexp_rename from_id to_id clexp, n)
  | CL_void -> CL_void

let rec instr_rename from_id to_id (I_aux (instr, aux)) =
  let instr = match instr with
    | I_decl (ctyp, id) when Name.compare id from_id = 0 -> I_decl (ctyp, to_id)
    | I_decl (ctyp, id) -> I_decl (ctyp, id)

    | I_init (ctyp, id, cval) when Name.compare id from_id = 0 ->
       I_init (ctyp, to_id, cval_rename from_id to_id cval)
    | I_init (ctyp, id, cval) ->
       I_init (ctyp, id, cval_rename from_id to_id cval)

    | I_if (cval, then_instrs, else_instrs, ctyp2) ->
       I_if (cval_rename from_id to_id cval,
             List.map (instr_rename from_id to_id) then_instrs,
             List.map (instr_rename from_id to_id) else_instrs,
             ctyp2)

    | I_jump (cval, label) -> I_jump (cval_rename from_id to_id cval, label)

    | I_funcall (clexp, extern, id, args) ->
       I_funcall (clexp_rename from_id to_id clexp, extern, id, List.map (cval_rename from_id to_id) args)

    | I_copy (clexp, cval) -> I_copy (clexp_rename from_id to_id clexp, cval_rename from_id to_id cval)

    | I_clear (ctyp, id) when Name.compare id from_id = 0 -> I_clear (ctyp, to_id)
    | I_clear (ctyp, id) -> I_clear (ctyp, id)

    | I_return cval -> I_return (cval_rename from_id to_id cval)

    | I_block instrs -> I_block (List.map (instr_rename from_id to_id) instrs)

    | I_try_block instrs -> I_try_block (List.map (instr_rename from_id to_id) instrs)

    | I_throw cval -> I_throw (cval_rename from_id to_id cval)

    | I_comment str -> I_comment str

    | I_raw str -> I_raw str

    | I_label label -> I_label label

    | I_goto label -> I_goto label

    | I_undefined ctyp -> I_undefined ctyp

    | I_match_failure -> I_match_failure

    | I_end -> I_end

    | I_reset (ctyp, id) when Name.compare id from_id = 0 -> I_reset (ctyp, to_id)
    | I_reset (ctyp, id) -> I_reset (ctyp, id)

    | I_reinit (ctyp, id, cval) when Name.compare id from_id = 0 ->
       I_reinit (ctyp, to_id, cval_rename from_id to_id cval)
    | I_reinit (ctyp, id, cval) ->
       I_reinit (ctyp, id, cval_rename from_id to_id cval)
  in
  I_aux (instr, aux)

(**************************************************************************)
(* 1. Instruction pretty printer                                          *)
(**************************************************************************)

let string_of_value = function
  | V_bits [] -> "UINT64_C(0)"
  | V_bits bs -> "UINT64_C(" ^ Sail2_values.show_bitlist bs ^ ")"
  | V_int i -> Big_int.to_string i ^ "l"
  | V_bool true -> "true"
  | V_bool false -> "false"
  | V_null -> "NULL"
  | V_unit -> "UNIT"
  | V_bit Sail2_values.B0 -> "UINT64_C(0)"
  | V_bit Sail2_values.B1 -> "UINT64_C(1)"
  | V_string str -> "\"" ^ str ^ "\""
  | V_ctor_kind str -> "Kind_" ^ Util.zencode_string str
  | _ -> failwith "Cannot convert value to string"

let string_of_name ?zencode:(zencode=true) =
  let ssa_num n = if n < 0 then "" else ("/" ^ string_of_int n) in
  function
  | Name (id, n) ->
     (if zencode then Util.zencode_string (string_of_id id) else string_of_id id) ^ ssa_num n
  | Have_exception n ->
     "have_exception" ^ ssa_num n
  | Return n ->
     "return" ^ ssa_num n
  | Current_exception n ->
     "(*current_exception)" ^ ssa_num n

let rec string_of_fragment ?zencode:(zencode=true) = function
  | F_id id -> string_of_name ~zencode:zencode id
  | F_ref id -> "&" ^ string_of_name ~zencode:zencode id
  | F_lit v -> string_of_value v
  | F_call (str, frags) ->
     Printf.sprintf "%s(%s)" str (Util.string_of_list ", " (string_of_fragment ~zencode:zencode) frags)
  | F_field (f, field) ->
     Printf.sprintf "%s.%s" (string_of_fragment' ~zencode:zencode f) field
  | F_op (f1, op, f2) ->
     Printf.sprintf "%s %s %s" (string_of_fragment' ~zencode:zencode f1) op (string_of_fragment' ~zencode:zencode f2)
  | F_unary (op, f) ->
     op ^ string_of_fragment' ~zencode:zencode f
  | F_raw raw -> raw
  | F_poly f -> string_of_fragment ~zencode:zencode f
and string_of_fragment' ?zencode:(zencode=true) f =
  match f with
  | F_op _ | F_unary _ -> "(" ^ string_of_fragment ~zencode:zencode f ^ ")"
  | _ -> string_of_fragment ~zencode:zencode f

(* String representation of ctyps here is only for debugging and
   intermediate language pretty-printer. *)
and string_of_ctyp = function
  | CT_lint -> "int"
  | CT_lbits true -> "lbits(dec)"
  | CT_lbits false -> "lbits(inc)"
  | CT_fbits (n, true) -> "fbits(" ^ string_of_int n ^ ", dec)"
  | CT_fbits (n, false) -> "fbits(" ^ string_of_int n ^ ", int)"
  | CT_sbits (n, true) -> "sbits(" ^ string_of_int n ^ ", dec)"
  | CT_sbits (n, false) -> "sbits(" ^ string_of_int n ^ ", inc)"
  | CT_fint n -> "int(" ^ string_of_int n ^ ")"
  | CT_bit -> "bit"
  | CT_unit -> "unit"
  | CT_bool -> "bool"
  | CT_real -> "real"
  | CT_tup ctyps -> "(" ^ Util.string_of_list ", " string_of_ctyp ctyps ^ ")"
  | CT_struct (id, _) | CT_enum (id, _) | CT_variant (id, _) -> string_of_id id
  | CT_string -> "string"
  | CT_vector (true, ctyp) -> "vector(dec, " ^ string_of_ctyp ctyp ^ ")"
  | CT_vector (false, ctyp) -> "vector(inc, " ^ string_of_ctyp ctyp ^ ")"
  | CT_list ctyp -> "list(" ^ string_of_ctyp ctyp ^ ")"
  | CT_ref ctyp -> "ref(" ^ string_of_ctyp ctyp ^ ")"
  | CT_poly -> "*"

(** This function is like string_of_ctyp, but recursively prints all
   constructors in variants and structs. Used for debug output. *)
and full_string_of_ctyp = function
  | CT_tup ctyps -> "(" ^ Util.string_of_list ", " full_string_of_ctyp ctyps ^ ")"
  | CT_struct (id, ctors) | CT_variant (id, ctors) ->
     "struct " ^ string_of_id id
     ^ "{ "
     ^ Util.string_of_list ", " (fun (id, ctyp) -> string_of_id id ^ " : " ^ full_string_of_ctyp ctyp) ctors
     ^ "}"
  | CT_vector (true, ctyp) -> "vector(dec, " ^ full_string_of_ctyp ctyp ^ ")"
  | CT_vector (false, ctyp) -> "vector(inc, " ^ full_string_of_ctyp ctyp ^ ")"
  | CT_list ctyp -> "list(" ^ full_string_of_ctyp ctyp ^ ")"
  | CT_ref ctyp -> "ref(" ^ full_string_of_ctyp ctyp ^ ")"
  | ctyp -> string_of_ctyp ctyp

let rec map_ctyp f = function
  | (CT_lint | CT_fint _ | CT_lbits _ | CT_fbits _ | CT_sbits _
     | CT_bit | CT_unit | CT_bool | CT_real | CT_string | CT_poly | CT_enum _) as ctyp -> f ctyp
  | CT_tup ctyps -> f (CT_tup (List.map (map_ctyp f) ctyps))
  | CT_ref ctyp -> f (CT_ref (map_ctyp f ctyp))
  | CT_vector (direction, ctyp) -> f (CT_vector (direction, map_ctyp f ctyp))
  | CT_list ctyp -> f (CT_list (map_ctyp f ctyp))
  | CT_struct (id, ctors) -> f (CT_struct (id, List.map (fun (id, ctyp) -> id, map_ctyp f ctyp) ctors))
  | CT_variant (id, ctors) -> f (CT_variant (id, List.map (fun (id, ctyp) -> id, map_ctyp f ctyp) ctors))

let rec ctyp_equal ctyp1 ctyp2 =
  match ctyp1, ctyp2 with
  | CT_lint, CT_lint -> true
  | CT_lbits d1, CT_lbits d2 -> d1 = d2
  | CT_sbits (m1, d1), CT_sbits (m2, d2) -> m1 = m2 && d1 = d2
  | CT_fbits (m1, d1), CT_fbits (m2, d2) -> m1 = m2 && d1 = d2
  | CT_bit, CT_bit -> true
  | CT_fint n, CT_fint m -> n = m
  | CT_unit, CT_unit -> true
  | CT_bool, CT_bool -> true
  | CT_struct (id1, _), CT_struct (id2, _) -> Id.compare id1 id2 = 0
  | CT_enum (id1, _), CT_enum (id2, _) -> Id.compare id1 id2 = 0
  | CT_variant (id1, _), CT_variant (id2, _) -> Id.compare id1 id2 = 0
  | CT_tup ctyps1, CT_tup ctyps2 when List.length ctyps1 = List.length ctyps2 ->
     List.for_all2 ctyp_equal ctyps1 ctyps2
  | CT_string, CT_string -> true
  | CT_real, CT_real -> true
  | CT_vector (d1, ctyp1), CT_vector (d2, ctyp2) -> d1 = d2 && ctyp_equal ctyp1 ctyp2
  | CT_list ctyp1, CT_list ctyp2 -> ctyp_equal ctyp1 ctyp2
  | CT_ref ctyp1, CT_ref ctyp2 -> ctyp_equal ctyp1 ctyp2
  | CT_poly, CT_poly -> true
  | _, _ -> false

let rec ctyp_compare ctyp1 ctyp2 =
  let lex_ord c1 c2 = if c1 = 0 then c2 else c1 in
  match ctyp1, ctyp2 with
  | CT_lint, CT_lint -> 0
  | CT_lint, _ -> 1
  | _, CT_lint -> -1

  | CT_fint n, CT_fint m -> compare n m
  | CT_fint _, _ -> 1
  | _, CT_fint _ -> -1

  | CT_fbits (n, ord1), CT_fbits (m, ord2) -> lex_ord (compare n m) (compare ord1 ord2)
  | CT_fbits _, _ -> 1
  | _, CT_fbits _ -> -1

  | CT_sbits (n, ord1), CT_sbits (m, ord2) -> lex_ord (compare n m) (compare ord1 ord2)
  | CT_sbits _, _ -> 1
  | _, CT_sbits _ -> -1

  | CT_lbits ord1 , CT_lbits ord2 -> compare ord1 ord2
  | CT_lbits _, _ -> 1
  | _, CT_lbits _ -> -1

  | CT_bit, CT_bit -> 0
  | CT_bit, _ -> 1
  | _, CT_bit -> -1

  | CT_unit, CT_unit -> 0
  | CT_unit, _ -> 1
  | _, CT_unit -> -1

  | CT_real, CT_real -> 0
  | CT_real, _ -> 1
  | _, CT_real -> -1

  | CT_poly, CT_poly -> 0
  | CT_poly, _ -> 1
  | _, CT_poly -> -1

  | CT_bool, CT_bool -> 0
  | CT_bool, _ -> 1
  | _, CT_bool -> -1

  | CT_string, CT_string -> 0
  | CT_string, _ -> 1
  | _, CT_string -> -1

  | CT_ref ctyp1, CT_ref ctyp2 -> ctyp_compare ctyp1 ctyp2
  | CT_ref _, _ -> 1
  | _, CT_ref _ -> -1

  | CT_list ctyp1, CT_list ctyp2 -> ctyp_compare ctyp1 ctyp2
  | CT_list _, _ -> 1
  | _, CT_list _ -> -1

  | CT_vector (d1, ctyp1), CT_vector (d2, ctyp2) ->
     lex_ord (ctyp_compare ctyp1 ctyp2) (compare d1 d2)
  | CT_vector _, _ -> 1
  | _, CT_vector _ -> -1

  | ctyp1, ctyp2 -> String.compare (full_string_of_ctyp ctyp1) (full_string_of_ctyp ctyp2)

module CT = struct
  type t = ctyp
  let compare ctyp1 ctyp2 = ctyp_compare ctyp1 ctyp2
end

module CTSet = Set.Make(CT)

let rec ctyp_unify ctyp1 ctyp2 =
  match ctyp1, ctyp2 with
  | CT_tup ctyps1, CT_tup ctyps2 when List.length ctyps1 = List.length ctyps2 ->
     List.concat (List.map2 ctyp_unify ctyps1 ctyps2)

  | CT_vector (b1, ctyp1), CT_vector (b2, ctyp2) when b1 = b2 ->
     ctyp_unify ctyp1 ctyp2

  | CT_list ctyp1, CT_list ctyp2 -> ctyp_unify ctyp1 ctyp2

  | CT_ref ctyp1, CT_ref ctyp2 -> ctyp_unify ctyp1 ctyp2

  | CT_poly, _ -> [ctyp2]

  | _, _ when ctyp_equal ctyp1 ctyp2 -> []
  | _, _ -> raise (Invalid_argument "ctyp_unify")

let rec ctyp_suprema = function
  | CT_lint -> CT_lint
  | CT_lbits d -> CT_lbits d
  | CT_fbits (_, d) -> CT_lbits d
  | CT_sbits (_, d) -> CT_lbits d
  | CT_fint _ -> CT_lint
  | CT_unit -> CT_unit
  | CT_bool -> CT_bool
  | CT_real -> CT_real
  | CT_bit -> CT_bit
  | CT_tup ctyps -> CT_tup (List.map ctyp_suprema ctyps)
  | CT_string -> CT_string
  | CT_enum (id, ids) -> CT_enum (id, ids)
  (* Do we really never want to never call ctyp_suprema on constructor
     fields?  Doing it causes issues for structs (see
     test/c/stack_struct.sail) but it might be wrong to not call it
     for nested variants... *)
  | CT_struct (id, ctors) -> CT_struct (id, ctors)
  | CT_variant (id, ctors) -> CT_variant (id, ctors)
  | CT_vector (d, ctyp) -> CT_vector (d, ctyp_suprema ctyp)
  | CT_list ctyp -> CT_list (ctyp_suprema ctyp)
  | CT_ref ctyp -> CT_ref (ctyp_suprema ctyp)
  | CT_poly -> CT_poly

let rec ctyp_ids = function
  | CT_enum (id, _) -> IdSet.singleton id
  | CT_struct (id, ctors) | CT_variant (id, ctors) ->
     IdSet.add id (List.fold_left (fun ids (_, ctyp) -> IdSet.union (ctyp_ids ctyp) ids) IdSet.empty ctors)
  | CT_tup ctyps -> List.fold_left (fun ids ctyp -> IdSet.union (ctyp_ids ctyp) ids) IdSet.empty ctyps
  | CT_vector (_, ctyp) | CT_list ctyp | CT_ref ctyp -> ctyp_ids ctyp
  | CT_lint | CT_fint _ | CT_lbits _ | CT_fbits _ | CT_sbits _ | CT_unit
    | CT_bool | CT_real | CT_bit | CT_string | CT_poly -> IdSet.empty

let rec unpoly = function
  | F_poly f -> unpoly f
  | F_call (call, fs) -> F_call (call, List.map unpoly fs)
  | F_field (f, field) -> F_field (unpoly f, field)
  | F_op (f1, op, f2) -> F_op (unpoly f1, op, unpoly f2)
  | F_unary (op, f) -> F_unary (op, unpoly f)
  | f -> f

let rec is_polymorphic = function
  | CT_lint | CT_fint _ | CT_lbits _ | CT_fbits _ | CT_sbits _ | CT_bit | CT_unit | CT_bool | CT_real | CT_string -> false
  | CT_tup ctyps -> List.exists is_polymorphic ctyps
  | CT_enum _ -> false
  | CT_struct (_, ctors) | CT_variant (_, ctors) -> List.exists (fun (_, ctyp) -> is_polymorphic ctyp) ctors
  | CT_vector (_, ctyp) | CT_list ctyp | CT_ref ctyp -> is_polymorphic ctyp
  | CT_poly -> true

let pp_id id =
  string (string_of_id id)

let pp_name id =
  string (string_of_name ~zencode:false id)

let pp_ctyp ctyp =
  string (string_of_ctyp ctyp |> Util.yellow |> Util.clear)

let pp_keyword str =
  string ((str |> Util.red |> Util.clear) ^ " ")

let pp_cval (frag, ctyp) =
  string (string_of_fragment ~zencode:false frag) ^^ string " : " ^^ pp_ctyp ctyp

let rec pp_clexp = function
  | CL_id (id, ctyp) -> pp_name id ^^ string " : " ^^ pp_ctyp ctyp
  | CL_field (clexp, field) -> parens (pp_clexp clexp) ^^ string "." ^^ string field
  | CL_tuple (clexp, n) -> parens (pp_clexp clexp) ^^ string "." ^^ string (string_of_int n)
  | CL_addr clexp -> string "*" ^^ pp_clexp clexp
  | CL_void -> string "void"

let rec pp_instr ?short:(short=false) (I_aux (instr, aux)) =
  match instr with
  | I_decl (ctyp, id) ->
     pp_keyword "var" ^^ pp_name id ^^ string " : " ^^ pp_ctyp ctyp
  | I_if (cval, then_instrs, else_instrs, ctyp) ->
     let pp_if_block = function
       | [] -> string "{}"
       | instrs -> surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
     in
     parens (pp_ctyp ctyp) ^^ space
     ^^ pp_keyword "if" ^^ pp_cval cval
     ^^ if short then
          empty
        else
          pp_keyword " then" ^^ pp_if_block then_instrs
          ^^ pp_keyword " else" ^^ pp_if_block else_instrs
  | I_jump (cval, label) ->
     pp_keyword "jump" ^^ pp_cval cval ^^ space ^^ string (label |> Util.blue |> Util.clear)
  | I_block instrs ->
     surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
  | I_try_block instrs ->
     pp_keyword "try" ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
  | I_reset (ctyp, id) ->
     pp_keyword "recreate" ^^ pp_name id ^^ string " : " ^^ pp_ctyp ctyp
  | I_init (ctyp, id, cval) ->
     pp_keyword "create" ^^ pp_name id ^^ string " : " ^^ pp_ctyp ctyp ^^ string " = " ^^ pp_cval cval
  | I_reinit (ctyp, id, cval) ->
     pp_keyword "recreate" ^^ pp_name id ^^ string " : " ^^ pp_ctyp ctyp ^^ string " = " ^^ pp_cval cval
  | I_funcall (x, _, f, args) ->
     separate space [ pp_clexp x; string "=";
                      string (string_of_id f |> Util.green |> Util.clear) ^^ parens (separate_map (string ", ") pp_cval args) ]
  | I_copy (clexp, cval) ->
     separate space [pp_clexp clexp; string "="; pp_cval cval]
  | I_clear (ctyp, id) ->
     pp_keyword "kill" ^^ pp_name id ^^ string " : " ^^ pp_ctyp ctyp
  | I_return cval ->
     pp_keyword "return" ^^ pp_cval cval
  | I_throw cval ->
     pp_keyword "throw" ^^ pp_cval cval
  | I_comment str ->
     string ("// " ^ str |> Util.magenta |> Util.clear)
  | I_label str ->
     string (str |> Util.blue |> Util.clear) ^^ string ":"
  | I_goto str ->
     pp_keyword "goto" ^^ string (str |> Util.blue |> Util.clear)
  | I_match_failure ->
     pp_keyword "match_failure"
  | I_end ->
     pp_keyword "end"
  | I_undefined ctyp ->
     pp_keyword "undefined" ^^ pp_ctyp ctyp
  | I_raw str ->
     pp_keyword "C" ^^ string (str |> Util.cyan |> Util.clear)

let pp_ctype_def = function
  | CTD_enum (id, ids) ->
     pp_keyword "enum" ^^ pp_id id ^^ string " = "
     ^^ separate_map (string " | ") pp_id ids
  | CTD_struct (id, fields) ->
     pp_keyword "struct" ^^ pp_id id ^^ string " = "
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) (fun (id, ctyp) -> pp_id id ^^ string " : " ^^ pp_ctyp ctyp) fields) rbrace
  | CTD_variant (id, ctors) ->
     pp_keyword "union" ^^ pp_id id ^^ string " = "
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) (fun (id, ctyp) -> pp_id id ^^ string " : " ^^ pp_ctyp ctyp) ctors) rbrace

let pp_cdef = function
  | CDEF_spec (id, ctyps, ctyp) ->
     pp_keyword "val" ^^ pp_id id ^^ string " : " ^^ parens (separate_map (comma ^^ space) pp_ctyp ctyps) ^^ string " -> " ^^ pp_ctyp ctyp
     ^^ hardline
  | CDEF_fundef (id, ret, args, instrs) ->
     let ret = match ret with
       | None -> empty
       | Some id -> space ^^ pp_id id
     in
     pp_keyword "function" ^^ pp_id id ^^ ret ^^ parens (separate_map (comma ^^ space) pp_id args) ^^ space
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
     ^^ hardline
  | CDEF_reg_dec (id, ctyp, instrs) ->
     pp_keyword "register" ^^ pp_id id ^^ string " : " ^^ pp_ctyp ctyp ^^ space
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
     ^^ hardline
  | CDEF_type tdef -> pp_ctype_def tdef ^^ hardline
  | CDEF_let (n, bindings, instrs) ->
     let pp_binding (id, ctyp) = pp_id id ^^ string " : " ^^ pp_ctyp ctyp in
     pp_keyword "let" ^^ string (string_of_int n) ^^ parens (separate_map (comma ^^ space) pp_binding bindings) ^^ space
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace ^^ space
     ^^ hardline
  | CDEF_startup (id, instrs)->
     pp_keyword "startup" ^^ pp_id id ^^ space
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
     ^^ hardline
  | CDEF_finish (id, instrs)->
     pp_keyword "finish" ^^ pp_id id ^^ space
     ^^ surround 2 0 lbrace (separate_map (semi ^^ hardline) pp_instr instrs) rbrace
     ^^ hardline

let rec fragment_deps = function
  | F_id id | F_ref id -> NameSet.singleton id
  | F_lit _ -> NameSet.empty
  | F_field (frag, _) | F_unary (_, frag) | F_poly frag -> fragment_deps frag
  | F_call (_, frags) -> List.fold_left NameSet.union NameSet.empty (List.map fragment_deps frags)
  | F_op (frag1, _, frag2) -> NameSet.union (fragment_deps frag1) (fragment_deps frag2)
  | F_raw _ -> NameSet.empty

let cval_deps = function (frag, _) -> fragment_deps frag

let rec clexp_deps = function
  | CL_id (id, _) -> NameSet.singleton id
  | CL_field (clexp, _) -> clexp_deps clexp
  | CL_tuple (clexp, _) -> clexp_deps clexp
  | CL_addr clexp -> clexp_deps clexp
  | CL_void -> NameSet.empty

(* Return the direct, read/write dependencies of a single instruction *)
let instr_deps = function
  | I_decl (ctyp, id) -> NameSet.empty, NameSet.singleton id
  | I_reset (ctyp, id) -> NameSet.empty, NameSet.singleton id
  | I_init (ctyp, id, cval) | I_reinit (ctyp, id, cval) -> cval_deps cval, NameSet.singleton id
  | I_if (cval, _, _, _) -> cval_deps cval, NameSet.empty
  | I_jump (cval, label) -> cval_deps cval, NameSet.empty
  | I_funcall (clexp, _, _, cvals) -> List.fold_left NameSet.union NameSet.empty (List.map cval_deps cvals), clexp_deps clexp
  | I_copy (clexp, cval) -> cval_deps cval, clexp_deps clexp
  | I_clear (_, id) -> NameSet.singleton id, NameSet.empty
  | I_throw cval | I_return cval -> cval_deps cval, NameSet.empty
  | I_block _ | I_try_block _ -> NameSet.empty, NameSet.empty
  | I_comment _ | I_raw _ -> NameSet.empty, NameSet.empty
  | I_label label -> NameSet.empty, NameSet.empty
  | I_goto label -> NameSet.empty, NameSet.empty
  | I_undefined _ -> NameSet.empty, NameSet.empty
  | I_match_failure -> NameSet.empty, NameSet.empty
  | I_end -> NameSet.empty, NameSet.empty

module NameCT = struct
  type t = name * ctyp
  let compare (n1, ctyp1) (n2, ctyp2) =
    let c = Name.compare n1 n2 in
    if c = 0 then CT.compare ctyp1 ctyp2 else c
end

module NameCTSet = Set.Make(NameCT)
module NameCTMap = Map.Make(NameCT)

let rec clexp_typed_writes = function
  | CL_id (id, ctyp) -> NameCTSet.singleton (id, ctyp)
  | CL_field (clexp, _) -> clexp_typed_writes clexp
  | CL_tuple (clexp, _) -> clexp_typed_writes clexp
  | CL_addr clexp -> clexp_typed_writes clexp
  | CL_void -> NameCTSet.empty

let instr_typed_writes (I_aux (aux, _)) =
  match aux with
  | I_decl (ctyp, id) | I_reset (ctyp, id) -> NameCTSet.singleton (id, ctyp)
  | I_init (ctyp, id, _) | I_reinit (ctyp, id, _) -> NameCTSet.singleton (id, ctyp)
  | I_funcall (clexp, _, _, _) | I_copy (clexp, _) -> clexp_typed_writes clexp
  | _ -> NameCTSet.empty

let rec map_clexp_ctyp f = function
  | CL_id (id, ctyp) -> CL_id (id, f ctyp)
  | CL_field (clexp, field) -> CL_field (map_clexp_ctyp f clexp, field)
  | CL_tuple (clexp, n) -> CL_tuple (map_clexp_ctyp f clexp, n)
  | CL_addr clexp -> CL_addr (map_clexp_ctyp f clexp)
  | CL_void -> CL_void

let rec map_instr_ctyp f (I_aux (instr, aux)) =
  let instr = match instr with
    | I_decl (ctyp, id) -> I_decl (f ctyp, id)
    | I_init (ctyp1, id, (frag, ctyp2)) -> I_init (f ctyp1, id, (frag, f ctyp2))
    | I_if ((frag, ctyp1), then_instrs, else_instrs, ctyp2) ->
       I_if ((frag, f ctyp1), List.map (map_instr_ctyp f) then_instrs, List.map (map_instr_ctyp f) else_instrs, f ctyp2)
    | I_jump ((frag, ctyp), label) -> I_jump ((frag, f ctyp), label)
    | I_funcall (clexp, extern, id, cvals) ->
       I_funcall (map_clexp_ctyp f clexp, extern, id, List.map (fun (frag, ctyp) -> frag, f ctyp) cvals)
    | I_copy (clexp, (frag, ctyp)) -> I_copy (map_clexp_ctyp f clexp, (frag, f ctyp))
    | I_clear (ctyp, id) -> I_clear (f ctyp, id)
    | I_return (frag, ctyp) -> I_return (frag, f ctyp)
    | I_block instrs -> I_block (List.map (map_instr_ctyp f) instrs)
    | I_try_block instrs -> I_try_block (List.map (map_instr_ctyp f) instrs)
    | I_throw (frag, ctyp) -> I_throw (frag, f ctyp)
    | I_undefined ctyp -> I_undefined (f ctyp)
    | I_reset (ctyp, id) -> I_reset (f ctyp, id)
    | I_reinit (ctyp1, id, (frag, ctyp2)) -> I_reinit (f ctyp1, id, (frag, f ctyp2))
    | I_end -> I_end
    | (I_comment _ | I_raw _ | I_label _ | I_goto _ | I_match_failure) as instr -> instr
  in
  I_aux (instr, aux)

(** Map over each instruction within an instruction, bottom-up *)
let rec map_instr f (I_aux (instr, aux)) =
  let instr = match instr with
    | I_decl _ | I_init _ | I_reset _ | I_reinit _
      | I_funcall _ | I_copy _ | I_clear _ | I_jump _ | I_throw _ | I_return _
      | I_comment _ | I_label _ | I_goto _ | I_raw _ | I_match_failure | I_undefined _ | I_end -> instr
    | I_if (cval, instrs1, instrs2, ctyp) ->
       I_if (cval, List.map (map_instr f) instrs1, List.map (map_instr f) instrs2, ctyp)
    | I_block instrs ->
       I_block (List.map (map_instr f) instrs)
    | I_try_block instrs ->
       I_try_block (List.map (map_instr f) instrs)
  in
  f (I_aux (instr, aux))

(** Iterate over each instruction within an instruction, bottom-up *)
let rec iter_instr f (I_aux (instr, aux)) =
  match instr with
  | I_decl _ | I_init _ | I_reset _ | I_reinit _
    | I_funcall _ | I_copy _ | I_clear _ | I_jump _ | I_throw _ | I_return _
    | I_comment _ | I_label _ | I_goto _ | I_raw _ | I_match_failure | I_undefined _ | I_end -> f (I_aux (instr, aux))
  | I_if (cval, instrs1, instrs2, ctyp) ->
     List.iter (iter_instr f) instrs1;
     List.iter (iter_instr f) instrs2
  | I_block instrs | I_try_block instrs ->
     List.iter (iter_instr f) instrs

(** Map over each instruction in a cdef using map_instr *)
let cdef_map_instr f = function
  | CDEF_reg_dec (id, ctyp, instrs) -> CDEF_reg_dec (id, ctyp, List.map (map_instr f) instrs)
  | CDEF_let (n, bindings, instrs) -> CDEF_let (n, bindings, List.map (map_instr f) instrs)
  | CDEF_fundef (id, heap_return, args, instrs) -> CDEF_fundef (id, heap_return, args, List.map (map_instr f) instrs)
  | CDEF_startup (id, instrs) -> CDEF_startup (id, List.map (map_instr f) instrs)
  | CDEF_finish (id, instrs) -> CDEF_finish (id, List.map (map_instr f) instrs)
  | CDEF_spec (id, ctyps, ctyp) -> CDEF_spec (id, ctyps, ctyp)
  | CDEF_type tdef -> CDEF_type tdef

let ctype_def_map_ctyp f = function
  | CTD_enum (id, ids) -> CTD_enum (id, ids)
  | CTD_struct (id, ctors) -> CTD_struct (id, List.map (fun (field, ctyp) -> (field, f ctyp)) ctors)
  | CTD_variant (id, ctors) -> CTD_variant (id, List.map (fun (field, ctyp) -> (field, f ctyp)) ctors)

(** Map over each ctyp in a cdef using map_instr_ctyp *)
let cdef_map_ctyp f = function
  | CDEF_reg_dec (id, ctyp, instrs) -> CDEF_reg_dec (id, f ctyp, List.map (map_instr_ctyp f) instrs)
  | CDEF_let (n, bindings, instrs) -> CDEF_let (n, bindings, List.map (map_instr_ctyp f) instrs)
  | CDEF_fundef (id, heap_return, args, instrs) -> CDEF_fundef (id, heap_return, args, List.map (map_instr_ctyp f) instrs)
  | CDEF_startup (id, instrs) -> CDEF_startup (id, List.map (map_instr_ctyp f) instrs)
  | CDEF_finish (id, instrs) -> CDEF_finish (id, List.map (map_instr_ctyp f) instrs)
  | CDEF_spec (id, ctyps, ctyp) -> CDEF_spec (id, List.map f ctyps, f ctyp)
  | CDEF_type tdef -> CDEF_type (ctype_def_map_ctyp f tdef)

(* Map over all sequences of instructions contained within an instruction *)
let rec map_instrs f (I_aux (instr, aux)) =
  let instr = match instr with
    | I_decl _ | I_init _ | I_reset _ | I_reinit _ -> instr
    | I_if (cval, instrs1, instrs2, ctyp) ->
       I_if (cval, f (List.map (map_instrs f) instrs1), f (List.map (map_instrs f) instrs2), ctyp)
    | I_funcall _ | I_copy _ | I_clear _ | I_jump _ | I_throw _ | I_return _ -> instr
    | I_block instrs -> I_block (f (List.map (map_instrs f) instrs))
    | I_try_block instrs -> I_try_block (f (List.map (map_instrs f) instrs))
    | I_comment _ | I_label _ | I_goto _ | I_raw _ | I_match_failure | I_undefined _  | I_end -> instr
  in
  I_aux (instr, aux)

let map_instr_list f instrs =
  List.map (map_instr f) instrs

let map_instrs_list f instrs =
  f (List.map (map_instrs f) instrs)

let rec instr_ids (I_aux (instr, _)) =
  let reads, writes = instr_deps instr in
  NameSet.union reads writes

let rec instr_reads (I_aux (instr, _)) =
  fst (instr_deps instr)

let rec instr_writes (I_aux (instr, _)) =
  snd (instr_deps instr)

let rec filter_instrs f instrs =
  let filter_instrs' = function
    | I_aux (I_block instrs, aux) -> I_aux (I_block (filter_instrs f instrs), aux)
    | I_aux (I_try_block instrs, aux) -> I_aux (I_try_block (filter_instrs f instrs), aux)
    | I_aux (I_if (cval, instrs1, instrs2, ctyp), aux) ->
       I_aux (I_if (cval, filter_instrs f instrs1, filter_instrs f instrs2, ctyp), aux)
    | instr -> instr
  in
  List.filter f (List.map filter_instrs' instrs)

(** GLOBAL: label_counter is used to make sure all labels have unique
   names. Like gensym_counter it should be safe to reset between
   top-level definitions. **)
let label_counter = ref 0

let label str =
  let str = str ^ string_of_int !label_counter in
  incr label_counter;
  str

let cval_ctyp = function (_, ctyp) -> ctyp

let rec clexp_ctyp = function
  | CL_id (_, ctyp) -> ctyp
  | CL_field (clexp, field) ->
     begin match clexp_ctyp clexp with
     | CT_struct (id, ctors) ->
        begin
          try snd (List.find (fun (id, ctyp) -> string_of_id id = field) ctors) with
          | Not_found -> failwith ("Struct type " ^ string_of_id id ^ " does not have a constructor " ^ field)
        end
     | ctyp -> failwith ("Bad ctyp for CL_field " ^ string_of_ctyp ctyp)
     end
  | CL_addr clexp ->
     begin match clexp_ctyp clexp with
     | CT_ref ctyp -> ctyp
     | ctyp -> failwith ("Bad ctyp for CL_addr " ^ string_of_ctyp ctyp)
     end
  | CL_tuple (clexp, n) ->
     begin match clexp_ctyp clexp with
     | CT_tup typs ->
        begin
          try List.nth typs n with
          | _ -> failwith "Tuple assignment index out of bounds"
        end
     | ctyp -> failwith ("Bad ctyp for CL_addr " ^ string_of_ctyp ctyp)
     end
  | CL_void -> CT_unit

let rec instr_ctyps (I_aux (instr, aux)) =
  match instr with
  | I_decl (ctyp, _) | I_reset (ctyp, _) | I_clear (ctyp, _) | I_undefined ctyp ->
     CTSet.singleton ctyp
  | I_init (ctyp, _, cval) | I_reinit (ctyp, _, cval) ->
     CTSet.add ctyp (CTSet.singleton (cval_ctyp cval))
  | I_if (cval, instrs1, instrs2, ctyp) ->
     CTSet.union (instrs_ctyps instrs1) (instrs_ctyps instrs2)
     |> CTSet.add (cval_ctyp cval)
     |> CTSet.add ctyp
  | I_funcall (clexp, _, _, cvals) ->
     List.fold_left (fun m ctyp -> CTSet.add ctyp m) CTSet.empty (List.map cval_ctyp cvals)
     |> CTSet.add (clexp_ctyp clexp)
  | I_copy (clexp, cval)  ->
     CTSet.add (clexp_ctyp clexp) (CTSet.singleton (cval_ctyp cval))
  | I_block instrs | I_try_block instrs ->
     instrs_ctyps instrs
  | I_throw cval | I_jump (cval, _) | I_return cval ->
     CTSet.singleton (cval_ctyp cval)
  | I_comment _ | I_label _ | I_goto _ | I_raw _ | I_match_failure | I_end ->
     CTSet.empty

and instrs_ctyps instrs = List.fold_left CTSet.union CTSet.empty (List.map instr_ctyps instrs)

let ctype_def_ctyps = function
  | CTD_enum _ -> []
  | CTD_struct (_, fields) -> List.map snd fields
  | CTD_variant (_, ctors) -> List.map snd ctors

let cdef_ctyps = function
  | CDEF_reg_dec (_, ctyp, instrs) ->
     CTSet.add ctyp (instrs_ctyps instrs)
  | CDEF_spec (_, ctyps, ctyp) ->
     CTSet.add ctyp (List.fold_left (fun m ctyp -> CTSet.add ctyp m) CTSet.empty ctyps)
  | CDEF_fundef (_, _, _, instrs) | CDEF_startup (_, instrs) | CDEF_finish (_, instrs) ->
     instrs_ctyps instrs
  | CDEF_type tdef ->
     List.fold_right CTSet.add (ctype_def_ctyps tdef) CTSet.empty
  | CDEF_let (_, bindings, instrs) ->
     List.fold_left (fun m ctyp -> CTSet.add ctyp m) CTSet.empty (List.map snd bindings)
     |> CTSet.union (instrs_ctyps instrs)

let rec c_ast_registers = function
  | CDEF_reg_dec (id, ctyp, instrs) :: ast -> (id, ctyp, instrs) :: c_ast_registers ast
  | _ :: ast -> c_ast_registers ast
  | [] -> []

let instr_split_at f =
  let rec instr_split_at' f before = function
    | [] -> (List.rev before, [])
    | instr :: instrs when f instr -> (List.rev before, instr :: instrs)
    | instr :: instrs -> instr_split_at' f (instr :: before) instrs
  in
  instr_split_at' f []

let rec instrs_rename from_id to_id =
  let rename id = if Name.compare id from_id = 0 then to_id else id in
  let crename = cval_rename from_id to_id in
  let irename instrs = instrs_rename from_id to_id instrs in
  let lrename = clexp_rename from_id to_id in
  function
  | (I_aux (I_decl (ctyp, new_id), _) :: _) as instrs when Name.compare from_id new_id = 0 -> instrs
  | I_aux (I_decl (ctyp, new_id), aux) :: instrs -> I_aux (I_decl (ctyp, new_id), aux) :: irename instrs
  | I_aux (I_reset (ctyp, id), aux) :: instrs -> I_aux (I_reset (ctyp, rename id), aux) :: irename instrs
  | I_aux (I_init (ctyp, id, cval), aux) :: instrs -> I_aux (I_init (ctyp, rename id, crename cval), aux) :: irename instrs
  | I_aux (I_reinit (ctyp, id, cval), aux) :: instrs -> I_aux (I_reinit (ctyp, rename id, crename cval), aux) :: irename instrs
  | I_aux (I_if (cval, then_instrs, else_instrs, ctyp), aux) :: instrs ->
     I_aux (I_if (crename cval, irename then_instrs, irename else_instrs, ctyp), aux) :: irename instrs
  | I_aux (I_jump (cval, label), aux) :: instrs -> I_aux (I_jump (crename cval, label), aux) :: irename instrs
  | I_aux (I_funcall (clexp, extern, function_id, cvals), aux) :: instrs ->
     I_aux (I_funcall (lrename clexp, extern, function_id, List.map crename cvals), aux) :: irename instrs
  | I_aux (I_copy (clexp, cval), aux) :: instrs -> I_aux (I_copy (lrename clexp, crename cval), aux) :: irename instrs
  | I_aux (I_clear (ctyp, id), aux) :: instrs -> I_aux (I_clear (ctyp, rename id), aux) :: irename instrs
  | I_aux (I_return cval, aux) :: instrs -> I_aux (I_return (crename cval), aux) :: irename instrs
  | I_aux (I_block block, aux) :: instrs -> I_aux (I_block (irename block), aux) :: irename instrs
  | I_aux (I_try_block block, aux) :: instrs -> I_aux (I_try_block (irename block), aux) :: irename instrs
  | I_aux (I_throw cval, aux) :: instrs -> I_aux (I_throw (crename cval), aux) :: irename instrs
  | (I_aux ((I_comment _ | I_raw _ | I_end | I_label _ | I_goto _ | I_match_failure | I_undefined _), _) as instr) :: instrs -> instr :: irename instrs
  | [] -> []
