open Stdune
open Import

let interpret_destdir ~destdir path =
  match destdir with
  | None ->
    path
  | Some prefix ->
    Path.append_local
      (Path.of_string prefix)
      (Path.local_part path)

let get_dirs context ~prefix_from_command_line ~libdir_from_command_line =
  match prefix_from_command_line with
  | Some p ->
    let prefix = Path.of_string p in
    let dir = Option.value ~default:"lib" libdir_from_command_line in
    Fiber.return (prefix, Some (Path.relative prefix dir))
  | None ->
    let open Fiber.O in
    let* prefix = Context.install_prefix context in
    let libdir =
      match libdir_from_command_line with
      | None -> Context.install_ocaml_libdir context
      | Some l -> Fiber.return (Some (Path.relative prefix l))
    in
    let+ libdir = libdir in
    (prefix, libdir)

let resolve_package_install setup pkg =
  match Import.Main.package_install_file setup pkg with
  | Ok path -> path
  | Error () ->
    let pkg = Package.Name.to_string pkg in
    User_error.raise [ Pp.textf "Unknown package %s!" pkg ]
      ~hints:(User_message.did_you_mean pkg
                ~candidates:(Package.Name.Map.keys setup.conf.packages
                             |> List.map ~f:Package.Name.to_string))

let print_unix_error f =
  try
    f ()
  with Unix.Unix_error (e, _, _) ->
    User_message.prerr
      (User_error.make
         [ Pp.text (Unix.error_message e) ])

let set_executable_bits   x = x lor  0o111
let clear_executable_bits x = x land (lnot 0o111)

(** Operations that act on real files or just pretend to (for --dry-run) *)
module type File_operations = sig
  val copy_file
    :  src:Path.Build.t
    -> dst:Path.t
    -> executable:bool
    -> unit Fiber.t
  val mkdir_p : Path.t -> unit
  val remove_if_exists : Path.t -> unit
  val remove_dir_if_empty : Path.t -> unit
end

module type Workspace = sig
  val workspace : Dune.Main.workspace
end

module File_ops_dry_run : File_operations = struct
  let copy_file ~src ~dst ~executable =
    Format.printf
      "Copying %a to %a (executable: %b)\n"
      Path.pp (Path.build src)
      Path.pp dst
      executable;
    Fiber.return ()

  let mkdir_p path =
    Format.printf
      "Creating directory %a\n"
      Path.pp
      path

  let remove_if_exists path =
    Format.printf
      "Removing (if it exists) %a\n"
      Path.pp
      path

  let remove_dir_if_empty path =
    Format.printf
      "Removing directory (if empty) %a\n"
      Path.pp
      path
end

