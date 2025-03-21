open Import
open Dune_lang.Decoder

(* This file defines Dune types as well as the S-expression syntax for the
   various supported versions of the specification. *)

(* Deprecated *)
module Jbuild_version = struct
  type t = V1

  let decode = enum [ "1", V1 ]
end

let () =
  Dune_project.Extension.register_deleted ~name:"library_variants" ~deleted_in:(2, 6)
;;

module Lint = struct
  type t = Preprocess.Without_instrumentation.t Preprocess.Per_module.t

  let decode = Preprocess.Per_module.decode
  let default = Preprocess.Per_module.default ()
  let no_lint = default
end

type for_ =
  | Executable
  | Library of Wrapped.t option

module Buildable = struct
  type t =
    { loc : Loc.t
    ; modules : Stanza_common.Modules_settings.t
    ; empty_module_interface_if_absent : bool
    ; libraries : Lib_dep.t list
    ; foreign_archives : (Loc.t * Foreign.Archive.t) list
    ; extra_objects : Foreign.Objects.t
    ; foreign_stubs : Foreign.Stubs.t list
    ; preprocess : Preprocess.With_instrumentation.t Preprocess.Per_module.t
    ; preprocessor_deps : Dep_conf.t list
    ; lint : Preprocess.Without_instrumentation.t Preprocess.Per_module.t
    ; flags : Ocaml_flags.Spec.t
    ; js_of_ocaml : Js_of_ocaml.In_buildable.t
    ; allow_overlapping_dependencies : bool
    ; ctypes : Ctypes_field.t option
    }

  let decode (for_ : for_) =
    let use_foreign =
      Dune_lang.Syntax.deleted_in
        Stanza.syntax
        (2, 0)
        ~extra_info:"Use the (foreign_stubs ...) field instead."
    in
    let only_in_library decode =
      match for_ with
      | Executable -> return None
      | Library _ -> decode
    in
    let add_stubs language ~loc ~names ~flags foreign_stubs =
      match names with
      | None -> foreign_stubs
      | Some names ->
        let names = Ordered_set_lang.replace_standard_with_empty names in
        let flags = Option.value ~default:Ordered_set_lang.Unexpanded.standard flags in
        Foreign.Stubs.make ~loc ~language ~names ~mode:Mode.Select.All ~flags
        :: foreign_stubs
    in
    let+ loc = loc
    and+ preprocess, preprocessor_deps = Stanza_common.preprocess_fields
    and+ lint = field "lint" Lint.decode ~default:Lint.default
    and+ foreign_stubs =
      multi_field
        "foreign_stubs"
        (Dune_lang.Syntax.since Stanza.syntax (2, 0) >>> Foreign.Stubs.decode)
    and+ foreign_archives =
      field_o
        "foreign_archives"
        (Dune_lang.Syntax.since Stanza.syntax (2, 0)
         >>> repeat (located Foreign.Archive.decode))
    and+ extra_objects =
      field_o
        "extra_objects"
        (Dune_lang.Syntax.since Stanza.syntax (3, 5) >>> Foreign.Objects.decode)
    and+ c_flags =
      only_in_library
        (field_o "c_flags" (use_foreign >>> Ordered_set_lang.Unexpanded.decode))
    and+ cxx_flags =
      only_in_library
        (field_o "cxx_flags" (use_foreign >>> Ordered_set_lang.Unexpanded.decode))
    and+ c_names_loc, c_names =
      located
        (only_in_library (field_o "c_names" (use_foreign >>> Ordered_set_lang.decode)))
    and+ cxx_names_loc, cxx_names =
      located
        (only_in_library (field_o "cxx_names" (use_foreign >>> Ordered_set_lang.decode)))
    and+ modules = Stanza_common.Modules_settings.decode
    and+ self_build_stubs_archive_loc, self_build_stubs_archive =
      located
        (only_in_library
           (field
              ~default:None
              "self_build_stubs_archive"
              (Dune_lang.Syntax.deleted_in
                 Stanza.syntax
                 (2, 0)
                 ~extra_info:"Use the (foreign_archives ...) field instead."
               >>> enter (maybe string))))
    and+ libraries =
      let allow_re_export =
        match for_ with
        | Library _ -> true
        | Executable -> false
      in
      field "libraries" (Lib_dep.L.decode ~allow_re_export) ~default:[]
    and+ flags = Ocaml_flags.Spec.decode
    and+ js_of_ocaml =
      field
        "js_of_ocaml"
        Js_of_ocaml.In_buildable.decode
        ~default:Js_of_ocaml.In_buildable.default
    and+ allow_overlapping_dependencies = field_b "allow_overlapping_dependencies"
    and+ version = Dune_lang.Syntax.get_exn Stanza.syntax
    and+ ctypes =
      field_o
        "ctypes"
        (Dune_lang.Syntax.since Ctypes_field.syntax (0, 1) >>> Ctypes_field.decode)
    and+ loc_instrumentation, instrumentation = Stanza_common.instrumentation
    and+ empty_module_interface_if_absent =
      field_b
        "empty_module_interface_if_absent"
        ~check:(Dune_lang.Syntax.since Stanza.syntax (3, 0))
    in
    let preprocess =
      let init =
        let f libname = Preprocess.With_instrumentation.Ordinary libname in
        Module_name.Per_item.map preprocess ~f:(Preprocess.map ~f)
      in
      List.fold_left instrumentation ~init ~f:(fun accu ((backend, flags), deps) ->
        Preprocess.Per_module.add_instrumentation
          accu
          ~loc:loc_instrumentation
          ~flags
          ~deps
          backend)
    in
    let foreign_stubs =
      foreign_stubs
      |> add_stubs C ~loc:c_names_loc ~names:c_names ~flags:c_flags
      |> add_stubs Cxx ~loc:cxx_names_loc ~names:cxx_names ~flags:cxx_flags
    in
    let libraries =
      let ctypes_libraries =
        if Option.is_none ctypes
        then []
        else Ctypes_stubs.libraries_needed_for_ctypes ~loc:Loc.none
      in
      libraries @ ctypes_libraries
    in
    let foreign_archives =
      let foreign_archives = Option.value ~default:[] foreign_archives in
      if version < (2, 0)
         && List.is_non_empty foreign_stubs
         && Option.is_some self_build_stubs_archive
      then
        User_error.raise
          ~loc:self_build_stubs_archive_loc
          [ Pp.concat
              [ Pp.textf "A library cannot use "
              ; Pp.hbox (Pp.textf "(self_build_stubs_archive ...)")
              ; Pp.textf " and "
              ; Pp.hbox (Pp.textf "(c_names ...)")
              ; Pp.textf " simultaneously. This is supported starting from "
              ; Pp.hbox (Pp.textf "Dune 2.0.")
              ]
          ]
      else (
        match self_build_stubs_archive with
        | None -> foreign_archives
        (* Note: we add "_stubs" to the name, since [self_build_stubs_archive]
           used this naming convention; [foreign_archives] does not use it and
           allows users to name archives as they like (they still need to add
           the "lib" prefix, however, since standard linkers require it). *)
        | Some name -> (loc, Foreign.Archive.stubs name) :: foreign_archives)
    in
    let extra_objects = Option.value ~default:Foreign.Objects.empty extra_objects in
    { loc
    ; preprocess
    ; preprocessor_deps
    ; lint
    ; modules
    ; empty_module_interface_if_absent
    ; foreign_stubs
    ; foreign_archives
    ; extra_objects
    ; libraries
    ; flags
    ; js_of_ocaml
    ; allow_overlapping_dependencies
    ; ctypes
    }
  ;;

  let has_foreign t =
    List.is_non_empty t.foreign_stubs
    || List.is_non_empty t.foreign_archives
    || (not (Foreign.Objects.is_empty t.extra_objects))
    || Option.is_some t.ctypes
  ;;

  let has_foreign_cxx t =
    List.exists
      ~f:(fun stub -> Foreign_language.(equal Cxx stub.Foreign.Stubs.language))
      t.foreign_stubs
  ;;

  let has_mode_dependent_foreign_stubs t =
    List.exists ~f:Foreign.Stubs.is_mode_dependent t.foreign_stubs
  ;;

  let has_foreign_stubs t =
    List.is_non_empty t.foreign_stubs || Ctypes_field.has_stubs t.ctypes
  ;;
end

