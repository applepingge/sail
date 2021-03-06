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

open Sail

open Ast
open Ast_util
open Interpreter
open Pretty_print_sail

type mode =
  | Evaluation of frame
  | Normal
  | Emacs

let current_mode = ref Normal

let prompt () =
  match !current_mode with
  | Normal -> "sail> "
  | Evaluation _ -> "eval> "
  | Emacs -> ""

let eval_clear = ref true

let mode_clear () =
  match !current_mode with
  | Normal -> ()
  | Evaluation _ -> if !eval_clear then LNoise.clear_screen () else ()
  | Emacs -> ()

let rec user_input callback =
  match LNoise.linenoise (prompt ()) with
  | None -> ()
  | Some v ->
     mode_clear ();
     begin
       try callback v with
       | Reporting.Fatal_error e -> Reporting.print_error e
     end;
     user_input callback

let sail_logo =
  let banner str = str |> Util.bold |> Util.red |> Util.clear in
  let logo =
    if !Interactive.opt_suppress_banner then []
    else
      [ {|    ___       ___       ___       ___ |};
        {|   /\  \     /\  \     /\  \     /\__\|};
        {|  /::\  \   /::\  \   _\:\  \   /:/  /|};
        {| /\:\:\__\ /::\:\__\ /\/::\__\ /:/__/ |};
        {| \:\:\/__/ \/\::/  / \::/\/__/ \:\  \ |};
        {|  \::/  /    /:/  /   \:\__\    \:\__\|};
        {|   \/__/     \/__/     \/__/     \/__/|} ]
  in
  let help =
    [ "Type :commands for a list of commands, and :help <command> for help.";
      "Type expressions to evaluate them." ]
  in
  List.map banner logo @ [""] @ help @ [""]

let vs_ids = ref (val_spec_ids !Interactive.ast)

let interactive_state = ref (initial_state !Interactive.ast Value.primops)

let interactive_bytecode = ref []

let sep = "-----------------------------------------------------" |> Util.blue |> Util.clear

let print_program () =
  match !current_mode with
  | Normal | Emacs -> ()
  | Evaluation (Step (out, _, _, stack)) ->
     List.map stack_string stack |> List.rev |> List.iter (fun code -> print_endline (Lazy.force code); print_endline sep);
     print_endline (Lazy.force out)
  | Evaluation (Done (_, v)) ->
     print_endline (Value.string_of_value v |> Util.green |> Util.clear)
  | Evaluation _ -> ()

let rec run () =
  match !current_mode with
  | Normal | Emacs -> ()
  | Evaluation frame ->
     begin
       match frame with
       | Done (state, v) ->
          interactive_state := state;
          print_endline ("Result = " ^ Value.string_of_value v);
          current_mode := Normal
       | Step (out, state, _, stack) ->
          begin
            try
              current_mode := Evaluation (eval_frame frame)
            with
            | Failure str -> print_endline str; current_mode := Normal
          end;
          run ()
       | Break frame ->
          print_endline "Breakpoint";
          current_mode := Evaluation frame
     end

let rec run_steps n =
  print_endline ("step " ^ string_of_int n);
  match !current_mode with
  | _ when n <= 0 -> ()
  | Normal | Emacs -> ()
  | Evaluation frame ->
     begin
       match frame with
       | Done (state, v) ->
          interactive_state := state;
          print_endline ("Result = " ^ Value.string_of_value v);
          current_mode := Normal
       | Step (out, state, _, stack) ->
          begin
            try
              current_mode := Evaluation (eval_frame frame)
            with
            | Failure str -> print_endline str; current_mode := Normal
          end;
          run_steps (n - 1)
       | Break frame ->
          print_endline "Breakpoint";
          current_mode := Evaluation frame
     end