module File_ops_real(W : Workspace) : File_operations = struct
  open W

  let get_vcs p = Dune.File_tree.nearest_vcs workspace.conf.file_tree p

  type 'a load_special_file_result =
    | No_version_needed
    | Need_version of (Format.formatter -> version:string -> unit)

  let copy_special_file ~src ~package_name ~ic ~oc ~f =
    let plain_copy () =
      seek_in ic 0;
      Io.copy_channels ic oc;
      Fiber.return ()
    in
    match f ic with
    | exception _ ->
      User_warning.emit ~loc:(Loc.in_file (Path.build src))
        [ Pp.text "Failed to parse file, not adding version information." ];
      plain_copy ()
    | No_version_needed ->
      plain_copy ()
    | Need_version print ->
      match
        let open Option.O in
        let package_name = Package.Name.of_string package_name in
        let* package =
          Package.Name.Map.find workspace.conf.packages package_name
        in
        get_vcs package.path
      with
      | None ->
        plain_copy ()
      | Some vcs ->
        let open Fiber.O in
        let+ version = Dune.Vcs.describe vcs in
        let ppf = Format.formatter_of_out_channel oc in
        print ppf ~version;
        Format.pp_print_flush ppf ()

  let process_meta ic =
    let lb = Lexing.from_channel ic in
    let meta : Dune.Meta.t =
      { name = None
      ; entries = Dune.Meta.parse_entries lb
      }
    in
    let need_more_versions =
      try
        let (_ : Dune.Meta.t) =
          Dune.Meta.add_versions meta ~get_version:(fun _ -> raise_notrace Exit)
        in
        false
      with Exit ->
        true
    in
    if not need_more_versions then
      No_version_needed
    else
      Need_version (fun ppf ~version ->
        let meta =
          Dune.Meta.add_versions meta ~get_version:(fun _ -> Some version)
        in
        Dune.Meta.pp ppf meta.entries)

  let process_dune_package ic =
    let lb = Lexing.from_channel ic in
    let dp =
      Dune_lang.Parser.parse ~mode:Many lb
      |> List.map ~f:Dune_lang.Ast.remove_locs
    in
    if List.exists dp ~f:(function
      | Dune_lang.List (Atom (A "version") :: _) -> true
      | _ -> false) then
      No_version_needed
    else
      Need_version (fun ppf ~version ->
        let version =
          Dune_lang.List [ Dune_lang.atom "version"
                         ; Dune_lang.atom_or_quoted_string version
                         ]
        in
        let dp =
          match dp with
          | lang :: name :: rest ->
            lang :: name :: version :: rest
          | [lang] -> [lang; version]
          | [] -> [version]
        in
        Format.pp_open_vbox ppf 0;
        List.iter dp ~f:(fun x ->
          Dune_lang.Deprecated.pp Dune ppf x;
          Format.pp_print_cut ppf ());
        Format.pp_close_box ppf ())

  let copy_file ~src ~dst ~executable =
    let chmod =
      if executable then
        set_executable_bits
      else
        clear_executable_bits
    in
    let ic, oc = Io.setup_copy ~chmod ~src:(Path.build src) ~dst () in
    Fiber.finalize ~finally:(fun () -> Io.close_both (ic, oc); Fiber.return ())
      (fun () ->
         match Path.Build.explode src with
         | ["install"; _ctx; "lib"; package_name; "META"] ->
           copy_special_file ~src ~package_name ~ic ~oc ~f:process_meta
         | ["install"; _ctx; "lib"; package_name; "dune-package"] ->
           copy_special_file ~src ~package_name ~ic ~oc ~f:process_dune_package
         | _ ->
           Dune.Artifact_substitution.copy ~get_vcs ~input:(input ic)
             ~output:(output oc))

  let remove_if_exists dst =
    if Path.exists dst then begin
      Printf.eprintf
        "Deleting %s\n%!"
        (Path.to_string_maybe_quoted dst);
      print_unix_error (fun () -> Path.unlink dst)
    end

  let remove_dir_if_empty dir =
    if Path.exists dir then
      match Path.readdir_unsorted dir with
      | Ok [] ->
        Printf.eprintf "Deleting empty directory %s\n%!"
          (Path.to_string_maybe_quoted dir);
        print_unix_error (fun () -> Path.rmdir dir)
      | Error e ->
        User_message.prerr
          (User_error.make
             [ Pp.text (Unix.error_message e) ])
      | _  -> ()

  let mkdir_p = Path.mkdir_p
end

let file_operations ~dry_run ~workspace : (module File_operations) =
  if dry_run then
    (module File_ops_dry_run)
  else
    (module File_ops_real(struct
         let workspace = workspace
       end))