module Public_lib = struct
  type t =
    { name : Loc.t * Lib_name.t
    ; package : Package.t
    ; sub_dir : string option
    }

  let sub_dir t = t.sub_dir
  let loc t = fst t.name
  let name t = snd t.name
  let package t = t.package

  (** if [~allow_deprecated_names] is set, then we allow the package name to be
      attached to one of the deprecated packages *)
  let make ~allow_deprecated_names project ((_, s) as loc_name) =
    let pkg, rest = Lib_name.split s in
    let x =
      if not allow_deprecated_names
      then None
      else
        Dune_project.packages project
        |> Package.Name.Map.values
        |> List.find_map ~f:(fun package ->
          let deprecated_package_names = Package.deprecated_package_names package in
          if Package.Name.Map.mem deprecated_package_names pkg
          then Some { package; sub_dir = None; name = loc_name }
          else None)
    in
    match x with
    | Some x -> Ok x
    | None ->
      Stanza_common.Pkg.resolve project pkg
      |> Result.map ~f:(fun pkg ->
        { package = pkg
        ; sub_dir = (if rest = [] then None else Some (String.concat rest ~sep:"/"))
        ; name = loc_name
        })
  ;;

  let decode ~allow_deprecated_names =
    map_validate
      (let+ project = Dune_project.get_exn ()
       and+ loc_name = located Lib_name.decode in
       project, loc_name)
      ~f:(fun (project, loc_name) -> make ~allow_deprecated_names project loc_name)
  ;;
end

module Mode_conf = struct
  module T = struct
    type t =
      | Byte
      | Native
      | Best

    let all = [ Byte; Native; Best ]

    let compare x y =
      match x, y with
      | Byte, Byte -> Eq
      | Byte, _ -> Lt
      | _, Byte -> Gt
      | Native, Native -> Eq
      | Native, _ -> Lt
      | _, Native -> Gt
      | Best, Best -> Eq
    ;;
  end

  include T

  let decode = enum [ "byte", Byte; "native", Native; "best", Best ]

  let to_string = function
    | Byte -> "byte"
    | Native -> "native"
    | Best -> "best"
  ;;

  let to_dyn t = Dyn.variant (to_string t) []
  let encode t = Dune_lang.atom (to_string t)

  module Kind = struct
    type t =
      | Inherited
      | Requested of Loc.t
  end

  module Map = struct
    type nonrec 'a t =
      { byte : 'a
      ; native : 'a
      ; best : 'a
      }

    let find t = function
      | Byte -> t.byte
      | Native -> t.native
      | Best -> t.best
    ;;

    let update t key ~f =
      match key with
      | Byte -> { t with byte = f t.byte }
      | Native -> { t with native = f t.native }
      | Best -> { t with best = f t.best }
    ;;

    let make_one x = { byte = x; native = x; best = x }
  end

  type mode_conf = t

  module Set = struct
    type nonrec t = Kind.t option Map.t

    let empty : t = Map.make_one None

    let of_list (input : (mode_conf * Kind.t) list) : t =
      List.fold_left ~init:empty input ~f:(fun acc (key, kind) ->
        Map.update acc key ~f:(function
          | None -> Some kind
          | Some (Kind.Requested loc) ->
            User_error.raise ~loc [ Pp.textf "already configured" ]
          | Some Inherited ->
            (* this doesn't happen as inherited can't be manually specified *)
            assert false))
    ;;

    let to_list (t : t) : (mode_conf * Kind.t) list =
      let get mode_conf =
        match Map.find t mode_conf with
        | None -> None
        | Some k -> Some (mode_conf, k)
      in
      List.filter_map ~f:get all
    ;;

    let decode =
      let decode =
        let+ loc, t = located decode in
        t, Kind.Requested loc
      in
      repeat decode >>| of_list
    ;;

    let default loc : t =
      { empty with byte = Some Inherited; best = Some (Requested loc) }
    ;;

    module Details = struct
      type t = Kind.t option

      let validate t ~if_ = if if_ then t else None
      let ( ||| ) x y = if Option.is_some x then x else y
    end

    let eval_detailed t ~has_native =
      let exists = function
        | Best | Byte -> true
        | Native -> has_native
      in
      let get key : Details.t =
        match Map.find t key with
        | None -> None
        | Some Kind.Inherited -> Option.some_if (exists key) Kind.Inherited
        | Some (Kind.Requested loc) ->
          (* TODO always true for now, but we should delay this error *)
          let exists =
            exists key || User_error.raise ~loc [ Pp.text "this mode isn't available" ]
          in
          Option.some_if exists (Kind.Requested loc)
      in
      let best_mode = if has_native then Native else Byte in
      let best = get Best in
      let open Details in
      let byte = get Byte ||| validate best ~if_:(best_mode = Byte) in
      let native = get Native ||| validate best ~if_:(best_mode = Native) in
      { Mode.Dict.byte; native }
    ;;

    let eval t ~has_native =
      eval_detailed t ~has_native |> Mode.Dict.map ~f:Option.is_some
    ;;
  end

  module Lib = struct
    type t =
      | Ocaml of mode_conf
      | Melange

    let decode =
      enum'
        [ "byte", return @@ Ocaml Byte
        ; "native", return @@ Ocaml Native
        ; "best", return @@ Ocaml Best
        ; ( "melange"
          , Dune_lang.Syntax.since Melange_stanzas.syntax (0, 1) >>> return Melange )
        ]
    ;;

    let to_string = function
      | Ocaml Byte -> "byte"
      | Ocaml Native -> "native"
      | Ocaml Best -> "best"
      | Melange -> "melange"
    ;;

    let to_dyn t = Dyn.variant (to_string t) []

    let equal x y =
      match x, y with
      | Ocaml o1, Ocaml o2 ->
        (match compare o1 o2 with
         | Eq -> true
         | _ -> false)
      | Ocaml _, _ | _, Ocaml _ -> false
      | Melange, Melange -> true
    ;;

    module Map = struct
      type nonrec 'a t =
        { ocaml : 'a Map.t
        ; melange : 'a
        }

      let find t = function
        | Ocaml a -> Map.find t.ocaml a
        | Melange -> t.melange
      ;;

      let update t key ~f =
        match key with
        | Ocaml key -> { t with ocaml = Map.update t.ocaml key ~f }
        | Melange -> { t with melange = f t.melange }
      ;;

      let make_one x = { ocaml = Map.make_one x; melange = x }
    end

    module Set = struct
      type mode_conf = t
      type nonrec t = Kind.t option Map.t

      let empty : t = Map.make_one None

      let of_list (input : (mode_conf * Kind.t) list) : t =
        List.fold_left ~init:empty input ~f:(fun acc (key, kind) ->
          Map.update acc key ~f:(function
            | None -> Some kind
            | Some (Kind.Requested loc) ->
              User_error.raise ~loc [ Pp.textf "already configured" ]
            | Some Inherited ->
              (* this doesn't happen as inherited can't be manually specified *)
              assert false))
      ;;

      let decode_osl ~stanza_loc project =
        let+ modes = Ordered_set_lang.decode in
        let standard =
          Set.default stanza_loc |> Set.to_list |> List.map ~f:(fun (m, k) -> Ocaml m, k)
        in
        Ordered_set_lang.eval
          modes
          ~standard
          ~eq:(fun (a, _) (b, _) -> equal a b)
          ~parse:(fun ~loc s ->
            let mode =
              Dune_lang.Decoder.parse
                (Dune_project.set_parsing_context project decode)
                Univ_map.empty
                (Atom (loc, Dune_lang.Atom.of_string s))
            in
            mode, Kind.Requested loc)
        |> of_list
      ;;

      let decode =
        let decode =
          let+ loc, t = located decode in
          t, Kind.Requested loc
        in
        repeat decode >>| of_list
      ;;

      let default loc : t = { empty with ocaml = Set.default loc }

      module Details = struct
        type t = Kind.t option
      end

      let eval_detailed t ~has_native =
        let get key : Details.t = Map.find t key in
        let melange = get Melange in
        { Lib_mode.Map.ocaml = Set.eval_detailed t.ocaml ~has_native; melange }
      ;;

      let eval t ~has_native =
        eval_detailed t ~has_native |> Lib_mode.Map.map ~f:Option.is_some
      ;;
    end
  end
end

