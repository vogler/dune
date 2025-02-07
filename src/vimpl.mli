(** Extra information required to generate rules for virtual library
    implementations *)

open Stdune

type t

val make
  :  vlib:Lib.t
  -> impl:Dune_file.Library.t
  -> vlib_modules:Modules.t
  -> vlib_foreign_objects:Path.t list
  -> vlib_dep_graph:Dep_graph.Ml_kind.t
  -> t

val impl : t -> Dune_file.Library.t

(** Return the library module information for the virtual library. Required for
    setting up the copying rules *)
val vlib_modules : t -> Modules.t

val impl_modules : t option -> Modules.t -> Modules.t

val vlib : t -> Lib.t

val vlib_dep_graph : t -> Dep_graph.Ml_kind.t

(** Return the combined list of .o files for stubs consisting of .o files from
    the implementation and virtual library.*)
val vlib_stubs_o_files : t option -> Path.t list
