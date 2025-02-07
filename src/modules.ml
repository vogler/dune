open Stdune

module Mode = Wrapped

module Common = struct
  module Encode = struct
    open Dune_lang.Encoder

    let main_module_name = field "main_module_name" Module.Name.encode
    let modules ?(name="modules") modules =
      field_l name (fun x -> x) (Module.Name_map.encode modules)
  end

  module Decode = struct
    open Stanza.Decoder
    let main_module_name = field "main_module_name" Module.Name.decode
    let modules ?(name="modules") ~src_dir () =
      field ~default:Module.Name.Map.empty name
        (Module.Name_map.decode ~src_dir)
  end
end

module Stdlib = struct
  type t =
    { modules : Module.Name_map.t
    ; unwrapped : Module.Name.Set.t
    ; exit_module : Module.Name.t option
    ; main_module_name : Module.Name.t
    }

  let encode { modules; unwrapped; exit_module; main_module_name } =
    let open Dune_lang.Encoder in
    let module E = Common.Encode in
    record_fields
      [ E.main_module_name main_module_name
      ; E.modules modules
      ; field_o "exit_module" Module.Name.encode exit_module
      ; field_l "unwrapped" Module.Name.encode
          (Module.Name.Set.to_list unwrapped)
      ]

  let decode ~src_dir =
    let open Stanza.Decoder in
    let open Common.Decode in
    fields (
      let+ main_module_name = main_module_name
      and+ modules = modules ~src_dir ()
      and+ exit_module = field_o "exit_module" Module.Name.decode
      and+ unwrapped = field ~default:[] "unwrapped"
                         (list (enter Module.Name.decode))
      in
      let unwrapped = Module.Name.Set.of_list unwrapped in
      { modules
      ; main_module_name
      ; exit_module
      ; unwrapped
      }
    )

  let to_dyn { modules ; unwrapped; exit_module; main_module_name } =
    let open Dyn.Encoder in
    record
      [ "modules", Module.Name_map.to_dyn modules
      ; "unwrapped", Module.Name.Set.to_dyn unwrapped
      ; "exit_module", option Module.Name.to_dyn exit_module
      ; "main_module_name", Module.Name.to_dyn main_module_name
      ]

  let exit_module t =
    let open Option.O in
    let* name = t.exit_module in
    Module.Name.Map.find t.modules name

  let fold t ~init ~f = Module.Name.Map.fold t.modules ~f ~init

  let map t ~f = { t with modules = Module.Name.Map.map t.modules ~f }

  let lib_interface t =
    Module.Name.Map.find t.modules t.main_module_name

  (* Returns [true] is a special module, i.e. one whose compilation unit name is
     hard-coded inside the compiler. It is not possible to change the
     compilation unit name of such modules, so they cannot be wrapped. *)
  let special_compiler_module (stdlib : Dune_file.Library.Stdlib.t) m =
    let name = Module.name m in
    Glob.test stdlib.internal_modules (Module.Name.to_string name) ||
    match stdlib.exit_module with
    | None -> false
    | Some n -> n = name

  let make ~(stdlib : Dune_file.Library.Stdlib.t) ~modules ~main_module_name =
    let modules =
    Module.Name.Map.map modules ~f:(fun m ->
      if Module.name m = main_module_name
      || special_compiler_module stdlib m then
        m
      else
        Module.with_wrapper m ~main_module_name)
    in
    let unwrapped = stdlib.modules_before_stdlib in
    let exit_module = stdlib.exit_module in
    { modules
    ; unwrapped
    ; exit_module
    ; main_module_name
    }

  let obj_map t ~f =
    Module.Name.Map.fold t.modules ~init:Module.Obj_map.empty
      ~f:(fun m acc -> Module.Obj_map.add_exn acc m (f m))

  let impl_only t =
    Module.Name.Map.values t.modules
    |> List.filter ~f:(fun m -> Some (Module.name m) <> t.exit_module)

  let find t = Module.Name.Map.find t.modules

  let find_dep t ~of_ name =
    let of_name = Module.name of_ in
    if of_name = t.main_module_name then
      if Module.Name.Set.mem t.unwrapped name then
        Module.Name.Map.find t.modules name
      else
        None
    else
      Module.Name.Map.find t.modules name

  let alias_for t m =
    let name = Module.name m in
    if name = t.main_module_name
    || Module.Name.Set.mem t.unwrapped name then
      None
    else
      lib_interface t
