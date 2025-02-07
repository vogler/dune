open Import

module CC = Compilation_context
module SC = Super_context

type t =
  { to_link : Lib.Lib_and_module.t list
  ; force_linkall : bool
  }

let generate_and_compile_module cctx ~precompiled_cmi ~name:basename
      ~lib ~code ~requires =
  let open Build.O in
  let sctx       = CC.super_context cctx in
  let obj_dir    = CC.obj_dir       cctx in
  let dir        = CC.dir           cctx in
  let name = Module.Name.of_string basename in
  let wrapped = Result.ok_exn (Lib.wrapped lib) in
  let module_ =
    let src_dir = Path.build (Obj_dir.obj_dir obj_dir) in
    let gen_module = Module.generated ~src_dir name in
    match wrapped with
    | None -> gen_module
    | Some (Yes_with_transition _) -> assert false
    | Some (Simple false) -> gen_module
    | Some (Simple true) ->
      let main_module_name =
        Lib.main_module_name lib
        |> Result.ok_exn
        |> Option.value_exn
      in
      Module.with_wrapper gen_module ~main_module_name
  in
  SC.add_rule ~dir sctx (
    let ml =
      Module.file module_ ~ml_kind:Impl
      |> Option.value_exn
      |> Path.as_in_build_dir_exn
    in
    code >>> Build.write_file_dyn ml);
  let opaque =
    Ocaml_version.supports_opaque_for_mli
      (Super_context.context sctx).version
  in
  let modules = Modules.singleton_exe module_ in
  let cctx =
    Compilation_context.create
      ~super_context:sctx
      ~expander:(Compilation_context.expander cctx)
      ~scope:(Compilation_context.scope cctx)
      ~dir_kind:(Compilation_context.dir_kind cctx)
      ~obj_dir
      ~modules
      ~requires_compile:requires
      ~requires_link:(lazy requires)
      ~flags:Ocaml_flags.empty
      ~opaque
      ~dynlink:(Compilation_context.dynlink cctx)
      ~package:(Compilation_context.package cctx)
      ()
  in
  Module_compilation.build_module
    ~dep_graphs:(Dep_graph.Ml_kind.dummy module_)
    ~precompiled_cmi
    cctx
    module_;
  module_

let pr buf fmt = Printf.bprintf buf (fmt ^^ "\n")
let prlist buf name l ~f =
  match l with
  | [] -> pr buf "let %s = []" name
  | x :: l ->
    pr buf "let %s =" name;
    Printf.bprintf buf "  [ ";
    f x;
    List.iter l ~f:(fun x ->
      Printf.bprintf buf "  ; ";
      f x);
    pr buf "  ]"

let findlib_init_code ~preds ~libs =
  let public_libs =
    List.filter
      ~f:(fun lib ->
        let info = Lib.info lib in
        let status = Lib_info.status info in
        not (Lib_info.Status.is_private status))
      libs
  in
  let buf = Buffer.create 1024 in
  List.iter public_libs ~f:(fun lib ->
    pr buf "Findlib.record_package Findlib.Record_core %S;;"
      (Lib_name.to_string (Lib.name lib)));
  prlist buf "preds" (Variant.Set.to_list preds)
    ~f:(fun v -> pr buf "%S" (Variant.to_string v));
  pr buf "in";
  pr buf "let preds =";
  pr buf "  (if Dynlink.is_native then \"native\" else \"byte\") :: preds";
  pr buf "in";
  pr buf "Findlib.record_package_predicates preds;;";
  Buffer.contents buf