let help = function
  | ":t" | ":type" ->
     "(:t | :type) <function name> - Print the type of a function."
  | ":q" | ":quit" ->
     "(:q | :quit) - Exit the interpreter."
  | ":i" | ":infer" ->
     "(:i | :infer) <expression> - Infer the type of an expression."
  | ":v" | ":verbose" ->
     "(:v | :verbose) - Increase the verbosity level, or reset to zero at max verbosity."
  | ":b" | ":bind" ->
     "(:b | :bind) <id> : <typ> - Declare a variable of a specific type"
  | ":let" ->
     ":let <id> = <exp> - Bind a variable to expression"
  | ":def" ->
     ":def <definition> - Evaluate a top-level definition"
  | ":prove" ->
     ":prove <constraint> - Try to prove a constraint in the top-level environment"
  | ":assume" ->
     ":assume <constraint> - Add a constraint to the top-level environment"
  | ":commands" ->
     ":commands - List all available commands."
  | ":help" ->
     ":help <command> - Get a description of <command>. Commands are prefixed with a colon, e.g. :help :type."
  | ":elf" ->
     ":elf <file> - Load an ELF file."
  | ":r" | ":run" ->
     "(:r | :run) - Completely evaluate the currently evaluating expression."
  | ":s" | ":step" ->
     "(:s | :step) <number> - Perform a number of evaluation steps."
  | ":n" | ":normal" ->
     "(:n | :normal) - Exit evaluation mode back to normal mode."
  | ":clear" ->
     ":clear (on|off) - Set whether to clear the screen or not in evaluation mode."
  | ":l" | ":load" -> String.concat "\n"
     [ "(:l | :load) <files> - Load sail files and add their definitions to the interactive environment.";
       "Files containing scattered definitions must be loaded together." ]
  | ":u" | ":unload" ->
     "(:u | :unload) - Unload all loaded files."
  | ":output" ->
     ":output <file> - Redirect evaluating expression output to a file."
  | ":option" ->
     ":option string - Parse string as if it was an option passed on the command line. Try :option -help."
  | cmd ->
     "Either invalid command passed to help, or no documentation for " ^ cmd ^ ". Try :help :help."

let format_pos_emacs p1 p2 contents =
  let open Lexing in
  let b = Buffer.create 160 in
  Printf.sprintf "(sail-error %d %d %d %d \"%s\")"
                 p1.pos_lnum (p1.pos_cnum - p1.pos_bol)
                 p2.pos_lnum (p2.pos_cnum - p2.pos_bol)
                 contents

let rec emacs_error l contents =
  match l with
  | Parse_ast.Unknown -> "(error \"no location info: " ^ contents ^ "\")"
  | Parse_ast.Range (p1, p2) -> format_pos_emacs p1 p2 contents
  | Parse_ast.Unique (_, l) -> emacs_error l contents
  | Parse_ast.Documented (_, l) -> emacs_error l contents
  | Parse_ast.Generated l -> emacs_error l contents

type session = {
    id : string;
    files : string list
  }

let default_session = {
    id = "none";
    files = []
  }

let session = ref default_session

let parse_session file =
  let open Yojson.Basic.Util in
  if Sys.file_exists file then
    let json = Yojson.Basic.from_file file in
    let args = Str.split (Str.regexp " +") (json |> member "options" |> to_string) in
    Arg.parse_argv ~current:(ref 0) (Array.of_list ("sail" :: args)) Sail.options (fun _ -> ()) "";
    print_endline ("(message \"Using session " ^ file ^ "\")");
    {
      id = file;
      files = json |> member "files" |> convert_each to_string
    }
  else
    default_session

let load_session upto file =
  match upto with
  | None -> None
  | Some upto_file when Filename.basename upto_file = file -> None
  | Some upto_file ->
     let (_, ast, env) =
       load_files ~check:true !Interactive.env [Filename.concat (Filename.dirname upto_file) file]
     in
     Interactive.ast := append_ast !Interactive.ast ast;
     Interactive.env := env;
     print_endline ("(message \"Checked " ^ file ^ "...\")\n");
     Some upto_file

let load_into_session file =
  let session_file = Filename.concat (Filename.dirname file) "sail.json" in
  session := (if session_file = !session.id then !session else parse_session session_file);
  ignore (List.fold_left load_session (Some file) !session.files)

type input = Command of string * string | Expression of string | Empty