end

module Mangle = struct
  module Lib = struct
    type kind =
      | Has_lib_interface
      | Implementation of Lib_name.Local.t
      | Neither

    type t =
      { main_module_name : Module.Name.t
      ; kind : kind
      }
  end

  type t =
    | Lib of Lib.t
    | Exe

  let of_lib ~main_module_name ~modules ~(lib : Dune_file.Library.t) =
    let kind : Lib.kind =
      if Option.is_some lib.implements then
        Implementation (snd lib.name)
      else if Module.Name.Map.mem modules main_module_name then
        Has_lib_interface
      else
        Neither
    in
    Lib { main_module_name ; kind }

  let prefix t : Module.Name.t Visibility.Map.t =
    match t with
    | Lib { main_module_name ; kind } ->
      begin match kind with
      | Has_lib_interface
      | Neither -> Visibility.Map.make_both main_module_name
      | Implementation lib ->
        { private_ =
            sprintf "%s__%s__"
              (Module.Name.to_string main_module_name)
              (Lib_name.Local.to_string lib)
            |> Module.Name.of_string
        ; public = main_module_name
        }
      end
    | Exe ->
      sprintf "dune__exe"
      |> Module.Name.of_string
      |> Visibility.Map.make_both

  let make_alias_module t ~src_dir =
    let prefix = prefix t in
    let name =
      match t with
      | Lib { kind = Has_lib_interface; _ } ->
        Module.Name.add_suffix prefix.public "__"
      | Lib { kind = Implementation _ ; _ } ->
        prefix.private_
      | _ -> prefix.public
    in
    Module.generated_alias ~src_dir name
end