module Library = struct
  module Wrapped = struct
    include Wrapped

    let default = Simple true

    let make ~wrapped ~implements ~special_builtin_support : t Lib_info.Inherited.t =
      (match wrapped, special_builtin_support with
       | Some (loc, Yes_with_transition _), Some (_loc, _) ->
         (* TODO use _loc *)
         User_error.raise
           ~loc
           [ Pp.text
               "Cannot have transition modules for libraries with special builtin support"
           ]
       | _, _ -> ());
      match wrapped, implements with
      | None, None -> This default
      | None, Some w -> From w
      | Some (_loc, w), None -> This w
      | Some (loc, _), Some _ ->
        User_error.raise
          ~loc
          [ Pp.text
              "Wrapped cannot be set for implementations. It is inherited from the \
               virtual library."
          ]
    ;;

    let field = field_o "wrapped" (located decode)
  end

  module Modes = struct
    let decode ~stanza_loc ~dune_version project =
      let expected_version = 3, 8 in
      if dune_version >= expected_version
      then Mode_conf.Lib.Set.decode_osl ~stanza_loc project
      else
        (* Old behavior: if old parser succeeds, return that. Otherwise, if
           parsing the ordered set language succeeds, ask the user to upgrade to
           a supported version *)
        try_ Mode_conf.Lib.Set.decode (fun _exn ->
          let+ _modes = Mode_conf.Lib.Set.decode_osl ~stanza_loc project in
          Syntax.Error.since
            stanza_loc
            Stanza.syntax
            expected_version
            ~what:"Ordered set language for modes")
    ;;
  end

  type visibility =
    | Public of Public_lib.t
    | Private of Package.t option

  type t =
    { name : Loc.t * Lib_name.Local.t
    ; visibility : visibility
    ; synopsis : string option
    ; install_c_headers : (Loc.t * string) list
    ; public_headers : Loc.t * Dep_conf.t list
    ; ppx_runtime_libraries : (Loc.t * Lib_name.t) list
    ; modes : Mode_conf.Lib.Set.t
    ; kind : Lib_kind.t
    ; library_flags : Ordered_set_lang.Unexpanded.t
    ; c_library_flags : Ordered_set_lang.Unexpanded.t
    ; virtual_deps : (Loc.t * Lib_name.t) list
    ; wrapped : Wrapped.t Lib_info.Inherited.t
    ; optional : bool
    ; buildable : Buildable.t
    ; dynlink : Dynlink_supported.t
    ; project : Dune_project.t
    ; sub_systems : Sub_system_info.t Sub_system_name.Map.t
    ; dune_version : Dune_lang.Syntax.Version.t
    ; virtual_modules : Ordered_set_lang.t option
    ; implements : (Loc.t * Lib_name.t) option
    ; default_implementation : (Loc.t * Lib_name.t) option
    ; private_modules : Ordered_set_lang.t option
    ; stdlib : Ocaml_stdlib.t option
    ; special_builtin_support : (Loc.t * Lib_info.Special_builtin_support.t) option
    ; enabled_if : Blang.t
    ; instrumentation_backend : (Loc.t * Lib_name.t) option
    ; melange_runtime_deps : Loc.t * Dep_conf.t list
    }

  let no_keep_locs =
    Warning.make ~default:(fun _ -> `Enabled) ~name:"no_keep_locs" ~since:(3, 11)
  ;;

  let decode =
    fields
      (let* stanza_loc = loc in
       let* wrapped = Wrapped.field in
       let* dune_version = Dune_lang.Syntax.get_exn Stanza.syntax in
       let* project = Dune_project.get_exn () in
       let+ buildable = Buildable.decode (Library (Option.map ~f:snd wrapped))
       and+ name = field_o "name" Lib_name.Local.decode_loc
       and+ public =
         field_o "public_name" (Public_lib.decode ~allow_deprecated_names:false)
       and+ synopsis = field_o "synopsis" string
       and+ install_c_headers =
         field "install_c_headers" (repeat (located string)) ~default:[]
       and+ public_headers =
         field
           "public_headers"
           (Dune_lang.Syntax.since Stanza.syntax (3, 8)
            >>> located (repeat Dep_conf.decode_no_files))
           ~default:(stanza_loc, [])
       and+ ppx_runtime_libraries =
         field "ppx_runtime_libraries" (repeat (located Lib_name.decode)) ~default:[]
       and+ library_flags = Ordered_set_lang.Unexpanded.field "library_flags"
       and+ c_library_flags = Ordered_set_lang.Unexpanded.field "c_library_flags"
       and+ virtual_deps =
         field "virtual_deps" (repeat (located Lib_name.decode)) ~default:[]
       and+ modes =
         field
           "modes"
           (Modes.decode ~stanza_loc ~dune_version project)
           ~default:(Mode_conf.Lib.Set.default stanza_loc)
       and+ kind = field "kind" Lib_kind.decode ~default:Lib_kind.Normal
       and+ optional = field_b "optional"
       and+ no_dynlink = field_b "no_dynlink"
       and+ () =
         let check =
           let* loc = loc in
           Warning_emit.Bag.decode no_keep_locs (fun () ->
             let is_error = dune_version >= (2, 0) in
             let message =
               User_message.make
                 ~loc
                 [ Pp.text "no_keep_locs is a no-op. Please delete it." ]
             in
             if is_error then raise (User_error.E message) else Memo.return message)
         in
         let+ _ = field_b "no_keep_locs" ~check in
         ()
       and+ sub_systems = Sub_system_info.record_parser
       and+ virtual_modules =
         field_o
           "virtual_modules"
           (Dune_lang.Syntax.since Stanza.syntax (1, 7) >>> Ordered_set_lang.decode)
       and+ implements =
         field_o
           "implements"
           (Dune_lang.Syntax.since Stanza.syntax (1, 7) >>> located Lib_name.decode)
       and+ default_implementation =
         field_o
           "default_implementation"
           (Dune_lang.Syntax.since Stanza.syntax (2, 6) >>> located Lib_name.decode)
       and+ private_modules =
         field_o
           "private_modules"
           (Dune_lang.Syntax.since Stanza.syntax (1, 2) >>> Ordered_set_lang.decode)
       and+ stdlib =
         field_o
           "stdlib"
           (Dune_lang.Syntax.since Ocaml_stdlib.syntax (0, 1) >>> Ocaml_stdlib.decode)
       and+ special_builtin_support =
         field_o
           "special_builtin_support"
           (Dune_lang.Syntax.since Stanza.syntax (1, 10)
            >>> located Lib_info.Special_builtin_support.decode)
       and+ enabled_if =
         let open Enabled_if in
         let allowed_vars =
           Only
             (("context_name", (2, 8))
              :: ("profile", (2, 5))
              :: Lib_config.allowed_in_enabled_if)
         in
         decode ~allowed_vars ~since:(Some (1, 10)) ()
       and+ instrumentation_backend =
         field_o
           "instrumentation.backend"
           (Dune_lang.Syntax.since Stanza.syntax (2, 7)
            >>> fields (field "ppx" (located Lib_name.decode)))
       and+ package =
         field_o
           "package"
           (Dune_lang.Syntax.since Stanza.syntax (2, 8)
            >>> located Stanza_common.Pkg.decode)
       and+ melange_runtime_deps =
         field
           "melange.runtime_deps"
           (Dune_lang.Syntax.since Melange_stanzas.syntax (0, 1)
            >>> located (repeat Dep_conf.decode))
           ~default:(stanza_loc, [])
       in
       let wrapped = Wrapped.make ~wrapped ~implements ~special_builtin_support in
       let name =
         let open Dune_lang.Syntax.Version.Infix in
         match name, public with
         | Some (loc, res), _ -> loc, res
         | None, Some { name = loc, name; _ } ->
           if dune_version >= (1, 1)
           then (
             match Lib_name.to_local (loc, name) with
             | Ok m -> loc, m
             | Error user_message ->
               User_error.raise
                 ~loc
                 [ Pp.textf "Invalid library name."
                 ; Pp.text
                     "Public library names don't have this restriction. You can either \
                      change this public name to be a valid library name or add a \
                      \"name\" field with a valid library name."
                 ]
                 ~hints:(Lib_name.Local.valid_format_doc :: user_message.hints))
           else
             User_error.raise
               ~loc
               [ Pp.text
                   "name field cannot be omitted before version 1.1 of the dune language"
               ]
         | None, None ->
           User_error.raise
             ~loc:stanza_loc
             [ Pp.text
                 (if dune_version >= (1, 1)
                  then "supply at least one of name or public_name fields"
                  else "name field is missing")
             ]
       in
       let visibility =
         match public, package with
         | None, None -> Private None
         | Some public, None -> Public public
         | None, Some (_loc, package) -> Private (Some package)
         | Some public, Some (loc, _) ->
           User_error.raise
             ~loc
             [ Pp.textf
                 "This library has a public_name, it already belongs to the package %s"
                 (Package.Name.to_string (Package.name public.package))
             ]
       in
       Option.both virtual_modules implements
       |> Option.iter ~f:(fun (virtual_modules, (_, impl)) ->
         User_error.raise
           ~loc:(Ordered_set_lang.loc virtual_modules |> Option.value_exn)
           [ Pp.textf
               "A library cannot be both virtual and implement %s"
               (Lib_name.to_string impl)
           ]);
       (match virtual_modules, default_implementation with
        | None, Some (loc, _) ->
          User_error.raise
            ~loc
            [ Pp.text "Only virtual libraries can specify a default implementation." ]
        | _ -> ());
       { name
       ; visibility
       ; synopsis
       ; install_c_headers
       ; public_headers
       ; ppx_runtime_libraries
       ; modes
       ; kind
       ; library_flags
       ; c_library_flags
       ; virtual_deps
       ; wrapped
       ; optional
       ; buildable
       ; dynlink = Dynlink_supported.of_bool (not no_dynlink)
       ; project
       ; sub_systems
       ; dune_version
       ; virtual_modules
       ; implements
       ; default_implementation
       ; private_modules
       ; stdlib
       ; special_builtin_support
       ; enabled_if
       ; instrumentation_backend
       ; melange_runtime_deps
       })
  ;;

  let package t =
    match t.visibility with
    | Public p -> Some p.package
    | Private p -> p
  ;;

  let sub_dir t =
    match t.visibility with
    | Public p -> p.sub_dir
    | Private None -> None
    | Private (Some _) ->
      Lib_name.Local.mangled_path_under_package (snd t.name)
      |> String.concat ~sep:"/"
      |> Option.some
  ;;

  let has_foreign t = Buildable.has_foreign t.buildable
  let has_foreign_cxx t = Buildable.has_foreign_cxx t.buildable

  let stubs_archive t =
    if Buildable.has_foreign_stubs t.buildable
    then Some (Foreign.Archive.stubs (Lib_name.Local.to_string (snd t.name)))
    else None
  ;;

  let foreign_archives t = List.map ~f:snd t.buildable.foreign_archives

  (* This function returns archives files for a given library and mode:
     - For "all" modes it returns:
     - the foreign archives (which are always not mode-dependent)
     - the lib's stubs archive if they are not mode-dependent
     - For a specific mode "m" it returns:
     - the lib's stubs archive for that mode if they are mode-dependent
  *)
  let foreign_lib_files t ~dir ~ext_lib ~for_mode =
    let stubs_archive = stubs_archive t in
    let foreign_archives = foreign_archives t in
    let stubs_are_mode_dependent =
      Buildable.has_mode_dependent_foreign_stubs t.buildable
    in
    let lib_file ~for_mode archive =
      Foreign.Archive.lib_file ~archive ~dir ~ext_lib ~mode:for_mode
    in
    let stubs_archive =
      Option.bind stubs_archive ~f:(fun archive ->
        match stubs_are_mode_dependent, for_mode with
        | false, Mode.Select.All | true, Only _ -> Some (lib_file ~for_mode archive)
        | _ -> None)
    in
    if for_mode = Mode.Select.All
    then (
      let foreign_archives =
        (* Stubs, and thus the lib archives can have mode-dependent versions, but
           right now foreign archives cannot *)
        List.map foreign_archives ~f:(lib_file ~for_mode)
      in
      Option.to_list stubs_archive @ foreign_archives)
    else Option.to_list stubs_archive
  ;;

  let foreign_dll_files t ~dir ~ext_dll =
    let stubs_archive = stubs_archive t in
    let foreign_archives = foreign_archives t in
    let mode =
      if Buildable.has_mode_dependent_foreign_stubs t.buildable
      then
        (* Shared object are never created in Native mode where everything is
           linked statically. *)
        Mode.Select.Only Mode.Byte
      else Mode.Select.All
    in
    let dll_file ~mode archive = Foreign.Archive.dll_file ~archive ~dir ~ext_dll ~mode in
    let foreign_archives =
      List.map foreign_archives ~f:(dll_file ~mode:Mode.Select.All)
    in
    (* Stubs can have mode-dependent versions, not foreign archives *)
    match stubs_archive with
    | Some stubs_archive -> dll_file ~mode stubs_archive :: foreign_archives
    | None -> foreign_archives
  ;;

  let archive_basename t ~ext = Lib_name.Local.to_string (snd t.name) ^ ext
  let archive t ~dir ~ext = Path.Build.relative dir (archive_basename t ~ext)

  let best_name t =
    match t.visibility with
    | Private _ -> Lib_name.of_local t.name
    | Public p -> snd p.name
  ;;

  let is_virtual t = Option.is_some t.virtual_modules
  let is_impl t = Option.is_some t.implements

  let obj_dir ~dir t =
    let private_lib =
      match t.visibility with
      | Private (Some _) -> true
      | Private None | Public _ -> false
    in
    Obj_dir.make_lib
      ~dir
      ~has_private_modules:
        ((* TODO instead of this fragile approximation, we should be looking at
            [Modules.t] and deciding. Unfortunately, [Obj_dir.t] is currently
            used in some places where [Modules.t] is not yet constructed. *)
         t.private_modules <> None
         || t.buildable.modules.root_module <> None)
      ~private_lib
      (snd t.name)
  ;;

  let main_module_name t : Lib_info.Main_module_name.t =
    match t.implements, t.wrapped with
    | Some x, From _ -> From x
    | Some _, This _ (* cannot specify for wrapped for implements *) | None, From _ ->
      assert false (* cannot inherit for normal libs *)
    | None, This (Simple false) ->
      (match t.stdlib with
       | None -> This None
       | Some _ -> This (Some (Module_name.of_local_lib_name t.name)))
    | None, This (Simple true | Yes_with_transition _) ->
      This (Some (Module_name.of_local_lib_name t.name))
  ;;

  let to_lib_info
    conf
    ~dir
    ~lib_config:
      ({ Lib_config.has_native; ext_lib; ext_dll; natdynlink_supported; _ } as lib_config)
    =
    let open Memo.O in
    let obj_dir = obj_dir ~dir conf in
    let archive ?(dir = dir) ext = archive conf ~dir ~ext in
    let modes = Mode_conf.Lib.Set.eval ~has_native conf.modes in
    let archive_for_mode ~f_ext ~mode =
      if Mode.Dict.get modes.ocaml mode then Some (archive (f_ext mode)) else None
    in
    let archives_for_mode ~f_ext =
      Mode.Dict.of_func (fun ~mode -> archive_for_mode ~f_ext ~mode |> Option.to_list)
    in
    let jsoo_runtime =
      List.map conf.buildable.js_of_ocaml.javascript_files ~f:(Path.Build.relative dir)
    in
    let status =
      match conf.visibility with
      | Private pkg -> Lib_info.Status.Private (conf.project, pkg)
      | Public p -> Public (conf.project, p.package)
    in
    let virtual_library = is_virtual conf in
    let foreign_archives =
      let init =
        Mode.Map.Multi.create_for_all_modes
        @@ foreign_lib_files conf ~dir ~ext_lib ~for_mode:All
      in
      Mode.Dict.foldi modes.ocaml ~init ~f:(fun mode enabled acc ->
        if enabled
        then (
          let for_mode = Mode.Select.Only mode in
          let libs = foreign_lib_files conf ~dir ~ext_lib ~for_mode in
          Mode.Map.Multi.add_all acc for_mode libs)
        else acc)
    in
    let native_archives =
      let archive = archive ext_lib in
      if virtual_library || not modes.ocaml.native
      then Lib_info.Files []
      else if Option.is_some conf.implements
              || (Lib_config.linker_can_create_empty_archives lib_config
                  && Ocaml.Version.ocamlopt_always_calls_library_linker
                       lib_config.ocaml_version)
      then Lib_info.Files [ archive ]
      else Lib_info.Needs_module_info archive
    in
    let foreign_dll_files = foreign_dll_files conf ~dir ~ext_dll in
    let exit_module = Option.bind conf.stdlib ~f:(fun x -> x.exit_module) in
    let virtual_ = Option.map conf.virtual_modules ~f:(fun _ -> Lib_info.Source.Local) in
    let foreign_objects = Lib_info.Source.Local in
    let archives, plugins =
      if virtual_library
      then Mode.Dict.make_both [], Mode.Dict.make_both []
      else (
        let plugins =
          let archive_file ~mode =
            archive_for_mode ~f_ext:Mode.plugin_ext ~mode |> Option.to_list
          in
          { Mode.Dict.native =
              (if Dynlink_supported.get conf.dynlink natdynlink_supported
               then archive_file ~mode:Native
               else [])
          ; byte = archive_file ~mode:Byte
          }
        in
        archives_for_mode ~f_ext:Mode.compiled_lib_ext, plugins)
    in
    let main_module_name = main_module_name conf in
    let name = best_name conf in
    let+ enabled =
      let+ enabled_if_result =
        Blang_expand.eval conf.enabled_if ~dir:(Path.build dir) ~f:(fun ~source:_ pform ->
          let+ value =
            match pform with
            | Var Context_name ->
              let context, _ = Path.Build.extract_build_context_exn dir in
              Memo.return context
            | Var Profile ->
              let context, _ = Path.Build.extract_build_context_exn dir in
              let+ profile = Per_context.profile (Context_name.of_string context) in
              Profile.to_string profile
            | _ -> Memo.return @@ Lib_config.get_for_enabled_if lib_config pform
          in
          [ Value.String value ])
      in
      if not enabled_if_result
      then Lib_info.Enabled_status.Disabled_because_of_enabled_if
      else if conf.optional
      then Optional
      else Normal
    in
    let version =
      match status with
      | Public (_, pkg) -> Package.version pkg
      | Installed_private | Installed | Private _ -> None
    in
    let requires = conf.buildable.libraries in
    let loc = conf.buildable.loc in
    let kind = conf.kind in
    let src_dir = dir in
    let orig_src_dir = None in
    let synopsis = conf.synopsis in
    let sub_systems = conf.sub_systems in
    let ppx_runtime_deps = conf.ppx_runtime_libraries in
    let preprocess = conf.buildable.preprocess in
    let virtual_deps = conf.virtual_deps in
    let dune_version = Some conf.dune_version in
    let implements = conf.implements in
    let default_implementation = conf.default_implementation in
    let wrapped = Some conf.wrapped in
    let special_builtin_support = conf.special_builtin_support in
    let instrumentation_backend = conf.instrumentation_backend in
    let entry_modules = Lib_info.Source.Local in
    let melange_runtime_deps =
      let loc, runtime_deps = conf.melange_runtime_deps in
      Lib_info.File_deps.Local (loc, runtime_deps)
    in
    let public_headers =
      let loc, public_headers = conf.public_headers in
      Lib_info.File_deps.Local (loc, public_headers)
    in
    Lib_info.create
      ~loc
      ~path_kind:Local
      ~name
      ~kind
      ~status
      ~src_dir
      ~orig_src_dir
      ~obj_dir
      ~version
      ~synopsis
      ~main_module_name
      ~sub_systems
      ~requires
      ~foreign_objects
      ~public_headers
      ~plugins
      ~archives
      ~ppx_runtime_deps
      ~foreign_archives
      ~native_archives
      ~foreign_dll_files
      ~jsoo_runtime
      ~preprocess
      ~enabled
      ~virtual_deps
      ~dune_version
      ~virtual_
      ~entry_modules
      ~implements
      ~default_implementation
      ~modes
      ~modules:Local
      ~wrapped
      ~special_builtin_support
      ~exit_module
      ~instrumentation_backend
      ~melange_runtime_deps
  ;;

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)
end

module Executables = struct
  module Names : sig
    type t

    val names : t -> (Loc.t * string) list
    val package : t -> Package.t option
    val has_public_name : t -> bool

    val make
      :  multi:bool
      -> allow_omit_names_version:Dune_lang.Syntax.Version.t
      -> (t, fields) Dune_lang.Decoder.parser

    val install_conf
      :  t
      -> ext:Filename.Extension.t
      -> enabled_if:Blang.t
      -> dir:Path.Source.t
      -> Install_conf.t option
  end = struct
    type public =
      { public_names : (Loc.t * string option) list
      ; package : Package.t
      }

    type t =
      { names : (Loc.t * string) list
      ; public : public option
      ; dune_syntax : Syntax.Version.t
      }

    let names t = t.names
    let package t = Option.map t.public ~f:(fun p -> p.package)
    let has_public_name t = Option.is_some t.public

    let public_name ~dash_is_none =
      let+ loc, s = located string in
      ( loc
      , match s with
        | "-" -> if dash_is_none then None else Some s
        | s -> Some s )
    ;;

    let multi_fields =
      map_validate
        (let+ names = field_o "names" (repeat1 (located string))
         and+ pub_names =
           field_o "public_names" (repeat1 (public_name ~dash_is_none:true))
         in
         names, pub_names)
        ~f:(fun (names, public_names) ->
          match names, public_names with
          | Some names, Some public_names ->
            if List.length public_names = List.length names
            then Ok (Some names, Some public_names)
            else
              Error
                (User_error.make
                   [ Pp.text
                       "The list of public names must be of the same length as the list \
                        of names"
                   ])
          | names, public_names -> Ok (names, public_names))
    ;;

    let single_fields =
      let* dune_syntax = Dune_lang.Syntax.get_exn Stanza.syntax in
      let dash_is_none = dune_syntax >= (3, 8) in
      let+ name = field_o "name" (located string)
      and+ public_name = field_o "public_name" (public_name ~dash_is_none) in
      Option.map name ~f:List.singleton, Option.map public_name ~f:List.singleton
    ;;

    let pluralize s ~multi = if multi then s ^ "s" else s

    let make ~multi ~allow_omit_names_version =
      let check_valid_name_version = 3, 0 in
      let+ names = if multi then multi_fields else single_fields
      and+ loc = loc
      and+ dune_syntax = Dune_lang.Syntax.get_exn Stanza.syntax
      and+ package =
        field_o
          "package"
          (let+ loc = loc
           and+ pkg = Stanza_common.Pkg.decode in
           loc, pkg)
      and+ project = Dune_project.get_exn () in
      let names, public_names = names in
      let names =
        let open Dune_lang.Syntax.Version.Infix in
        if dune_syntax >= check_valid_name_version
        then
          Option.iter
            names
            ~f:
              (List.iter ~f:(fun name ->
                 ignore (Module_name.parse_string_exn name : Module_name.t)));
        match names, public_names with
        | Some names, _ -> names
        | None, Some public_names ->
          if dune_syntax >= allow_omit_names_version
          then (
            let check_names = dune_syntax >= check_valid_name_version in
            List.map public_names ~f:(fun (loc, p) ->
              match p, check_names with
              | None, _ ->
                User_error.raise ~loc [ Pp.text "This executable must have a name field" ]
              | Some s, false -> loc, s
              | Some s, true ->
                (match Module_name.of_string_user_error (loc, s) with
                 | Ok _ -> loc, s
                 | Error user_message ->
                   User_error.raise
                     ~loc
                     [ Pp.textf "Invalid module name."
                     ; Pp.text
                         "Public executable names don't have this restriction. You can \
                          either change this public name to be a valid module name or \
                          add a \"name\" field with a valid module name."
                     ]
                     ~hints:(Module_name.valid_format_doc :: user_message.hints))))
          else
            User_error.raise
              ~loc
              [ Pp.textf
                  "%s field may not be omitted before dune version %s"
                  (pluralize ~multi "name")
                  (Dune_lang.Syntax.Version.to_string allow_omit_names_version)
              ]
        | None, None ->
          if dune_syntax >= allow_omit_names_version
          then
            User_error.raise
              ~loc
              [ Pp.textf
                  "either the %s or the %s field must be present"
                  (pluralize ~multi "name")
                  (pluralize ~multi "public_name")
              ]
          else
            User_error.raise
              ~loc
              [ Pp.textf "field %s is missing" (pluralize ~multi "name") ]
      in
      let public =
        match package, public_names with
        | None, None -> None
        | Some (_loc, package), Some public_names -> Some { package; public_names }
        | None, Some public_names ->
          if List.for_all public_names ~f:(fun (_, x) -> Option.is_none x)
          then None
          else
            Some
              { public_names
              ; package =
                  Stanza_common.Pkg.default_exn
                    ~loc
                    project
                    (pluralize "executable" ~multi)
              }
        | Some (loc, _), None ->
          User_error.raise
            ~loc
            [ Pp.textf
                "This field is useless without a (%s ...) field."
                (pluralize "public_name" ~multi)
            ]
      in
      { names; public; dune_syntax }
    ;;

    let install_conf t ~ext ~enabled_if ~dir =
      Option.map t.public ~f:(fun { package; public_names } ->
        let files =
          List.map2 t.names public_names ~f:(fun (locn, name) (locp, pub) ->
            Option.map pub ~f:(fun pub ->
              Install_entry.File.of_file_binding
                (File_binding.Unexpanded.make
                   ~src:(locn, name ^ ext)
                   ~dst:(locp, pub)
                   ~dune_syntax:t.dune_syntax
                   ~dir:(Some dir))))
          |> List.filter_opt
        in
        { Install_conf.section = Section Bin
        ; files
        ; dirs = []
        ; package
        ; enabled_if
        ; source_trees = []
        })
    ;;
  end

  module Link_mode = struct
    module T = struct
      type t =
        | Byte_complete
        | Other of
            { mode : Mode_conf.t
            ; kind : Binary_kind.t
            }

      let compare a b =
        match a, b with
        | Byte_complete, Byte_complete -> Eq
        | Byte_complete, _ -> Lt
        | _, Byte_complete -> Gt
        | Other { mode; kind }, Other t ->
          let open Ordering.O in
          let= () = Mode_conf.compare mode t.mode in
          Binary_kind.compare kind t.kind
      ;;

      let to_dyn = Dyn.opaque
    end

    include T

    let make mode kind = Other { mode; kind }
    let exe = make Best Exe
    let object_ = make Best Object
    let shared_object = make Best Shared_object
    let byte = make Byte Exe
    let native = make Native Exe
    let js = make Byte Js
    let plugin = make Best Plugin

    let simple_representations =
      [ "exe", exe
      ; "object", object_
      ; "shared_object", shared_object
      ; "byte", byte
      ; "native", native
      ; "js", js
      ; "byte_complete", Byte_complete
      ; "plugin", plugin
      ]
    ;;

    let simple = Dune_lang.Decoder.enum simple_representations

    let decode =
      enter
        (let+ mode = Mode_conf.decode
         and+ kind = Binary_kind.decode in
         make mode kind)
      <|> simple
    ;;

    let simple_encode link_mode =
      let is_ok (_, candidate) = compare candidate link_mode = Eq in
      List.find ~f:is_ok simple_representations
      |> Option.map ~f:(fun (s, _) -> Dune_lang.atom s)
    ;;

    let encode link_mode =
      match simple_encode link_mode with
      | Some s -> s
      | None ->
        (match link_mode with
         | Byte_complete -> assert false
         | Other { mode; kind } ->
           Dune_lang.Encoder.pair Mode_conf.encode Binary_kind.encode (mode, kind))
    ;;

    let to_dyn t =
      match t with
      | Byte_complete -> Dyn.Variant ("Byte_complete", [])
      | Other { mode; kind } ->
        let open Dyn in
        Variant
          ( "Other"
          , [ record [ "mode", Mode_conf.to_dyn mode; "kind", Binary_kind.to_dyn kind ] ]
          )
    ;;

    let extension t ~loc ~ext_obj ~ext_dll =
      match t with
      | Byte_complete -> ".bc.exe"
      | Other { mode; kind } ->
        let same_as_mode : Mode.t =
          match mode with
          | Byte -> Byte
          | Native | Best ->
            (* From the point of view of the extension, [native] and [best] are
               the same *)
            Native
        in
        (match same_as_mode, kind with
         | Byte, C -> ".bc.c"
         | Native, C ->
           User_error.raise ~loc [ Pp.text "C file generation only supports bytecode!" ]
         | Byte, Exe -> ".bc"
         | Native, Exe -> ".exe"
         | Byte, Object -> ".bc" ^ ext_obj
         | Native, Object -> ".exe" ^ ext_obj
         | Byte, Shared_object -> ".bc" ^ ext_dll
         | Native, Shared_object -> ext_dll
         | mode, Plugin -> Mode.plugin_ext mode
         | Byte, Js -> Js_of_ocaml.Ext.exe
         | Native, Js ->
           User_error.raise
             ~loc
             [ Pp.text "Javascript generation only supports bytecode!" ])
    ;;

    module O = Comparable.Make (T)

    let installable_modes =
      [ (0, 0), exe; (0, 0), native; (0, 0), byte; (3, 6), Byte_complete ]
    ;;

    module Map = struct
      include O.Map

      let decode =
        let+ loc, l = located (repeat (located decode)) in
        match l with
        | [] -> User_error.raise ~loc [ Pp.textf "No linking mode defined" ]
        | l ->
          let t =
            List.fold_left l ~init:empty ~f:(fun acc (loc, link_mode) ->
              set acc link_mode loc)
          in
          (match
             String.Map.of_list_map (to_list t) ~f:(fun (lm, loc) ->
               extension lm ~loc ~ext_obj:".OBJ" ~ext_dll:".DLL", lm)
           with
           | Ok _ -> ()
           | Error (_ext, (lm1, _), (lm2, _)) ->
             User_error.raise
               ~loc
               [ Pp.textf
                   "It is not allowed use both %s and %s together as they use the same \
                    file extension."
                   (Dune_lang.to_string (encode lm1))
                   (Dune_lang.to_string (encode lm2))
               ]);
          t
      ;;

      let byte_and_exe = of_list_exn [ byte, Loc.none; exe, Loc.none ]

      let default_for_exes ~version =
        if version < (2, 0) then byte_and_exe else singleton exe Loc.none
      ;;

      let default_for_tests ~version =
        if version < (3, 0) then byte_and_exe else singleton exe Loc.none
      ;;

      let best_install_mode t ~(dune_version : Syntax.Version.t) =
        let rec loop acc = function
          | [] -> acc
          | (since, mode) :: rest ->
            (match mem t mode with
             | false -> loop acc rest
             | true ->
               if dune_version < since
               then loop (Some (`Unavailable_until (since, mode))) rest
               else Some (`Found mode))
        in
        match loop None installable_modes with
        | None -> None
        | Some (`Found f) -> Some f
        | Some (`Unavailable_until (since, mode)) ->
          let what =
            List.find_map simple_representations ~f:(fun (rep, mode') ->
              Option.some_if (Ordering.is_eq (T.compare mode mode')) rep)
            |> Option.value_exn
          in
          let loc = find_exn t mode in
          Syntax.Error.since loc Stanza.syntax since ~what
      ;;
    end
  end

  type t =
    { names : (Loc.t * string) list
    ; link_flags : Link_flags.Spec.t
    ; link_deps : Dep_conf.t list
    ; modes : Loc.t Link_mode.Map.t
    ; optional : bool
    ; buildable : Buildable.t
    ; package : Package.t option
    ; promote : Rule.Promote.t option
    ; install_conf : Install_conf.t option
    ; embed_in_plugin_libraries : (Loc.t * Lib_name.t) list
    ; forbidden_libraries : (Loc.t * Lib_name.t) list
    ; bootstrap_info : string option
    ; enabled_if : Blang.t
    ; dune_version : Dune_lang.Syntax.Version.t
    }

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)

  let bootstrap_info_extension =
    let syntax =
      Dune_lang.Syntax.create
        ~name:"dune-bootstrap-info"
        ~desc:"private extension to handle Dune bootstrap"
        [ (0, 1), `Since (2, 0) ]
    in
    Dune_project.Extension.register syntax (return ((), [])) Dyn.unit
  ;;

  let common =
    let* dune_version = Dune_lang.Syntax.get_exn Stanza.syntax in
    let+ buildable = Buildable.decode Executable
    and+ (_ : bool) =
      field
        "link_executables"
        ~default:true
        (Dune_lang.Syntax.deleted_in Stanza.syntax (1, 0) >>> bool)
    and+ link_deps = field "link_deps" (repeat Dep_conf.decode) ~default:[]
    and+ link_flags = Link_flags.Spec.decode ~check:None
    and+ modes =
      field
        "modes"
        Link_mode.Map.decode
        ~default:(Link_mode.Map.default_for_exes ~version:dune_version)
    and+ optional =
      field_b "optional" ~check:(Dune_lang.Syntax.since Stanza.syntax (2, 0))
    and+ promote =
      field_o
        "promote"
        (Dune_lang.Syntax.since Stanza.syntax (1, 11) >>> Rule_mode_decoder.Promote.decode)
    and+ () =
      map_validate
        (field "inline_tests" (repeat junk >>| fun _ -> true) ~default:false)
        ~f:(function
          | false -> Ok ()
          | true ->
            Error
              (User_error.make
                 [ Pp.text "Inline tests are only allowed in libraries."
                 ; Pp.text
                     "See https://github.com/ocaml/dune/issues/745 for more details."
                 ]))
    and+ embed_in_plugin_libraries =
      field_o
        "embed_in_plugin_libraries"
        (Dune_lang.Syntax.since Stanza.syntax (2, 4)
         >>> located (repeat (located Lib_name.decode)))
    and+ forbidden_libraries =
      field
        "forbidden_libraries"
        (Dune_lang.Syntax.since Stanza.syntax (2, 0) >>> repeat (located Lib_name.decode))
        ~default:[]
    and+ bootstrap_info =
      field_o
        "bootstrap_info"
        (let+ loc = loc
         and+ fname = filename
         and+ project = Dune_project.get_exn () in
         if not (Dune_project.is_extension_set project bootstrap_info_extension)
         then User_error.raise ~loc [ Pp.text "This field is reserved for Dune itself" ];
         fname)
    and+ project_root = Dune_project.get_exn () >>| Dune_project.root
    and+ enabled_if =
      let allowed_vars = Enabled_if.common_vars ~since:(2, 3) in
      let is_error = Dune_lang.Syntax.Version.Infix.(dune_version >= (2, 6)) in
      Enabled_if.decode ~allowed_vars ~is_error ~since:(Some (2, 3)) ()
    in
    fun names ~multi ->
      let has_public_name = Names.has_public_name names in
      let private_names = Names.names names in
      let install_conf =
        match Link_mode.Map.best_install_mode ~dune_version modes with
        | None when has_public_name ->
          User_error.raise
            ~loc:buildable.loc
            [ Pp.textf
                "No installable mode found for %s."
                (if multi then "these executables" else "this executable")
            ; Pp.text "When public_name is set, one of the following modes is required:"
            ; Pp.enumerate
                (List.filter_map Link_mode.installable_modes ~f:(fun (since, mode) ->
                   Option.some_if (dune_version >= since) mode))
                ~f:(fun mode -> Pp.verbatim (Dune_lang.to_string (Link_mode.encode mode)))
            ]
        | None -> None
        | Some mode ->
          let ext =
            match mode with
            | Byte_complete -> ".bc.exe"
            | Other { mode = Byte; _ } -> ".bc"
            | Other { mode = Native | Best; _ } -> ".exe"
          in
          Names.install_conf names ~ext ~enabled_if ~dir:project_root
      in
      let embed_in_plugin_libraries =
        let plugin =
          Link_mode.Map.existsi modes ~f:(fun mode _ ->
            match mode with
            | Link_mode.Other { kind = Plugin; _ } -> true
            | _ -> false)
        in
        match embed_in_plugin_libraries, plugin with
        | None, _ -> []
        | Some (_, l), true -> l
        | Some (loc, _), false ->
          User_error.raise
            ~loc
            [ Pp.textf "This field can only be used when linking a plugin." ]
      in
      { names = private_names
      ; link_flags
      ; link_deps
      ; modes
      ; optional
      ; buildable
      ; package = Names.package names
      ; promote
      ; install_conf
      ; embed_in_plugin_libraries
      ; forbidden_libraries
      ; bootstrap_info
      ; enabled_if
      ; dune_version
      }
  ;;

  let single, multi =
    let make multi =
      fields
        (let+ names = Names.make ~multi ~allow_omit_names_version:(1, 1)
         and+ f = common in
         f names ~multi)
    in
    make false, make true
  ;;

  let has_foreign t = Buildable.has_foreign t.buildable
  let has_foreign_cxx t = Buildable.has_foreign_cxx t.buildable
  let obj_dir t ~dir = Obj_dir.make_exe ~dir ~name:(snd (List.hd t.names))