let build_info_code cctx ~libs ~api_version =
  begin match api_version with
  | Dune_file.Library.Special_builtin_support.Build_info.V1 -> ()
  end;
  let sctx = CC.super_context cctx in
  let file_tree = Super_context.file_tree sctx in
  (* [placeholders] is a mapping from source path to variable
     names. For each binding [(p, v)], we will generate the following
     code:

     {[
       let v = Placeholder "%%DUNE_PLACEHOLDER:...:vcs-describe:...:p%%"
     ]}
  *)
  let placeholders = ref Path.Source.Map.empty in
  let gen_placeholder_var =
    let n = ref 0 in
    fun () -> let s = sprintf "p%d" !n in incr n; s
  in
  let placeholder p =
    match File_tree.nearest_vcs file_tree p with
    | None -> "None"
    | Some vcs ->
      let p =
        Option.value (Path.as_in_source_tree vcs.root)
          (* The only VCS root that is potentially not in the source
             tree is the VCS at the root of the repo. For this VCS, it
             is enough to use the source tree root in the placeholder
             given that we take the nearest VCS when performing the
             actual substitution. *)
          ~default:Path.Source.root
      in
      match Path.Source.Map.find !placeholders p with
      | Some var -> var
      | None ->
        let  var = gen_placeholder_var () in
        placeholders := Path.Source.Map.set !placeholders p var;
        var
  in
  let version_of_package (p : Package.t) =
    match p.version with
    | Some (v, _) -> sprintf "Some %S" v
    | None -> placeholder p.path
  in
  let version =
    match Compilation_context.package cctx with
    | Some p -> version_of_package p
    | None ->
      let p = Path.Build.drop_build_context_exn (CC.dir cctx) in
      placeholder p
  in
  let libs =
    List.map libs ~f:(fun lib ->
      Lib.name lib,
      match Lib_info.version (Lib.info lib) with
      | Some v -> sprintf "Some %S" v
      | None ->
        match Lib_info.status (Lib.info lib) with
        | Installed -> "None"
        | Public (_, p) -> version_of_package p
        | Private _ ->
          let p = Path.drop_build_context_exn (Obj_dir.dir (Lib.obj_dir lib)) in
          placeholder p)
  in
  let buf = Buffer.create 1024 in
  (* Parse the replacement format described in
     [artifact_substitution.ml]. *)
  pr buf "let eval s =";
  pr buf "  let len = String.length s in";
  pr buf "  if s.[0] = '=' then";
  pr buf "    let colon_pos = String.index_from s 1 ':' in";
  pr buf "    let vlen = int_of_string (String.sub s 1 (colon_pos - 1)) in";
  pr buf "    (* This [min] is because the value might have been truncated";
  pr buf "       if it was too large *)";
  pr buf "    let vlen = min vlen (len - colon_pos - 1) in";
  pr buf "    Some (String.sub s (colon_pos + 1) vlen)";
  pr buf "  else";
  pr buf "    None";
  pr buf "[@@inline never]";
  pr buf "";
  Path.Source.Map.iteri !placeholders ~f:(fun path var ->
    pr buf "let %s = eval %S"
      var (Artifact_substitution.encode ~min_len:64 (Vcs_describe path)));
  if not (Path.Source.Map.is_empty !placeholders) then pr buf "";
  pr buf "let version = %s" version;
  pr buf "";
  prlist buf "statically_linked_libraries" libs ~f:(fun (name, v) ->
    pr buf "%S, %s" (Lib_name.to_string name) v);
  Buffer.contents buf

let handle_special_libs cctx =
  let open Result.O in
  let+ all_libs = CC.requires_link cctx in
  let obj_dir = Compilation_context.obj_dir cctx |> Obj_dir.of_local in
  let sctx = CC.super_context cctx in
  let module LM = Lib.Lib_and_module in
  let rec process_libs ~to_link_rev ~force_linkall libs =
    match libs with
    | [] -> { to_link = List.rev to_link_rev; force_linkall }
    | lib :: libs ->
      match Lib_info.special_builtin_support (Lib.info lib) with
      | None ->
        process_libs libs
          ~to_link_rev:(LM.Lib lib :: to_link_rev)
          ~force_linkall
      | Some special ->
        match special with
        | Build_info { data_module; api_version } ->
          let module_ =
            generate_and_compile_module
              cctx
              ~name:data_module
              ~lib
              ~code:(Build.arr (fun () ->
                build_info_code cctx ~libs:all_libs ~api_version))
              ~requires:(Ok [lib])
              ~precompiled_cmi:true
          in
          process_libs libs
            ~to_link_rev:(LM.Lib lib
                          :: Module (obj_dir, module_)
                          :: to_link_rev)
            ~force_linkall
        | Findlib_dynload ->
          (* If findlib.dynload is linked, we stores in the binary
             the packages linked by linking just after
             findlib.dynload a module containing the info *)
          let requires =
            (* This shouldn't fail since findlib.dynload depends on
               dynlink and findlib. That's why it's ok to use a
               dummy location. *)
            let+ dynlink =
              Lib.DB.resolve (SC.public_libs sctx)
                (Loc.none, Lib_name.of_string_exn ~loc:None "dynlink")
            and+ findlib =
              Lib.DB.resolve (SC.public_libs sctx)
                (Loc.none, Lib_name.of_string_exn ~loc:None "findlib")
            in
            [ dynlink; findlib ]
          in
          let module_ =
            generate_and_compile_module
              cctx
              ~lib
              ~name:"findlib_initl"
              ~code:(Build.arr (fun () ->
                findlib_init_code ~preds:Findlib.Package.preds ~libs:all_libs))
              ~requires
              ~precompiled_cmi:false
          in
          process_libs libs
            ~to_link_rev:(LM.Module (obj_dir, module_)
                          :: Lib lib
                          :: to_link_rev)
            ~force_linkall:true
  in
  process_libs all_libs ~to_link_rev:[] ~force_linkall:false