module Wrapped = struct
  type t =
    { modules : Module.Name_map.t
    ; wrapped_compat : Module.Name_map.t
    ; alias_module : Module.t
    ; main_module_name : Module.Name.t
    ; wrapped : Mode.t
    }

  let encode
        { modules; wrapped_compat; alias_module; main_module_name; wrapped } =
    let open Dune_lang.Encoder in
    let module E = Common.Encode in
    record_fields
      [ E.main_module_name main_module_name
      ; E.modules modules
      ; field_l "alias_module" sexp (Module.encode alias_module)
      ; field "wrapped" Wrapped.encode wrapped
      ; E.modules ~name:"wrapped_compat" wrapped_compat
      ]

  let decode ~src_dir =
    let open Stanza.Decoder in
    let open Common.Decode in
    fields (
      let+ main_module_name = main_module_name
      and+ modules = modules ~src_dir ()
      and+ wrapped_compat = modules ~name:"wrapped_compat" ~src_dir ()
      and+ alias_module = field "alias_module" (Module.decode ~src_dir)
      and+ wrapped = field "wrapped" Mode.decode
      in
      { main_module_name
      ; modules
      ; wrapped_compat
      ; alias_module
      ; wrapped
      }
    )

  let map ({ modules; wrapped_compat; alias_module
           ; main_module_name = _; wrapped = _} as t) ~f =
    { t with
      modules = Module.Name.Map.map modules ~f
    ; wrapped_compat = Module.Name.Map.map wrapped_compat ~f
    ; alias_module = f alias_module
    }

  let wrap_modules prefix ~main_module_name ~modules =
    Module.Name.Map.map modules ~f:(fun (m : Module.t) ->
      if Module.name m = main_module_name then
        m
      else
        let visibility = Module.visibility m in
        let prefix = Visibility.Map.find prefix visibility in
        Module.with_wrapper m ~main_module_name:prefix)

  let make ~src_dir ~lib ~modules ~main_module_name ~wrapped =
    let mangle = Mangle.of_lib ~main_module_name ~lib ~modules in
    let (modules, wrapped_compat) =
      let prefix = Mangle.prefix mangle in
      let wrapped_modules =
        wrap_modules prefix ~main_module_name ~modules in
      match (wrapped : Mode.t) with
      | Simple false -> assert false
      | Simple true ->
        (wrapped_modules, Module.Name.Map.empty)
      | Yes_with_transition _ ->
        ( wrapped_modules
        , Module.Name.Map.remove modules main_module_name
          |> Module.Name.Map.filter_map ~f:(fun m ->
            match Module.visibility m with
            | Public -> Some (Module.wrapped_compat m)
            | Private -> None)
        )
    in
    let alias_module = Mangle.make_alias_module ~src_dir mangle in
    { modules
    ; alias_module
    ; wrapped_compat
    ; main_module_name
    ; wrapped
    }

  let exe ~src_dir ~modules =
    let mangle = Mangle.Exe in
    let prefix = Mangle.prefix mangle in
    let alias_module = Mangle.make_alias_module mangle ~src_dir in
    let modules =
      Module.Name.Map.map modules ~f:(fun m ->
        Module.with_wrapper m ~main_module_name:prefix.public)
    in
    { modules
    ; wrapped_compat = Module.Name.Map.empty
    ; alias_module
    (* XXX exe's don't have a main module, but this is harmless *)
    ; main_module_name = Module.name alias_module
    ; wrapped = Simple true
    }

  let obj_map { modules; wrapped_compat; alias_module; main_module_name = _
              ; wrapped = _ } ~f =
    let init = Module.Obj_map.singleton alias_module (f alias_module) in
    let acc =
      Module.Name.Map.fold ~f:(fun m acc ->
        Module.Obj_map.add_exn acc m (f m)) in
    acc modules ~init:(acc wrapped_compat ~init)

  let to_dyn { modules; wrapped_compat; alias_module; main_module_name
             ; wrapped } =
    let open Dyn.Encoder in
    record
      [ "modules", Module.Name_map.to_dyn modules
      ; "wrapped_compat", Module.Name_map.to_dyn wrapped_compat
      ; "alias_module", Module.to_dyn alias_module
      ; "main_module_name", Module.Name.to_dyn main_module_name
      ; "wrapped", Wrapped.to_dyn wrapped
      ]

  let is_alias_name t name = Module.name t.alias_module = name

  let impl_only { modules; wrapped_compat; alias_module
                ; main_module_name = _; wrapped = _ }
    =
    let modules =
      Module.Name_map.impl_only modules
      @ Module.Name.Map.values wrapped_compat
    in
    alias_module :: modules

  let fold { modules; wrapped_compat; alias_module;
             main_module_name = _ ; wrapped = _ }
        ~init ~f =
    let init = f alias_module init in
    let init = Module.Name.Map.fold modules ~f ~init in
    Module.Name.Map.fold wrapped_compat ~f ~init

  let lib_interface t =
    Module.Name.Map.find t.modules t.main_module_name

  let find t name =
    if is_alias_name t name then
      Some t.alias_module
    else
      begin match Module.Name.Map.find t.modules name with
      | Some _ as m -> m
      | None -> Module.Name.Map.find t.wrapped_compat name
      end

  let find_dep t ~of_ name =
    match Module.kind of_ with
    | Alias -> None
    | Wrapped_compat ->
      begin match lib_interface t with
      | Some li -> Option.some_if (name = Module.name li) li
      | None -> Module.Name.Map.find t.modules name
      end
    | _ ->
      if is_alias_name t name then
        Some t.alias_module
      else
        Module.Name.Map.find t.modules name

  let alias_for t m =
    match Module.kind m with
    | Alias
    | Wrapped_compat -> None
    | _ -> Some t.alias_module

  let relocate_alias_module t ~src_dir =
    let alias_module = Module.set_src_dir t.alias_module ~src_dir in
    { t with alias_module }
end

type t =
  | Singleton of Module.t
  | Unwrapped of Module.Name_map.t
  | Wrapped of Wrapped.t
  | Impl of impl
  | Stdlib of Stdlib.t

and impl =
  { impl : t
  ; vlib : t
  }

let rec encode t =
  let open Dune_lang in
  match t with
  | Singleton m -> List (atom "singleton" :: Module.encode m)
  | Unwrapped m -> List (atom "unwrapped" :: Module.Name_map.encode m)
  | Wrapped m -> List (atom "wrapped" :: Wrapped.encode m)
  | Stdlib m -> List (atom "stdlib" :: Stdlib.encode m)
  | Impl { impl ; _ } -> encode impl