end

module Tests = struct
  type t =
    { exes : Executables.t
    ; locks : Locks.t
    ; package : Package.t option
    ; deps : Dep_conf.t Bindings.t
    ; enabled_if : Blang.t
    ; build_if : Blang.t
    ; action : Dune_lang.Action.t option
    }

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)

  let gen_parse names =
    fields
      (let* deps =
         field "deps" (Bindings.decode Dep_conf.decode) ~default:Bindings.empty
       in
       String_with_vars.add_user_vars_to_decoding_env
         (Bindings.var_names deps)
         (let* dune_version = Dune_lang.Syntax.get_exn Stanza.syntax in
          let+ buildable = Buildable.decode Executable
          and+ link_flags = Link_flags.Spec.decode ~check:None
          and+ names = names
          and+ package = field_o "package" Stanza_common.Pkg.decode
          and+ locks = Locks.field ()
          and+ modes =
            field
              "modes"
              Executables.Link_mode.Map.decode
              ~default:(Executables.Link_mode.Map.default_for_tests ~version:dune_version)
          and+ enabled_if = Enabled_if.decode ~allowed_vars:Any ~since:(Some (1, 4)) ()
          and+ action =
            field_o
              "action"
              (Dune_lang.Syntax.since ~fatal:false Stanza.syntax (1, 2)
               >>> Dune_lang.Action.decode_dune_file)
          and+ forbidden_libraries =
            field
              "forbidden_libraries"
              (Dune_lang.Syntax.since Stanza.syntax (2, 0)
               >>> repeat (located Lib_name.decode))
              ~default:[]
          and+ build_if =
            field
              "build_if"
              ~default:Blang.true_
              (Syntax.since Stanza.syntax (3, 9)
               >>> Enabled_if.decode_value ~allowed_vars:Any ())
          in
          { exes =
              { Executables.link_flags
              ; link_deps = []
              ; modes
              ; optional = false
              ; buildable
              ; names
              ; package = None
              ; promote = None
              ; install_conf = None
              ; embed_in_plugin_libraries = []
              ; forbidden_libraries
              ; bootstrap_info = None
              ; enabled_if
              ; dune_version
              }
          ; locks
          ; package
          ; deps
          ; enabled_if
          ; build_if
          ; action
          }))
  ;;

  let multi = gen_parse (field "names" (repeat1 (located string)))
  let single = gen_parse (field "name" (located string) >>| List.singleton)
