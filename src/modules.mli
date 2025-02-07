(** Module layout information. Contains infromation about aliasing, wrapping. *)
open Stdune

type t

val to_dyn : t -> Dyn.t

val lib
  : src_dir:Path.Build.t
  -> main_module_name:Module.Name.t option
  -> wrapped:Wrapped.t
  -> lib:Dune_file.Library.t
  -> modules: Module.Name_map.t
  -> t

val encode : t -> Dune_lang.t

val decode
  : version:Syntax.Version.t
  -> src_dir:Path.t
  -> implements:bool
  -> t Dune_lang.Decoder.t

val impl : t -> vlib:t -> t

val find_dep : t -> of_:Module.t -> Module.Name.t -> Module.t option

val find : t -> Module.Name.t -> Module.t option

val compat_for_exn : t -> Module.t -> Module.t

val impl_only : t -> Module.t list

val singleton_exe : Module.t -> t

val fold_no_vlib : t -> init:'acc -> f:(Module.t -> 'acc -> 'acc) -> 'acc

val iter_no_vlib : t -> f:(Module.t -> unit) -> unit

val exe_unwrapped : Module.Name_map.t -> t
val exe_wrapped
  :  src_dir:Path.Build.t
  -> modules:Module.Name_map.t
  -> t

(** For wrapped libraries, this is the user written entry module for the
    library. For single module libraries, it's the sole module in the library *)
val lib_interface : t -> Module.t option

(** Returns the modules that need to be aliased in the alias module *)
val for_alias : t -> Module.Name_map.t

val fold_user_written
  :  t
  -> f:(Module.t -> 'acc -> 'acc)
  -> init:'acc
  -> 'acc

val map_user_written : t -> f:(Module.t -> Module.t) -> t

(** Returns all the compatibility modules. *)
val wrapped_compat : t -> Module.Name_map.t

val obj_map : t -> f:(Module.t -> 'a) -> 'a Module.Obj_map.t

(** List of entry modules visible to users of the library. For wrapped
    libraries, this is always one module. For unwrapped libraries, this could be
    more than one. *)
val entry_modules : t -> Module.t list

(** Returns the main module name if it exists. It exist for libraries with
   [(wrapped true)] or one module libraries. *)
val main_module_name : t -> Module.Name.t option

(** Returns only the virtual module names in the library *)
val virtual_module_names : t -> Module.Name.Set.t

(** Returns the alias module if it exists. This module only exists for [(wrapped
    true)] and when there is more than 1 module. *)
val alias_module : t -> Module.t option

val wrapped : t -> Wrapped.t

val version_installed : t -> install_dir:Path.t -> t

val alias_for : t -> Module.t -> Module.t option

val is_stdlib_alias : t -> Module.t -> bool

val exit_module : t -> Module.t option

(** [relcoate_alias_module t ~src_dir] sets the source directory of the alias
    module to [src_dir]. Only works if [t] is wrapped. *)
val relocate_alias_module : t -> src_dir:Path.t -> t