let as_singleton m =
  if Module.Name.Map.cardinal m <> 1 then
    None
  else
    Module.Name.Map.choose m
    |> Option.map ~f:snd

(* Pre-1.11 encoding *)
module Old_format = struct
  let decode ~implements ~src_dir =
    let open Stanza.Decoder in
    fields (
      let+ loc = loc
      and+ alias_module = field_o "alias_module" (Module.decode ~src_dir)
      and+ main_module_name = field_o "main_module_name" Module.Name.decode
      and+ modules =
        field ~default:[] "modules" (list (enter (Module.decode ~src_dir)))
      and+ wrapped = field "wrapped" Mode.decode
      in
      let modules =
        modules
        |> List.map ~f:(fun m -> (Module.name m, m))
        |> Module.Name.Map.of_list_exn
      in
      match wrapped with
      | Simple false -> begin
          match as_singleton modules with
          | Some m -> Singleton m
          | None -> Unwrapped modules
        end
      | (Yes_with_transition _ | Simple true) ->
        match main_module_name, alias_module, as_singleton modules with
        | Some main_module_name, _, Some m
          when Module.name m = main_module_name && not implements ->
          Singleton m
        | Some main_module_name, Some alias_module, _ ->
          Wrapped
            { modules
            ; wrapped_compat = Module.Name.Map.empty
            ; alias_module
            ; main_module_name
            ; wrapped
            }
        | None, _, _ | _, None, _ ->
          User_error.raise ~loc
            [ Pp.text "Cannot wrap without main module name or alias module" ]
    )
end

let decode ~version ~src_dir ~implements =
  if version <= (1, 10) then
    Old_format.decode ~implements ~src_dir
  else
    let open Stanza.Decoder in
    sum
      [ "singleton", (
          let+ m = Module.decode ~src_dir in
          Singleton m
        )
      ; "unwrapped", (
          let+ modules = Module.Name_map.decode ~src_dir in
          Unwrapped modules
        )
      ; "wrapped", (
          let+ w = Wrapped.decode ~src_dir in
          Wrapped w
        )
      ; "stdlib", (
          let+ stdlib = Stdlib.decode ~src_dir in
          Stdlib stdlib
        )
      ]

let rec to_dyn =
  let open Dyn.Encoder in
  function
  | Singleton m -> constr "Singleton" [Module.to_dyn m]
  | Unwrapped m -> constr "Unwrapped" [Module.Name_map.to_dyn m]
  | Wrapped w -> constr "Wrapped" [Wrapped.to_dyn w]
  | Stdlib s -> constr "Stdlib" [Stdlib.to_dyn s]
  | Impl impl -> constr "Impl" [dyn_of_impl impl]

and dyn_of_impl { impl; vlib } =
  let open Dyn.Encoder in
  record
    [ "impl", to_dyn impl
    ; "vlib", to_dyn vlib
    ]

let rec lib_interface = function
  | Singleton m -> Some m
  | Unwrapped _ -> None
  | Wrapped w -> Wrapped.lib_interface w
  | Stdlib w -> Stdlib.lib_interface w
  | Impl { impl = _; vlib } -> lib_interface vlib

let rec main_module_name = function
  | Singleton m -> Some (Module.name m)
  | Unwrapped _ -> None
  | Wrapped w -> Some w.main_module_name
  | Stdlib w -> Some w.main_module_name
  | Impl { vlib ; impl = _ } -> main_module_name vlib

let lib ~src_dir ~main_module_name ~wrapped ~lib ~modules =
  let make_wrapped main_module_name =
    Wrapped (Wrapped.make ~src_dir ~lib ~modules ~main_module_name ~wrapped)
  in
  match lib.stdlib with
  | Some stdlib ->
    let main_module_name = Option.value_exn main_module_name in
    Stdlib (Stdlib.make ~stdlib ~modules ~main_module_name)
  | None ->
    begin match wrapped, main_module_name, as_singleton modules with
    | Simple false, _, Some m -> Singleton m
    | Simple false, _, None -> Unwrapped modules
    | (Yes_with_transition _ | Simple true), Some main_module_name, Some m ->
      let implements = Dune_file.Library.is_impl lib in
      if Module.name m = main_module_name && not implements then
        Singleton m
      else
        make_wrapped main_module_name
    | (Yes_with_transition _ | Simple true), Some main_module_name, None ->
      make_wrapped main_module_name
    | (Simple true | Yes_with_transition _), None, _ ->
      Code_error.raise "Modules.lib: cannot wrap without main module name"
        []
    end