end

module Documentation = struct
  type t =
    { loc : Loc.t
    ; package : Package.t
    ; mld_files : Ordered_set_lang.t
    }

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)

  let decode =
    fields
      (let+ package = Stanza_common.Pkg.field ~stanza:"documentation"
       and+ mld_files = Ordered_set_lang.field "mld_files"
       and+ loc = loc in
       { loc; package; mld_files })
  ;;
end

module Include_subdirs = struct
  type qualification =
    | Unqualified
    | Qualified

  type t =
    | No
    | Include of qualification

  type stanza = Loc.t * t

  include Stanza.Make (struct
      type nonrec t = stanza

      include Poly
    end)

  let decode ~enable_qualified =
    sum
      [ "no", return No
      ; "unqualified", return (Include Unqualified)
      ; ( "qualified"
        , let+ () =
            if enable_qualified then return () else Syntax.since Stanza.syntax (3, 7)
          in
          Include Qualified )
      ]
  ;;
end

module Library_redirect = struct
  type 'old_name t =
    { project : Dune_project.t
    ; loc : Loc.t
    ; old_name : 'old_name
    ; new_public_name : Loc.t * Lib_name.t
    }

  module Local = struct
    type nonrec t = (Loc.t * Lib_name.Local.t) t

    include Stanza.Make (struct
        type nonrec t = t

        include Poly
      end)

    let for_lib (lib : Library.t) ~new_public_name ~loc : t =
      { loc; new_public_name; old_name = lib.name; project = lib.project }
    ;;

    let of_private_lib (lib : Library.t) : t option =
      match lib.visibility with
      | Public _ | Private None -> None
      | Private (Some package) ->
        let loc, name = lib.name in
        let package_name = Package.name package in
        let new_public_name = loc, Lib_name.mangled package_name name in
        Some (for_lib lib ~loc ~new_public_name)
    ;;

    let of_lib (lib : Library.t) : t option =
      let open Option.O in
      let* public_name =
        match lib.visibility with
        | Public plib -> Some plib.name
        | Private _ -> None
      in
      if Lib_name.equal (Lib_name.of_local lib.name) (snd public_name)
      then None
      else (
        let loc = fst public_name in
        Some (for_lib lib ~loc ~new_public_name:public_name))
    ;;
  end
