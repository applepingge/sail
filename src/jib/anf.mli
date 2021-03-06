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

(** The A-normal form (ANF) grammar *)

open Ast
open Ast_util
open Jib
open Type_check

(** The first step in compiling Sail is converting the Sail expression
   grammar into A-normal form (ANF). Essentially this converts
   expressions such as [f(g(x), h(y))] into something like:

   [let v0 = g(x) in let v1 = h(x) in f(v0, v1)]

   Essentially the arguments to every function must be trivial, and
   complex expressions must be let bound to new variables, or used in
   a block, assignment, or control flow statement (if, for, and
   while/until loops). The aexp datatype represents these expressions,
   while aval represents the trivial values.

   The convention is that the type of an aexp is given by last
   argument to a constructor. It is omitted where it is obvious - for
   example all for loops have unit as their type. If some constituent
   part of the aexp has an annotation, the it refers to the previous
   argument, so in

   [AE_let (id, typ1, _, body, typ2)]

   [typ1] is the type of the bound identifer, whereas [typ2] is the type
   of the whole let expression (and therefore also the body).

   See Flanagan et al's {e The Essence of Compiling with Continuations}.
   *)

type 'a aexp = AE_aux of 'a aexp_aux * Env.t * l

and 'a aexp_aux =
  | AE_val of 'a aval
  | AE_app of id * ('a aval) list * 'a
  | AE_cast of 'a aexp * 'a
  | AE_assign of id * 'a * 'a aexp
  | AE_let of mut * id * 'a * 'a aexp * 'a aexp * 'a
  | AE_block of ('a aexp) list * 'a aexp * 'a
  | AE_return of 'a aval * 'a
  | AE_throw of 'a aval * 'a
  | AE_if of 'a aval * 'a aexp * 'a aexp * 'a
  | AE_field of 'a aval * id * 'a
  | AE_case of 'a aval * ('a apat * 'a aexp * 'a aexp) list * 'a
  | AE_try of 'a aexp * ('a apat * 'a aexp * 'a aexp) list * 'a
  | AE_record_update of 'a aval * ('a aval) Bindings.t * 'a
  | AE_for of id * 'a aexp * 'a aexp * 'a aexp * order * 'a aexp
  | AE_loop of loop * 'a aexp * 'a aexp
  | AE_short_circuit of sc_op * 'a aval * 'a aexp

and sc_op = SC_and | SC_or

and 'a apat = AP_aux of 'a apat_aux * Env.t * l

and 'a apat_aux =
  | AP_tup of ('a apat) list
  | AP_id of id * 'a
  | AP_global of id * 'a
  | AP_app of id * 'a apat * 'a
  | AP_cons of 'a apat * 'a apat
  | AP_as of 'a apat * id * 'a
  | AP_nil of 'a
  | AP_wild of 'a

(** We allow ANF->ANF optimization to insert fragments of C code
   directly in the ANF grammar via [AV_C_fragment]. Such fragments
   must be side-effect free expressions. *)
and 'a aval =
  | AV_lit of lit * 'a
  | AV_id of id * 'a lvar
  | AV_ref of id * 'a lvar
  | AV_tuple of ('a aval) list
  | AV_list of ('a aval) list * 'a
  | AV_vector of ('a aval) list * 'a
  | AV_record of ('a aval) Bindings.t * 'a
  | AV_C_fragment of fragment * 'a * ctyp

(** Function for generating unique identifiers during ANF
   translation. *)
val gensym : unit -> id

(** {2 Functions for transforming ANF expressions} *)

(** Map over all values in an ANF expression *)
val map_aval : (Env.t -> Ast.l -> 'a aval -> 'a aval) -> 'a aexp -> 'a aexp

(** Map over all function calls in an ANF expression *)
val map_functions : (Env.t -> Ast.l -> id -> ('a aval) list -> 'a -> 'a aexp_aux) -> 'a aexp -> 'a aexp

(** Remove all variable shadowing in an ANF expression *)
val no_shadow : IdSet.t -> 'a aexp -> 'a aexp

val apat_globals : 'a apat -> (id * 'a) list
val apat_types : 'a apat -> 'a Bindings.t

(** Returns true if an ANF expression is dead due to flow typing
   implying it is unreachable. Note: This function calls SMT. *)
val is_dead_aexp : 'a aexp -> bool

(** {2 Compiling to ANF expressions} *)

val anf_pat : ?global:bool -> tannot pat -> typ apat

val anf : tannot exp -> typ aexp

(** {2 Pretty printing ANF expressions} *)

val pp_aval : typ aval -> PPrint.document
val pp_aexp : typ aexp -> PPrint.document
