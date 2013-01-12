(* Add whatever -I options have been specified on the command line,
     but keep the directories that user code linked in with ocamlmktop
     may have added to load_path. *)
let default_build_paths =
  let open Config in
  lazy (List.rev !Clflags.include_dirs @ !load_path @ [Filename.concat standard_library "camlp4"])

let set_default_path () =
  Config.load_path := Lazy.force default_build_paths

let source_path = ref []

type state = {
  pos      : Lexing.position;
  tokens   : Outline.Raw.t;
  outlines : Outline.Chunked.t;
  chunks   : Chunk.t;
  envs     : Typer.t;
}
 
let initial_state = {
  pos      = Lexing.((from_string "").lex_curr_p);
  tokens   = History.empty;
  outlines = History.empty;
  chunks   = History.empty;
  envs     = History.empty;
}

let commands = Hashtbl.create 17

let main_loop () =
  let input  = Json.stream_from_channel stdin in
  let output =
    let out_json = Json.to_channel stdout in
    fun json ->
      out_json json;
      print_newline ()
  in
  try
    let rec loop state =
      let state, answer =
        try match Stream.next input with
          | `List (`String command :: args) ->
                let handler =
                  try Hashtbl.find commands command
                  with Not_found -> failwith "unknown command"
                in
                handler state args
          | _ -> failwith "malformed command"
        with
          | Failure s -> state, `List [`String "failure"; `String s]
          | Stream.Failure as exn -> raise exn
          | exn -> state, `List [`String "exception"; `String (Printexc.to_string exn)]
      in
      output answer;
      loop state
    in
    loop initial_state
  with Stream.Failure -> ()

let pos_to_json pos =
  Lexing.(`Assoc ["line", `Int pos.pos_lnum;
                  "col", `Int (pos.pos_cnum - pos.pos_bol);
                  "offset", `Int pos.pos_cnum])
let return_position p = `List [`String "position" ; pos_to_json p]

let invalid_arguments () = failwith "invalid arguments"

type command = state -> Json.json list -> state * Json.json 