let install_uninstall ~what =
  let doc =
    sprintf "%s packages." (String.capitalize what)
  in
  let name_ = Arg.info [] ~docv:"PACKAGE" in
  let term =
    let+ common = Common.term
    and+ prefix_from_command_line =
      Arg.(value
           & opt (some string) None
           & info ["prefix"]
               ~docv:"PREFIX"
               ~doc:"Directory where files are copied. For instance binaries \
                     are copied into $(i,\\$prefix/bin), library files into \
                     $(i,\\$prefix/lib), etc... It defaults to the current opam \
                     prefix if opam is available and configured, otherwise it uses \
                     the same prefix as the ocaml compiler.")
    and+ libdir_from_command_line =
      Arg.(value
           & opt (some string) None
           & info ["libdir"]
               ~docv:"PATH"
               ~doc:"Directory where library files are copied, relative to \
                     $(b,prefix) or absolute. If $(b,--prefix) \
                     is specified the default is $(i,\\$prefix/lib), otherwise \
                     it is the output of $(b,ocamlfind printconf destdir)"
          )
    and+ destdir =
      Arg.(value
           & opt (some string) None
           & info ["destdir"]
               ~env:(env_var "DESTDIR")
               ~docv:"PATH"
               ~doc:"When passed, this directory is prepended to all \
                     installed paths."
          )
    and+ dry_run =
      Arg.(value
           & flag
           & info ["dry-run"]
               ~doc:"Only display the file operations that would be performed."
          )
    and+ pkgs =
      Arg.(value & pos_all package_name [] name_)
    in
    Common.set_common common ~targets:[];
    let log = Log.create common in
    Scheduler.go ~log ~common (fun () ->
      let open Fiber.O in
      let* workspace = Import.Main.scan_workspace ~log common in
      let pkgs =
        match pkgs with
        | [] -> Package.Name.Map.keys workspace.conf.packages
        | l  -> l
      in
      let install_files, missing_install_files =
        List.concat_map pkgs ~f:(fun pkg ->
          let fn = resolve_package_install workspace pkg in
          List.map workspace.contexts ~f:(fun ctx ->
            let fn = Path.append_source (Path.build ctx.Context.build_dir) fn in
            if Path.exists fn then
              Left (ctx, (pkg, fn))
            else
              Right fn))
        |> List.partition_map ~f:Fn.id
      in
      if missing_install_files <> [] then begin
        User_error.raise
          [ Pp.textf "The following <package>.install are missing:"
          ; Pp.enumerate missing_install_files ~f:(fun p ->
              Pp.text (Path.to_string p))
          ]
          ~hints:[ Pp.text "try running: dune build @install" ]
      end;
      (match
         workspace.contexts,
         prefix_from_command_line,
         libdir_from_command_line
       with
       | _ :: _ :: _, Some _, _ | _ :: _ :: _, _, Some _ ->
         User_error.raise
           [ Pp.text "Cannot specify --prefix or --libdir when installing \
                      into multiple contexts!"
           ]
       | _ -> ());
      let module CMap = Map.Make(Context) in
      let install_files_by_context =
        CMap.of_list_multi install_files
        |> CMap.to_list
        |> List.map ~f:(fun (context, install_files) ->
          let entries_per_package =
            List.map install_files ~f:(fun (package, install_file) ->
              let entries = Install.load_install_file install_file in
              match
                List.filter_map entries ~f:(fun entry ->
                  Option.some_if
                    (not (Path.exists (Path.build entry.src)))
                    entry.src)
              with
              | [] -> (package, entries)
              | missing_files ->
                User_error.raise
                  [ Pp.textf
                      "The following files which are listed in %s \
                       cannot be installed because they do not exist:"
                      (Path.to_string_maybe_quoted install_file)
                  ; Pp.enumerate missing_files ~f:(fun p ->
                      Pp.verbatim (Path.Build.to_string_maybe_quoted p))
                  ])
          in
          (context, entries_per_package))
      in
      let (module Ops) = file_operations ~dry_run ~workspace in
      let files_deleted_in = ref Path.Set.empty in
      let+ () =
        Fiber.sequential_iter install_files_by_context
          ~f:(fun (context, entries_per_package) ->
            let* (prefix, libdir) =
              get_dirs context ~prefix_from_command_line
                ~libdir_from_command_line
            in
            Fiber.sequential_iter entries_per_package
              ~f:(fun (package, entries) ->
                let paths =
                  Install.Section.Paths.make
                    ~package
                    ~destdir:prefix
                    ?libdir
                    ()
                in
                Fiber.sequential_iter entries ~f:(fun entry ->
                  let dst =
                    Install.Entry.relative_installed_path entry ~paths
                    |> interpret_destdir ~destdir
                  in
                  let dir = Path.parent_exn dst in
                  if what = "install" then begin
                    Printf.eprintf "Installing %s\n%!"
                      (Path.to_string_maybe_quoted dst);
                    Ops.mkdir_p dir;
                    let executable =
                      Install.Section.should_set_executable_bit entry.section
                    in
                    Ops.copy_file ~src:entry.src ~dst ~executable
                  end else begin
                    Ops.remove_if_exists dst;
                    files_deleted_in := Path.Set.add !files_deleted_in dir;
                    Fiber.return ()
                  end)))
      in
      Path.Set.to_list !files_deleted_in
      (* This [List.rev] is to ensure we process children
         directories before their parents *)
      |> List.rev
      |> List.iter ~f:Ops.remove_dir_if_empty)
  in
  (term, Cmdliner.Term.info what ~doc ~man:Common.help_secs)

let install   = install_uninstall ~what:"install"
let uninstall = install_uninstall ~what:"uninstall"