end

module Deprecated_library_name = struct
  module Old_name = struct
    type deprecation =
      | Not_deprecated
      | Deprecated of { deprecated_package : Package.Name.t }

    type t = Public_lib.t * deprecation

    let decode =
      let+ public = Public_lib.decode ~allow_deprecated_names:true in
      let deprecation =
        let deprecated_package = Lib_name.package_name (Public_lib.name public) in
        if let name = Package.name (Public_lib.package public) in
           Package.Name.equal deprecated_package name
        then Not_deprecated
        else Deprecated { deprecated_package }
      in
      public, deprecation
    ;;
  end

  type t = Old_name.t Library_redirect.t

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)

  let old_public_name (t : t) = Public_lib.name (fst t.old_name)

  let decode =
    fields
      (let+ loc = loc
       and+ project = Dune_project.get_exn ()
       and+ old_name = field "old_public_name" Old_name.decode
       and+ new_public_name = field "new_public_name" (located Lib_name.decode) in
       let () =
         let loc, old_name = (fst old_name).name in
         if Lib_name.equal (snd new_public_name) old_name
         then
           User_error.raise
             ~loc
             [ Pp.text "old_public_name cannot be the same as the new_public_name" ]
       in
       { Library_redirect.loc; project; old_name; new_public_name })
  ;;