let impl impl ~vlib =
  match impl, vlib with
  | _, Impl _ | Impl _, _
  | Stdlib _, _ | _, Stdlib _ ->
    Code_error.raise "Modules.impl: invalid arguments"
      [ "impl", to_dyn impl
      ; "vlib", to_dyn vlib
      ]
  | _, _ -> Impl { impl; vlib }

let rec find t name =
  match t with
  | Singleton m ->
    Option.some_if (Module.name m = name) m
  | Unwrapped m -> Module.Name.Map.find m name
  | Stdlib w -> Stdlib.find w name
  | Wrapped w -> Wrapped.find w name
  | Impl { impl; vlib } ->
    begin match find impl name with
    | Some _ as m -> m
    | None -> find vlib name
    end

type from = Vlib | Impl_or_lib

let from_impl_or_lib = Option.map ~f:(fun m -> (Impl_or_lib, m))

let rec find_dep t ~of_ name =
  if Module.name of_ = name then
    None
  else
    let open Option.O in
    let* (from, m) =
      match t with
      | Stdlib s -> from_impl_or_lib (Stdlib.find_dep s ~of_ name)
      | Wrapped w -> from_impl_or_lib (Wrapped.find_dep w ~of_ name)
      | Impl { vlib; impl } ->
        begin match find_dep impl ~of_ name with
        | Some m -> Some (Impl_or_lib, m)
        | None ->
          let open Option.O in
          let+ m = find_dep vlib ~of_ name in
          (Vlib, m)
        end
      | _ -> from_impl_or_lib (find t name)
    in
    match from with
    | Impl_or_lib -> Some m
    | Vlib -> Option.some_if (Module.visibility m = Public) m

let singleton_exe m =
  Singleton (
    let mangle = Mangle.Exe in
    let main_module_name = (Mangle.prefix mangle).public in
    Module.with_wrapper m ~main_module_name
  )

let exe_unwrapped m = Unwrapped m
let exe_wrapped ~src_dir ~modules =
  match as_singleton modules with
  | None -> Wrapped (Wrapped.exe ~src_dir ~modules)
  | Some m -> singleton_exe m

let rec impl_only = function
  | Stdlib w -> Stdlib.impl_only w
  | Singleton m ->
    if Module.has ~ml_kind:Impl m then
      [m]
    else
      []
  | Unwrapped m -> Module.Name_map.impl_only m
  | Wrapped w -> Wrapped.impl_only w
  | Impl { vlib ; impl } ->
    impl_only impl @ impl_only vlib

let rec fold_no_vlib t ~init ~f =
  match t with
  | Stdlib w -> Stdlib.fold w ~init ~f
  | Singleton m -> f m init
  | Unwrapped m -> Module.Name.Map.fold m ~f ~init
  | Wrapped w -> Wrapped.fold w ~init ~f
  | Impl { vlib = _; impl } -> fold_no_vlib impl ~f ~init

let compat_for_exn t m =
  match t with
  | Singleton _
  | Stdlib _
  | Unwrapped _ -> assert false
  | Wrapped { modules ; _ } ->
    Module.Name.Map.find modules (Module.name m)
    |> Option.value_exn
  | Impl _ ->
    Code_error.raise "wrapped compat not supported for vlib"
      []

let iter_no_vlib t ~f =
  fold_no_vlib t ~init:() ~f:(fun x () -> f x)

let rec for_alias = function
  | Stdlib _
  | Singleton _
  | Unwrapped _ -> Module.Name.Map.empty
  | Wrapped { modules ; main_module_name ; alias_module = _
            ; wrapped_compat = _ ; wrapped = _} ->
    Module.Name.Map.remove modules main_module_name
  | Impl { vlib ; impl } ->
    let impl = for_alias impl in
    let vlib = for_alias vlib in
    Module.Name.Map.merge impl vlib ~f:(fun _ impl vlib ->
      match impl, vlib with
      | None, None -> assert false
      | Some _, _ -> impl
      | _, Some vlib ->
        Option.some_if (Module.visibility vlib = Public) vlib)

