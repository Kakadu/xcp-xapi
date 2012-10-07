(*
 * Copyright (C) 2006-2009 Citrix Systems Inc.
 *
 * This program is free software; you can redistribute it and/or modify
 * it under the terms of the GNU Lesser General Public License as published
 * by the Free Software Foundation; version 2.1 only. with the special
 * exception on linking described in file LICENSE.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 * GNU Lesser General Public License for more details.
 *)
open Listext

module DT = Datamodel_types
module DU = Datamodel_utils
module OU = Ocaml_utils

module O = Ocaml_syntax

let print s = output_string stdout (s^"\n")

(** Generate a single type declaration (using 'and' rather than 'let' *)
let gen_type highapi = function
  | DT.String | DT.Int | DT.Float | DT.Bool -> []
  | (DT.Record x) as ty ->
      let fields = DU.fields_of_obj (Dm_api.get_obj_by_name highapi ~objname:x) in
      let fields = List.map
	  (fun fld -> OU.ocaml_of_record_field x fld.DT.full_name ^ ":" ^
	    (OU.alias_of_ty fld.DT.ty)) fields in
      let fields = if fields = [] then [ "__unused: unit" ] else fields in
      [ "and " ^ (OU.alias_of_ty ty) ^ " = { " ^
	(String.concat "; " fields) ^ " }" ]
  | ty -> [ "and "^OU.alias_of_ty ty^" = "^OU.ocaml_of_ty ty ]

let gen_client highapi =
  let _ (* unused variable: all_types *) = DU.Types.of_objects (Dm_api.objects_of_api highapi) in
  List.iter (List.iter print)
    (List.between [""]
       [[ "open Xml";
	  "open XMLRPC";
	  "open API";
	  "module type RPC = sig val rpc: xml -> xml end";
	  "";
	  "let server_failure code args = raise (Api_errors.Server_error (code, args))";
	];
	O.Module.strings_of (Gen_client.gen_module highapi);
       ])

let gen_client_types highapi =
	let all_types = DU.Types.of_objects (Dm_api.objects_of_api highapi) in
	List.iter (List.iter print)
		(List.between [""]
			[
				[
					"open Xml";
					"open XMLRPC";
					"open Date";
					"module D = Debug.Debugger(struct let name = \"backtrace\" end)";
					"open D"
				];
				"type __unused = unit " :: (List.concat (List.map (gen_type highapi) all_types));
				GenOCaml.gen_of_xmlrpc highapi all_types;
				GenOCaml.gen_to_xmlrpc highapi all_types;
				O.Signature.strings_of (Gen_client.gen_signature highapi);
			]
		)

let gen_server highapi =
  let _ (* Unused variable: all_types *) = DU.Types.of_objects (Dm_api.objects_of_api highapi) in
  List.iter (List.iter print)
    (List.between [""]
       [[ "open Xml";
	  "open XMLRPC";
	  "open API";
	  "open Server_helpers";
	];
	O.Module.strings_of (Gen_server.gen_module highapi);
       ])

let gen_custom_actions highapi =
    List.iter (List.iter print)
      (List.between [""]
       [
	 [ "open API" ];
	 O.Signature.strings_of (Gen_empty_custom.gen_signature Gen_empty_custom.signature_name None highapi);
(* - make signatures with result type override like this:
	 O.Signature.strings_of (Gen_empty_custom.gen_signature Gen_empty_custom.forwarding_signature_name (Some "Xml.xml option") highapi);
*)
	 O.Module.strings_of (Gen_empty_custom.gen_release_module highapi);
       ]
      )

open Gen_db_actions

let gen_db_actions highapi =
  let all_types = DU.Types.of_objects (Dm_api.objects_of_api highapi) in
  let only_records = List.filter (function DT.Record _ -> true | _ -> false) all_types in

    List.iter (List.iter print)
      (List.between [""]
       [
	 [ "open API" ];

	(* These records have the hidden fields inside *)
	"type __unused = unit " :: (List.concat (List.map (gen_type highapi) only_records));

	 (* NB record types are ignored by dm_to_string and string_to_dm *)
	 O.Module.strings_of (dm_to_string all_types);
	 O.Module.strings_of (string_to_dm all_types);
	O.Module.strings_of (db_action highapi); ]
       @ (List.map O.Module.strings_of (Gen_db_check.all highapi)) @ [

       ]
      )

let gen_rbac highapi =
  print_endline (Gen_rbac.gen_permissions_of_static_roles highapi)