end

module Include = struct
  type t = Loc.t * string

  include Stanza.Make (struct
      type nonrec t = t

      include Poly
    end)
end

module Stanzas = struct
  type t = Stanza.t list

  let rules l = List.map l ~f:(fun x -> Rule_conf.make_stanza x)
  let execs exe = [ Executables.make_stanza exe ]

  type constructors = Stanza.Parser.t list

  let stanzas : constructors =
    List.concat
      [ Site_stanzas.all
      ; Cram_stanza.stanza
      ; [ ( "library"
          , let+ x = Library.decode in
            let base = [ Library.make_stanza x ] in
            match Library_redirect.Local.of_lib x with
            | None -> base
            | Some r -> Library_redirect.Local.make_stanza r :: base )
        ; ( "foreign_library"
          , let+ () = Dune_lang.Syntax.since Stanza.syntax (2, 0)
            and+ x = Foreign.Library.decode in
            [ Foreign.Library.make_stanza x ] )
        ; "executable", Executables.single >>| execs
        ; "executables", Executables.multi >>| execs
        ; ( "rule"
          , let+ loc = loc
            and+ x = Rule_conf.decode in
            [ Rule_conf.make_stanza { x with loc } ] )
        ; ( "ocamllex"
          , let+ loc = loc
            and+ x = Rule_conf.ocamllex in
            rules (Rule_conf.ocamllex_to_rule loc x) )
        ; ( "ocamlyacc"
          , let+ loc = loc
            and+ x = Rule_conf.ocamlyacc in
            rules (Rule_conf.ocamlyacc_to_rule loc x) )
        ; ( "install"
          , let+ x = Install_conf.decode in
            [ Install_conf.make_stanza x ] )
        ; ( "alias"
          , let+ x = Alias_conf.decode in
            [ Alias_conf.make_stanza x ] )
        ; ( "copy_files"
          , let+ x = Copy_files.decode in
            [ Copy_files.make_stanza x ] )
        ; ( "copy_files#"
          , let+ x = Copy_files.decode in
            [ Copy_files.make_stanza { x with add_line_directive = true } ] )
        ; ( "include"
          , let+ loc = loc
            and+ fn = relative_file in
            [ Include.make_stanza (loc, fn) ] )
        ; ( "documentation"
          , let+ d = Documentation.decode in
            [ Documentation.make_stanza d ] )
        ; ( "jbuild_version"
          , let+ () = Dune_lang.Syntax.deleted_in Stanza.syntax (1, 0)
            and+ _ = Jbuild_version.decode in
            [] )
        ; ( "tests"
          , let+ () = Dune_lang.Syntax.since Stanza.syntax (1, 0)
            and+ t = Tests.multi in
            [ Tests.make_stanza t ] )
        ; ( "test"
          , let+ () = Dune_lang.Syntax.since Stanza.syntax (1, 0)
            and+ t = Tests.single in
            [ Tests.make_stanza t ] )
        ; ( "external_variant"
          , let+ () = Dune_lang.Syntax.deleted_in Stanza.syntax (2, 6) in
            [] )
        ; ( "env"
          , let+ x = Dune_env.decode in
            [ Dune_env.make_stanza x ] )
        ; ( "include_subdirs"
          , let* project = Dune_project.get_exn () in
            let+ () = Dune_lang.Syntax.since Stanza.syntax (1, 1)
            and+ t =
              let enable_qualified =
                Dune_project.is_extension_set project Coq_stanza.key
              in
              Include_subdirs.decode ~enable_qualified
            and+ loc = loc in
            [ Include_subdirs.make_stanza (loc, t) ] )
        ; ( "toplevel"
          , let+ () = Dune_lang.Syntax.since Stanza.syntax (1, 7)
            and+ t = Toplevel_stanza.decode in
            [ Toplevel_stanza.make_stanza t ] )
        ; ( "deprecated_library_name"
          , let+ () = Dune_lang.Syntax.since Stanza.syntax (2, 0)
            and+ t = Deprecated_library_name.decode in
            [ Deprecated_library_name.make_stanza t ] )
        ]
      ]
  ;;

  let () = Dune_project.Lang.register Stanza.syntax stanzas

  let parser project =
    let syntax_parser = Dune_project.stanza_parser project in
    Dune_project.set project syntax_parser
  ;;

  let parse parser = Dune_lang.Decoder.parse parser Univ_map.empty

  let of_ast (project : Dune_project.t) sexp =
    let parser = parser project in
    parse parser sexp
  ;;

  (* XXX this is needed for evaluating includes generated by dune files written
     in OCaml syntax.*)
  let rec parse_file_includes ~stanza_parser ~context sexps =
    List.concat_map sexps ~f:(parse stanza_parser)
    |> Memo.List.concat_map ~f:(fun stanza ->
      match Stanza.repr stanza with
      | Include.T (loc, fn) ->
        let open Memo.O in
        let* sexps, context = Include_stanza.load_sexps ~context (loc, fn) in
        parse_file_includes ~stanza_parser ~context sexps
      | _ -> Memo.return [ stanza ])
  ;;

  let parse ~file ~dir (project : Dune_project.t) sexps =
    let stanza_parser = parser project in
    let warnings = Warning_emit.Bag.create () in
    let stanza_parser = Warning_emit.Bag.set warnings stanza_parser in
    let open Memo.O in
    let* stanzas =
      let context =
        Include_stanza.in_file
        @@
        match file with
        | Some f -> f
        | None ->
          (* TODO this is wrong *)
          Path.Source.relative dir Source_tree.Dune_file.fname
      in
      parse_file_includes ~stanza_parser ~context sexps
    in
    let (_ : bool) =
      List.fold_left stanzas ~init:false ~f:(fun env stanza ->
        match Stanza.repr stanza with
        | Dune_env.T e ->
          if env
          then
            User_error.raise
              ~loc:e.loc
              [ Pp.text "The 'env' stanza cannot appear more than once" ]
          else true
        | _ -> env)
    in
    let+ () = Warning_emit.Bag.emit_all warnings in
    stanzas
  ;;