(* This function is called on every line of input passed to the interpreter *)
let handle_input' input =
  LNoise.history_add input |> ignore;

  (* Process the input and check if it's a command, a raw expression,
     or empty. *)
  let input =
    if input <> "" && input.[0] = ':' then
      let n = try String.index input ' ' with Not_found -> String.length input in
      let cmd = Str.string_before input n in
      let arg = String.trim (Str.string_after input n) in
      Command (cmd, arg)
    else if input <> "" then
      Expression input
    else
      Empty
  in

  let recognised = ref true in

  let unrecognised_command cmd =
    if !recognised = false then print_endline ("Command " ^ cmd ^ " is not a valid command in this mode.") else ()
  in

  (* First handle commands that are mode-independent *)
  begin match input with
  | Command (cmd, arg) ->
     begin match cmd with
     | ":n" | ":normal" ->
        current_mode := Normal
     | ":t" | ":type" ->
        let typq, typ = Type_check.Env.get_val_spec (mk_id arg) !Interactive.env in
        pretty_sail stdout (doc_binding (typq, typ));
        print_newline ();
     | ":q" | ":quit" ->
        Value.output_close ();
        exit 0
     | ":i" | ":infer" ->
        let exp = Initial_check.exp_of_string arg in
        let exp = Type_check.infer_exp !Interactive.env exp in
        pretty_sail stdout (doc_typ (Type_check.typ_of exp));
        print_newline ()
     | ":prove" ->
        let nc = Initial_check.constraint_of_string arg in
        print_endline (string_of_bool (Type_check.prove __POS__ !Interactive.env nc))
     | ":assume" ->
        let nc = Initial_check.constraint_of_string arg in
        Interactive.env := Type_check.Env.add_constraint nc !Interactive.env
     | ":v" | ":verbose" ->
            Type_check.opt_tc_debug := (!Type_check.opt_tc_debug + 1) mod 3;
            print_endline ("Verbosity: " ^ string_of_int !Type_check.opt_tc_debug)
     | ":clear" ->
        if arg = "on" then
          eval_clear := true
        else if arg = "off" then
          eval_clear := false
        else print_endline "Invalid argument for :clear, expected either :clear on or :clear off"
     | ":commands" ->
        let commands =
          [ "Universal commands - :(t)ype :(i)nfer :(q)uit :(v)erbose :prove :assume :clear :commands :help :output :option";
            "Normal mode commands - :elf :(l)oad :(u)nload :let :def :(b)ind";
            "Evaluation mode commands - :(r)un :(s)tep :(n)ormal";
            "";
            ":(c)ommand can be called as either :c or :command." ]
        in
        List.iter print_endline commands
     | ":option" ->
        begin
          try
            let args = Str.split (Str.regexp " +") arg in
            Arg.parse_argv ~current:(ref 0) (Array.of_list ("sail" :: args)) Sail.options (fun _ -> ()) "";
          with
          | Arg.Bad message | Arg.Help message -> print_endline message
        end;
     | ":spec" ->
        let ast, env = Specialize.(specialize' 1 int_specialization !Interactive.ast !Interactive.env) in
        Interactive.ast := ast;
        Interactive.env := env;
        interactive_state := initial_state !Interactive.ast Value.primops
     | ":pretty" ->
        print_endline (Pretty_print_sail.to_string (Latex.defs !Interactive.ast))
     | ":ir" ->
        print_endline arg;
        let open Jib in
        let open Jib_util in
        let open PPrint in
        let is_cdef = function
          | CDEF_fundef (id, _, _, _) when Id.compare id (mk_id arg) = 0 -> true
          | CDEF_spec (id, _, _) when Id.compare id (mk_id arg) = 0 -> true
          | _ -> false
        in
        let cdefs = List.filter is_cdef !interactive_bytecode in
        print_endline (Pretty_print_sail.to_string (separate_map hardline pp_cdef cdefs))
     | ":ast" ->
        let chan = open_out arg in
        Pretty_print_sail.pp_defs chan !Interactive.ast;
        close_out chan
     | ":output" ->
        let chan = open_out arg in
        Value.output_redirect chan
     | ":help" -> print_endline (help arg)
     | _ -> recognised := false
     end
  | _ -> ()
  end;

  match !current_mode with
  | Normal ->
     begin match input with
     | Command (cmd, arg) ->
        (* Normal mode commands *)
        begin match cmd with
        | ":elf" -> Elf_loader.load_elf arg
        | ":l" | ":load" ->
           let files = Util.split_on_char ' ' arg in
           let (_, ast, env) = load_files !Interactive.env files in
           let ast = Process_file.rewrite_ast_interpreter !Interactive.env ast in
           Interactive.ast := append_ast !Interactive.ast ast;
           interactive_state := initial_state !Interactive.ast Value.primops;
           Interactive.env := env;
           vs_ids := val_spec_ids !Interactive.ast
        | ":u" | ":unload" ->
           Interactive.ast := Ast.Defs [];
           Interactive.env := Type_check.initial_env;
           interactive_state := initial_state !Interactive.ast Value.primops;
           vs_ids := val_spec_ids !Interactive.ast;
           (* See initial_check.mli for an explanation of why we need this. *)
           Initial_check.have_undefined_builtins := false;
           Process_file.clear_symbols ()
        | ":b" | ":bind" ->
           let args = Str.split (Str.regexp " +") arg in
           begin match args with
           | v :: ":" :: args ->
              let typ = Initial_check.typ_of_string (String.concat " " args) in
              let _, env, _ = Type_check.bind_pat !Interactive.env (mk_pat (P_id (mk_id v))) typ in
              Interactive.env := env
           | _ -> print_endline "Invalid arguments for :bind"
           end
        | ":let" ->
           let args = Str.split (Str.regexp " +") arg in
           begin match args with
           | v :: "=" :: args ->
              let exp = Initial_check.exp_of_string (String.concat " " args) in
              let ast, env = Type_check.check !Interactive.env (Defs [DEF_val (mk_letbind (mk_pat (P_id (mk_id v))) exp)]) in
              Interactive.ast := append_ast !Interactive.ast ast;
              Interactive.env := env;
              interactive_state := initial_state !Interactive.ast Value.primops;
           | _ -> print_endline "Invalid arguments for :let"
           end
        | ":def" ->
           let ast = Initial_check.ast_of_def_string_with (Process_file.preprocess_ast options) arg in
           let ast, env = Type_check.check !Interactive.env ast in
           Interactive.ast := append_ast !Interactive.ast ast;
           Interactive.env := env;
           interactive_state := initial_state !Interactive.ast Value.primops;
        | _ -> unrecognised_command cmd
        end
     | Expression str ->
        (* An expression in normal mode is type checked, then puts
             us in evaluation mode. *)
        let exp = Type_check.infer_exp !Interactive.env (Initial_check.exp_of_string str) in
        current_mode := Evaluation (eval_frame (Step (lazy "", !interactive_state, return exp, [])));
        print_program ()
     | Empty -> ()
     end

  | Emacs ->
     begin match input with
     | Command (cmd, arg) ->
        begin match cmd with
        | ":load" ->
           begin
             try
               load_into_session arg;
               let (_, ast, env) = load_files ~check:true !Interactive.env [arg] in
               Interactive.ast := append_ast !Interactive.ast ast;
               interactive_state := initial_state !Interactive.ast Value.primops;
               Interactive.env := env;
               vs_ids := val_spec_ids !Interactive.ast;
               print_endline ("(message \"Checked " ^ arg ^ " done\")\n");
             with
             | Reporting.Fatal_error (Err_type (l, msg)) ->
                print_endline (emacs_error l (String.escaped msg))
           end
        | ":unload" ->
           Interactive.ast := Ast.Defs [];
           Interactive.env := Type_check.initial_env;
           interactive_state := initial_state !Interactive.ast Value.primops;
           vs_ids := val_spec_ids !Interactive.ast;
           Initial_check.have_undefined_builtins := false;
           Process_file.clear_symbols ()
        | ":typeat" ->
           let args = Str.split (Str.regexp " +") arg in
           begin match args with
           | [file; pos] ->
              let open Lexing in
              let pos = int_of_string pos in
              let pos = { dummy_pos with pos_fname = file; pos_cnum = pos - 1 } in
              let sl = Some (pos, pos) in
              begin match find_annot_ast sl !Interactive.ast with
              | Some annot ->
                 let msg = String.escaped (string_of_typ (Type_check.typ_of_annot annot)) in
                 begin match simp_loc (fst annot) with
                 | Some (p1, p2) ->
                    print_endline ("(sail-highlight-region "
                                   ^ string_of_int (p1.pos_cnum + 1) ^ " " ^ string_of_int (p2.pos_cnum + 1)
                                   ^ " \"" ^ msg ^ "\")")
                 | None ->
                    print_endline ("(message \"" ^ msg ^ "\")")
                 end
              | None ->
                 print_endline "(message \"No type here\")"
              end
           | _ ->
              print_endline "(error \"Bad arguments for type at cursor\")"
           end
        | _ -> ()
        end
     | Expression _ | Empty -> ()
     end

  | Evaluation frame ->
     begin match input with
     | Command (cmd, arg) ->
        (* Evaluation mode commands *)
        begin
          match cmd with
          | ":r" | ":run" ->
             run ()
          | ":s" | ":step" ->
             run_steps (int_of_string arg)
          | _ -> unrecognised_command cmd
        end
     | Expression str ->
        print_endline "Already evaluating expression"
     | Empty ->
        (* Empty input will evaluate one step, or switch back to
             normal mode when evaluation is completed. *)
        begin match frame with
        | Done (state, v) ->
           interactive_state := state;
           print_endline ("Result = " ^ Value.string_of_value v);
           current_mode := Normal
        | Step (out, state, _, stack) ->
           begin
             try
               interactive_state := state;
               current_mode := Evaluation (eval_frame frame);
               print_program ()
             with
             | Failure str -> print_endline str; current_mode := Normal
           end
        | Break frame ->
           print_endline "Breakpoint";
           current_mode := Evaluation frame
        end
     end

let handle_input input =
  try handle_input' input with
  | Type_check.Type_error (env, l, err) ->
     print_endline (Type_error.string_of_type_error err)
  | Reporting.Fatal_error err ->
     Reporting.print_error err
  | exn ->
     print_endline (Printexc.to_string exn)

let () =
  (* Auto complete function names based on val specs, or directories if :load command *)
  LNoise.set_completion_callback (
      fun line_so_far ln_completions ->
      let line_so_far, last_id =
        try
          let p = Str.search_backward (Str.regexp "[^a-zA-Z0-9_/-]") line_so_far (String.length line_so_far - 1) in
          Str.string_before line_so_far (p + 1), Str.string_after line_so_far (p + 1)
        with
        | Not_found -> "", line_so_far
        | Invalid_argument _ -> line_so_far, ""
      in
      let n = try String.index line_so_far ' ' with Not_found -> String.length line_so_far in
      let cmd = Str.string_before line_so_far n in
      if last_id <> "" then
        if cmd = ":load" || cmd = ":l" then
          begin
            let dirname, basename = Filename.dirname last_id, Filename.basename last_id in
            if Sys.file_exists last_id then
              LNoise.add_completion ln_completions (line_so_far ^ last_id);
            if (try Sys.is_directory dirname with Sys_error _ -> false) then
              let contents = Sys.readdir (Filename.concat (Sys.getcwd ()) dirname) in
              for i = 0 to Array.length contents - 1 do
                if Str.string_match (Str.regexp_string basename) contents.(i) 0 then
                  let is_dir = (try Sys.is_directory (Filename.concat dirname contents.(i)) with Sys_error _ -> false) in
                  LNoise.add_completion ln_completions
                    (line_so_far ^ Filename.concat dirname contents.(i) ^ (if is_dir then Filename.dir_sep else ""))
              done
          end
        else if cmd = ":option" then
          List.map (fun (opt, _, _) -> opt) options
          |> List.filter (fun opt -> Str.string_match (Str.regexp_string last_id) opt 0)
          |> List.map (fun completion -> line_so_far ^ completion)
          |> List.iter (LNoise.add_completion ln_completions)
        else
          IdSet.elements !vs_ids
          |> List.map string_of_id
          |> List.filter (fun id -> Str.string_match (Str.regexp_string last_id) id 0)
          |> List.map (fun completion -> line_so_far ^ completion)
          |> List.iter (LNoise.add_completion ln_completions)
      else ()
    );

  LNoise.set_hints_callback (
      fun line_so_far ->
      let hint str = Some (" " ^ str, LNoise.Yellow, false) in
      match String.trim line_so_far with
      | _ when !Interactive.opt_emacs_mode -> None
      | ":load"  | ":l" -> hint "<sail file>"
      | ":bind"  | ":b" -> hint "<id> : <type>"
      | ":infer" | ":i" -> hint "<expression>"
      | ":type"  | ":t" -> hint "<function id>"
      | ":let" -> hint "<id> = <expression>"
      | ":def" -> hint "<definition>"
      | ":prove" -> hint "<constraint>"
      | ":assume" -> hint "<constraint>"
      | str ->
         let args = Str.split (Str.regexp " +") str in
         match args with
         | [":option"] -> hint "<flag>"
         | [":option"; flag] ->
            begin match List.find_opt (fun (opt, _, _) -> flag = opt) options with
            | Some (_, _, help) -> hint (Str.global_replace (Str.regexp " +") " " help)
            | None -> None
            end
         | _ -> None
    );

  (* Read the script file if it is set with the -is option, and excute them *)
  begin
    match !opt_interactive_script with
    | None -> ()
    | Some file ->
       let chan = open_in file in
       try
         while true do
           let line = input_line chan in
           handle_input line;
         done;
       with
       | End_of_file -> ()
  end;

  LNoise.history_load ~filename:"sail_history" |> ignore;
  LNoise.history_set ~max_length:100 |> ignore;

  if !Interactive.opt_interactive then
    begin
      if not !Interactive.opt_emacs_mode then
        List.iter print_endline sail_logo
      else (current_mode := Emacs; Util.opt_colors := false);
      user_input handle_input
    end
  else ()