let wrapped_compat = function
  | Stdlib _
  | Singleton _
  | Impl _
  | Unwrapped _ -> Module.Name.Map.empty
  | Wrapped w -> w.wrapped_compat

let rec fold_user_written t ~f ~init =
  match t with
  | Stdlib w -> Stdlib.fold w ~init ~f
  | Singleton m -> f m init
  | Wrapped { modules ; _ }
  | Unwrapped modules -> Module.Name.Map.fold modules ~init ~f
  | Impl { impl ; vlib = _ } -> fold_user_written impl ~f ~init

let rec map_user_written t ~f =
  match t with
  | Singleton m -> Singleton (f m)
  | Unwrapped m -> Unwrapped (Module.Name.Map.map m ~f)
  | Stdlib w -> Stdlib (Stdlib.map w ~f)
  | Wrapped ({ modules
             ; alias_module = _
             ; main_module_name = _
             ; wrapped_compat = _
             ; wrapped = _
             } as w) ->
    let modules = Module.Name.Map.map modules ~f in
    Wrapped { w with modules}
  | Impl t ->
    Impl { t with vlib = map_user_written t.vlib ~f }

let version_installed t ~install_dir =
  let f = Module.set_src_dir ~src_dir:install_dir in
  let rec loop = function
    | Singleton m -> Singleton (f m)
    | Unwrapped m -> Unwrapped (Module.Name.Map.map ~f m)
    | Stdlib w -> Stdlib (Stdlib.map w ~f)
    | Wrapped w -> Wrapped (Wrapped.map w ~f)
    | Impl w -> Impl { w with impl = loop w.impl }
  in
  loop t

let rec obj_map t ~f =
  match t with
  | Singleton m -> Module.Obj_map.add_exn Module.Obj_map.empty m (f m)
  | Unwrapped m ->
    Module.Name.Map.fold m ~init:Module.Obj_map.empty ~f:(fun m acc ->
      Module.Obj_map.add_exn acc m (f m))
  | Wrapped w -> Wrapped.obj_map w ~f
  | Stdlib w -> Stdlib.obj_map w ~f
  | Impl { impl ; vlib = _ } -> obj_map impl ~f

(* TODO perhaps return only public modules? *)
let entry_modules = function
  | Stdlib w -> Stdlib.lib_interface w |> Option.to_list
  | Singleton m -> [m]
  | Unwrapped m -> Module.Name.Map.values m
  | Wrapped m ->
    (* we assume this is never called for implementations *)
    begin match Wrapped.lib_interface m with
    | Some m -> [m]
    | None -> [m.alias_module]
    end
  | Impl i ->
    Code_error.raise "entry_modules: not defined for implementations"
      ["impl", dyn_of_impl i]

let virtual_module_names =
  fold_no_vlib ~init:Module.Name.Set.empty ~f:(fun m acc ->
    match Module.kind m with
    | Virtual -> Module.Name.Set.add acc (Module.name m)
    | _ -> acc)

let rec alias_module = function
  | Stdlib _
  | Singleton _
  | Unwrapped _ -> None
  | Wrapped w -> Some w.alias_module
  | Impl { impl; vlib = _ } -> alias_module impl

let rec wrapped = function
  | Wrapped w -> w.wrapped
  | Singleton _
  | Unwrapped _ -> Simple false
  | Stdlib _ -> Simple true
  | Impl { vlib = _; impl } -> wrapped impl

let rec alias_for t m =
  match t with
  | Singleton _
  | Unwrapped _ -> None
  | Wrapped w -> Wrapped.alias_for w m
  | Stdlib w -> Stdlib.alias_for w m
  | Impl { impl ; vlib = _ } -> alias_for impl m

let is_stdlib_alias t m =
  match t with
  | Stdlib w -> w.main_module_name = Module.name m
  | _ -> false

let exit_module = function
  | Stdlib w -> Stdlib.exit_module w
  | _ -> None

let relocate_alias_module t ~src_dir =
  match t with
  | Wrapped t -> Wrapped (Wrapped.relocate_alias_module t ~src_dir)
  | s -> s