end

let stanza_package stanza =
  match Stanza.repr stanza with
  | Library.T lib -> Library.package lib
  | Alias_conf.T { package = Some package; _ }
  | Rule_conf.T { package = Some package; _ }
  | Install_conf.T { package; _ }
  | Plugin.T { package; _ }
  | Executables.T { install_conf = Some { package; _ }; _ }
  | Documentation.T { package; _ }
  | Tests.T { package = Some package; _ } -> Some package
  | Coq_stanza.Theory.T { package = Some package; _ } -> Some package
  | _ -> None
;;

type t =
  { dir : Path.Source.t
  ; project : Dune_project.t
  ; stanzas : Stanzas.t
  }

let is_promoted_rule =
  let is_promoted_mode version = function
    | Rule.Mode.Promote { only = None; lifetime; _ } ->
      if version >= (3, 5)
      then (
        match lifetime with
        | Unlimited -> true
        | Until_clean -> false)
      else true
    | _ -> false
  in
  fun version rule ->
    match Stanza.repr rule with
    | Rule_conf.T { mode; _ } | Menhir_stanza.T { mode; _ } ->
      is_promoted_mode version mode
    | _ -> false
;;

let parse sexps ~dir ~file ~project =
  let open Memo.O in
  let+ stanzas = Stanzas.parse ~file ~dir project sexps in
  let stanzas =
    if !Clflags.ignore_promoted_rules
    then (
      let version = Dune_project.dune_version project in
      List.filter stanzas ~f:(fun s -> not (is_promoted_rule version s)))
    else stanzas
  in
  { dir; project; stanzas }
;;

module Make_fold (M : Monad.S) = struct
  open M.O

  let rec fold_stanzas l ~init ~f =
    match l with
    | [] -> M.return init
    | t :: l -> inner_fold t t.stanzas l ~init ~f

  and inner_fold t inner_list l ~init ~f =
    match inner_list with
    | [] -> fold_stanzas l ~init ~f
    | x :: inner_list ->
      let* init = f t x init in
      inner_fold t inner_list l ~init ~f
  ;;
end

module Memo_fold = Make_fold (Memo)
module Id_fold = Make_fold (Monad.Id)

let fold_stanzas t ~init ~f = Id_fold.fold_stanzas t ~init ~f

let equal t { dir; project; stanzas } =
  Path.Source.equal t.dir dir
  && Dune_project.equal t.project project
  && List.equal Stanza.equal t.stanzas stanzas
;;

let hash = Poly.hash
let to_dyn = Dyn.opaque
let of_ast = Stanzas.of_ast