let command_tell state = function
  | [`String source] ->
      let bufpos = ref state.pos in
      let tokens, outlines =
        Outline.parse ~bufpos ~goteof:(ref false)
          (state.tokens,state.outlines)
          (Lexing.from_string source)
      in
      let chunks = Chunk.append outlines state.chunks in
      (* Process directives *)
      let envs = Typer.sync chunks state.envs in
      { tokens ; outlines ; chunks ; envs ; pos = !bufpos},
      `Bool true
  | _ -> invalid_arguments ()

let command_line state = function
  | [] -> state, return_position state.pos
  | _ -> invalid_arguments ()

let command_seek state = function
  | [`Assoc props] ->
      let pos =
        try match List.assoc "offset" props with
          | `Int i -> `Offset i
          | _ -> invalid_arguments () 
        with Not_found ->
        try match List.assoc "line" props, List.assoc "col" props with
          | `Int line, `Int col -> `Line (line, col)
          | _ -> invalid_arguments ()
        with Not_found -> invalid_arguments ()
      in
      let outlines =
        match pos with
          | `Offset o -> Outline.Chunked.seek_offset o state.outlines
          | `Line (l,c) -> Outline.Chunked.seek_line (l,c) state.outlines
      in
      let outlines, _ = History.split outlines in
      let tokens, outlines = History.sync fst state.tokens outlines in
      let tokens, _ = History.split tokens in
      let chunks = Chunk.append outlines state.chunks in
      let envs = Typer.sync chunks state.envs in
      let pos =
        match Outline.Chunked.last_position outlines with
          | Some p -> p
          | None -> initial_state.pos
      in
      { tokens ; outlines ; chunks ; envs ; pos},
      return_position pos
  | _ -> invalid_arguments ()

let command_reset state = function
  | [] -> initial_state, return_position initial_state.pos
  | _ -> invalid_arguments ()


(* Path management *)
let command_which state = function
  | [`String s] -> 
      let filename =
        try
          Misc.find_in_path_uncap !source_path s
        with Not_found ->
          Misc.find_in_path_uncap !Config.load_path s
      in
      state, `String filename
  | _ -> invalid_arguments ()

let command_path ~reset r state = function
  | [ `String "list" ] ->
      state, `List (List.map (fun s -> `String s) !r)
  | [ `String "add" ; `String s ] ->
      let d = Misc.expand_directory Config.standard_library s in
      r := d :: !r;
      state, `Bool true
  | [ `String "remove" ; `String s ] ->
      let d = Misc.expand_directory Config.standard_library s in
      r := List.filter (fun d' -> d' <> d) !r;
      state, `Bool true
  | [ `String "reset" ] ->
      r := Lazy.force reset;
      state, `Bool true
  | _ -> invalid_arguments ()

let command_cd state = function
  | [`String s] ->
      Sys.chdir s;
      state, (`Bool true)
  | _ -> invalid_arguments ()

let _ = List.iter (fun (a,b) -> Hashtbl.add commands a b) [
  "tell",  (command_tell  :> command);
  "line",  (command_line  :> command);
  "seek",  (command_seek  :> command);
  "reset", (command_reset :> command);
  "cd",    (command_cd    :> command);
  "which", (command_which :> command);
  "source_path", (command_path ~reset:default_build_paths source_path :> command);
  "build_path",  (command_path ~reset:(lazy []) Config.load_path :> command);
]

(* Directives we want :
   - #line : current position
   - #seek "{line:int,col:int}" : set position to line, col
   - #seek "int"   : set position to offset
   response : {line:int,col:int,offset:int}, nearest position that could be recovered
   - #which "module.{ml,mli}" : find file with given name
   response : /path/to/module.{ml,mli}
   - #reset : reset to initial state

   - #source_path "path"
   - #build_path "path"
   - #remove_source_path "path"
   - #remove_build_path "path"
   - #clear_source_path
   - #clear_build_path
   Next : browsing
*)
  
let print_version () =
  Printf.printf "The Outliner toplevel, version %s\n" Sys.ocaml_version;
  exit 0

let print_version_num () =
  Printf.printf "%s\n" Sys.ocaml_version;
  exit 0

let unexpected_argument s =
  failwith ("Unexpected argument:" ^ s)

module Options = Main_args.Make_bytetop_options (struct
  let set r () = r := true
  let clear r () = r := false

  let _absname = set Location.absname
  let _I dir =
    let dir = Misc.expand_directory Config.standard_library dir in
    Clflags.include_dirs := dir :: !Clflags.include_dirs
  let _init s = Clflags.init_file := Some s
  let _labels = clear Clflags.classic
  let _no_app_funct = clear Clflags.applicative_functors
  let _noassert = set Clflags.noassert
  let _nolabels = set Clflags.classic
  let _noprompt = set Clflags.noprompt
  let _nopromptcont = set Clflags.nopromptcont
  let _nostdlib = set Clflags.no_std_include
  let _principal = set Clflags.principal
  let _rectypes = set Clflags.recursive_types
  let _stdin () = main_loop ()
  let _strict_sequence = set Clflags.strict_sequence
  let _unsafe = set Clflags.fast
  let _version () = print_version ()
  let _vnum () = print_version_num ()
  let _w s = Warnings.parse_options false s
  let _warn_error s = Warnings.parse_options true s
  let _warn_help = Warnings.help_warnings
  let _dparsetree = set Clflags.dump_parsetree
  let _drawlambda = set Clflags.dump_rawlambda
  let _dlambda = set Clflags.dump_lambda
  let _dinstr = set Clflags.dump_instr

  let anonymous s = unexpected_argument s
end);;

let main () =
  Arg.parse Options.list unexpected_argument "TODO";
  Compile.init_path ();
  set_default_path ();
  main_loop ()

let _ = main ()
