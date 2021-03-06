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
open Printf

open Stringext
open Hashtblext
open Pervasiveext
open Fun
open Listext

open Device_common
open Xenstore

exception Ioemu_failed of string
exception Ioemu_failed_dying

exception Device_shutdown
exception Device_not_found

exception Cdrom

module D = Debug.Debugger(struct let name = "xenops" end)
open D

(* keys read by vif udev script (keep in sync with api:scripts/vif) *)
let vif_udev_keys = "promiscuous" :: (List.map (fun x -> "ethtool-" ^ x) [ "rx"; "tx"; "sg"; "tso"; "ufo"; "gso" ])

(****************************************************************************************)

module Generic = struct

let vnc_port_path domid = sprintf "/local/domain/%d/console/vnc-port" domid

let tc_port_path domid = sprintf "/local/domain/%d/console/tc-port" domid

(* this transactionally hvm:bool
           -> add entries to add a device
   specified by backend and frontend *)
let add_device ~xs device backend_list frontend_list private_list =

	let frontend_path = frontend_path_of_device ~xs device
	and backend_path = backend_path_of_device ~xs device
	and hotplug_path = Hotplug.get_hotplug_path device
	and private_data_path = Hotplug.get_private_data_path_of_device device in

	debug "adding device  B%d[%s]  F%d[%s]  H[%s]" device.backend.domid backend_path device.frontend.domid frontend_path hotplug_path;
	Xs.transaction xs (fun t ->
		(* Sanity check: ensure the backend domain exists *)
		let _ =
			try
				let (_: string) = t.Xst.read (sprintf "/local/domain/%d/vm" device.backend.domid) in
				()
			with Xenbus.Xb.Noent ->
				raise (Device_backend_vanished device) in

		begin try
			ignore (t.Xst.read frontend_path);
			if Xenbus_utils.of_string (t.Xst.read (frontend_path ^ "/state"))
			   <> Xenbus_utils.Closed then
				raise (Device_frontend_already_connected device)
		with Xenbus.Xb.Noent -> () end;

		t.Xst.rm frontend_path;
		t.Xst.rm backend_path;
		(* CA-16259: don't clear the 'hotplug_path' because this is where we
		   record our own use of /dev/loop devices. Clearing this causes us to leak
		   one per PV .iso *)

		t.Xst.mkdir frontend_path;
		t.Xst.setperms frontend_path (device.frontend.domid, Xsraw.PERM_NONE, [ (device.backend.domid, Xsraw.PERM_READ) ]);

		t.Xst.mkdir backend_path;
		t.Xst.setperms backend_path (device.backend.domid, Xsraw.PERM_NONE, [ (device.frontend.domid, Xsraw.PERM_READ) ]);

		t.Xst.mkdir hotplug_path;
		t.Xst.setperms hotplug_path (device.backend.domid, Xsraw.PERM_NONE, []);

		t.Xst.writev frontend_path
		             (("backend", backend_path) :: frontend_list);
		t.Xst.writev backend_path
		             (("frontend", frontend_path) :: backend_list);

		t.Xst.mkdir private_data_path;
		t.Xst.setperms private_data_path (device.backend.domid, Xsraw.PERM_NONE, []);
		t.Xst.writev private_data_path private_list;
	)

let safe_rm ~xs path =
  try 
    debug "xenstore-rm %s" path;
    xs.Xs.rm path
  with _ -> debug "Failed to xenstore-rm %s; continuing" path 

(* Helper function to delete the frontend, backend and error trees for a device.
   This must only be done after synchronising with the hotplug scripts.
   Cleaning up is best-effort; some of it might fail but as much will be
   done as possible. *)
let rm_device_state ~xs (x: device) =
	debug "Device.rm_device_state %s" (string_of_device x);
	safe_rm ~xs (frontend_path_of_device ~xs x);
	safe_rm ~xs (backend_path_of_device ~xs x);
	(* Cleanup the directory containing the error node *)
	safe_rm ~xs (backend_error_path_of_device ~xs x);
	safe_rm ~xs (Filename.dirname (error_path_of_device ~xs x))

let can_surprise_remove ~xs (x: device) =
  (* "(info key in xenstore) && 2" tells us whether a vbd can be surprised removed *)
        let key = backend_path_of_device ~xs x ^ "/info" in
	try
	  let info = Int64.of_string (xs.Xs.read key) in
	  (Int64.logand info 2L) <> 0L
	with _ -> false

(** Checks whether the supplied device still exists (ie hasn't been deleted) *)
let exists ~xs (x: device) = 
  let backend_stub = backend_path_of_device ~xs x in
  try
    ignore_string(xs.Xs.read backend_stub);
    true
  with Xenbus.Xb.Noent -> false

let assert_exists_t ~xs t (x: device) =
  let backend_stub = backend_path_of_device ~xs x in
  try
    ignore_string(t.Xst.read backend_stub)
  with Xenbus.Xb.Noent -> raise Device_not_found

(** When hot-unplugging a device we ask nicely *)
let request_closure ~xs (x: device) =
	let backend_path = backend_path_of_device ~xs x in
	let state_path = backend_path ^ "/state" in
	Xs.transaction xs (fun t ->
		let online_path = backend_path ^ "/online" in
		debug "xenstore-write %s = 0" online_path;
		t.Xst.write online_path "0";
		let state = try Xenbus_utils.of_string (t.Xst.read state_path) with _ -> Xenbus_utils.Closed in
		if state <> Xenbus_utils.Closed then (
			debug "Device.del_device setting backend to Closing";
			t.Xst.write state_path (Xenbus_utils.string_of Xenbus_utils.Closing);
		)
	)

let unplug_watch ~xs (x: device) =
	let path = Hotplug.path_written_by_hotplug_scripts x in
	Watch.map (fun () -> "") (Watch.key_to_disappear path)
let error_watch ~xs (x: device) = Watch.value_to_appear (error_path_of_device ~xs x)
let frontend_closed ~xs (x: device) = Watch.map (fun () -> "") (Watch.value_to_become (frontend_path_of_device ~xs x ^ "/state") (Xenbus_utils.string_of Xenbus_utils.Closed))

let clean_shutdown ~xs (x: device) =
	debug "Device.Generic.clean_shutdown %s" (string_of_device x);

	let on_error error =
	    debug "Device.Generic.shutdown_common: read an error: %s" error;
	    (* CA-14804: Delete the error node contents *)
	    safe_rm ~xs (error_path_of_device ~xs x);
	    raise (Device_error (x, error)) in

	request_closure ~xs x;
	match Watch.wait_for ~xs (Watch.any_of [
		`Disconnected, frontend_closed ~xs x;
		`Unplugged, unplug_watch ~xs x; 
		`Failed, error_watch ~xs x;
	]) with
		| `Disconnected, _ ->
			debug "Device.Generic.clean_shutdown: frontend changed to state 6";
			safe_rm ~xs (frontend_path_of_device ~xs x);
			begin match Watch.wait_for ~xs (Watch.any_of [
				`Unplugged, unplug_watch ~xs x;
				`Failed, error_watch ~xs x;
			]) with
				| `Unplugged, _ -> rm_device_state ~xs x
				| `Failed, error -> on_error error
			end
		| `Unplugged, _ -> rm_device_state ~xs x
		| `Failed, error -> on_error error

let hard_shutdown_request ~xs (x: device) =
	debug "Device.Generic.hard_shutdown_request %s" (string_of_device x);

	let backend_path = backend_path_of_device ~xs x in
	let online_path = backend_path ^ "/online" in
	debug "xenstore-write %s = 0" online_path;
	xs.Xs.write online_path "0";

	debug "Device.Generic.hard_shutdown about to blow away frontend";
	let frontend_path = frontend_path_of_device ~xs x in
	safe_rm xs frontend_path

let hard_shutdown_complete ~xs (x: device) = unplug_watch ~xs x

let hard_shutdown ~xs (x: device) = 
	hard_shutdown_request ~xs x;
	ignore(Watch.wait_for ~xs (hard_shutdown_complete ~xs x));
	(* blow away the backend and error paths *)
	debug "Device.Generic.hard_shutdown about to blow away backend and error paths";
	rm_device_state ~xs x

(*
(* Assume we've told the backend to close. Watch both the error node and one other path.
   When the watch fires, call a predicate function and look for an error node.
   If an error node appears, throw Device_error. If the predicate returns true then
   return unit. If the timeout expires throw Device_disconnect_timeout. *)
let wait_for_error_or ~xs ?(timeout=Hotplug.hotplug_timeout) doc predicate otherpath domid kind devid = 
	let doc' = Printf.sprintf "%s (timeout = %f; %s)" doc timeout (print_device domid kind devid) in
  	let errorpath = error_node domid kind devid in
	debug "Device.wait_for_error_or %s (watching [ %s; %s ])" doc' otherpath errorpath;

	let finished = ref false and error = ref None in
	let callback watch =
		finished := predicate ();
		error := (try Some (xs.Xs.read errorpath) with Xenbus.Xb.Noent -> None);
		(* We return if the predicate is true of an error node has appeared *)
		!finished || !error <> None in
	begin try
		Xs.monitor_paths xs [ otherpath, "X";
				      errorpath, "X" ] timeout callback;
	with
		Xs.Timeout ->
			warn "Device.wait_for_error_or %s: timeout" doc';
			raise (Device_disconnect_timeout (domid, kind, devid))
	end;
	begin match !error with
	| Some error ->
		warn "Device.wait_for_error_or %s: failed: %s" doc' error;
		raise (Device_error (domid, kind, devid, error))
	| None ->
		debug "Device.wait_for_error_or %s: succeeded" doc'
	end

(** When destroying a whole domain, we blow away the frontend tree of individual devices.
    NB we only ever blow away the frontend (blowing away the backend risks resource leaks)
    NB we only ever blow away frontends of domUs which are being destroyed - we don't
    expect them to recover from this! *)
let destroy ~xs domid kind devid =
	let frontend_path = get_frontend_path ~xs domid kind devid in
	xs.Xs.rm frontend_path
*)

	  let really_kill pid =
		  try
			  Unixext.kill_and_wait pid
		  with Unixext.Process_still_alive ->
			  debug "%d: failed to respond to SIGTERM, sending SIGKILL" pid;
			  Unixext.kill_and_wait ~signal:Sys.sigkill pid
	  let best_effort txt f =
		  try
			  f ()
		  with e ->
			  info "%s: ignoring exception %s" txt (Printexc.to_string e)

end

(****************************************************************************************)
(** Disks:                                                                              *)

module Vbd = struct

type shutdown_mode =
	| Classic (** no signal that backend has flushed, rely on (eg) SM vdi_deactivate for safety *)
    | ShutdownRequest (** explicit signal that backend has flushed via "shutdown-done" *)

let read_feature_flag ~xs (x: device) flag =
	let feature_flag_path = Printf.sprintf "/local/domain/%d/control/%s" x.backend.domid flag in
	try ignore(xs.Xs.read feature_flag_path); true with _ -> false

let shutdown_mode_of_device ~xs (x: device) =
	if read_feature_flag ~xs x "feature-shutdown-request"
	then ShutdownRequest
	else Classic

type mode = ReadOnly | ReadWrite

let string_of_mode = function
	| ReadOnly -> "r"
	| ReadWrite -> "w"

let mode_of_string = function
	| "r" -> ReadOnly
	| "w" -> ReadWrite
	| s   -> invalid_arg "mode_of_string"

type lock = string

(** The format understood by blocktap *)
let string_of_lock lock mode = lock ^ ":" ^ (string_of_mode mode)

type physty = File | Phys | Qcow | Vhd | Aio

let backendty_of_physty = function
	| File -> "file"
	| Phys -> "phy"
	| Qcow | Vhd | Aio -> "phy"

let string_of_physty = function
	| Qcow -> "qcow"
	| Vhd  -> "vhd"
	| Aio  -> "aio"
	| File -> "file"
	| Phys -> "phys"

let physty_of_string s =
	match s with
	| "qcow" -> Qcow
	| "vhd"  -> Vhd
	| "aio"  -> Aio
	| "phy"  -> Phys
	| "file" -> File
	| _      -> invalid_arg "physty_of_string"

type devty = CDROM | Disk

let string_of_devty = function
	| CDROM -> "cdrom"
	| Disk  -> "disk"

let devty_of_string = function
	| "cdrom" -> CDROM
	| "disk"  -> Disk
	| _       -> invalid_arg "devty_of_string"

let kind_of_physty physty =
	match physty with
	| Qcow -> Tap
	| Vhd  -> Tap
	| Aio  -> Tap
	| Phys -> Vbd
	| File -> Vbd

let add_backend_keys ~xs (x: device) subdir keys =
	let backend_stub = backend_path_of_device ~xs x in
	let backend = backend_stub ^ "/" ^ subdir in
	debug "About to write data %s to path %s" (String.concat ";" (List.map (fun (a,b) -> "("^a^","^b^")") keys)) backend;
	Xs.transaction xs (fun t ->
		ignore(t.Xst.read backend_stub);
		t.Xst.writev backend keys
	)

let remove_backend_keys ~xs (x: device) subdir keys =
	let backend_stub = backend_path_of_device ~xs x in
	let backend = backend_stub ^ "/" ^ subdir in
	Xs.transaction xs (fun t ->
		List.iter (fun key -> t.Xst.rm (backend ^ "/" ^ key)) keys
	)


let uses_blktap ~phystype = List.mem phystype [ Qcow; Vhd; Aio ]

(** Request either a clean or hard shutdown *)
let request_shutdown ~xs (x: device) (force: bool) =
    let request = if force then "force" else "normal" in

    debug "Device.Vbd.request_shutdown %s %s" (string_of_device x) request;

    let backend_path = backend_path_of_device ~xs x in
    let request_path = backend_shutdown_request_path_of_device ~xs x in
    let online_path = backend_path ^ "/online" in

    (* Prevent spurious errors appearing by not writing online=0 if force *)
    if not(force) then begin
        debug "xenstore-write %s = 0" online_path;
        xs.Xs.write online_path "0";
    end;
    debug "xenstore-write %s = %s" request_path request;
    xs.Xs.write request_path request

(** Return the event to wait for when the shutdown has completed *)
let shutdown_done ~xs (x: device): string Watch.t = 
    Watch.value_to_appear (backend_shutdown_done_path_of_device ~xs x)


let shutdown_request_clean_shutdown ~xs (x: device) =
    debug "Device.Vbd.clean_shutdown %s" (string_of_device x);

    request_shutdown ~xs x false; (* normal *)
    (* Allow the domain to reject the request by writing to the error node *)
    let shutdown_done = shutdown_done ~xs x in
    let error = Watch.value_to_appear (error_path_of_device ~xs x) in
    match Watch.wait_for ~xs (Watch.any_of [ `OK, shutdown_done; `Failed, error ]) with
		| `OK, _ ->
			debug "Device.Vbd.shutdown_common: shutdown-done appeared";
			(* Delete the trees (otherwise attempting to plug the device in again doesn't
               work.) This also clears any stale error nodes. *)
			Generic.rm_device_state ~xs x
		| `Failed, error ->
			(* CA-14804: Delete the error node contents *)
			Generic.safe_rm ~xs (error_path_of_device ~xs x);
			debug "Device.Vbd.shutdown_common: read an error: %s" error;
			raise (Device_error (x, error))


let shutdown_request_hard_shutdown ~xs (x: device) = 
	debug "Device.Vbd.hard_shutdown %s" (string_of_device x);
	request_shutdown ~xs x true; (* force *)

	(* We don't watch for error nodes *)
	ignore_string (Watch.wait_for ~xs (shutdown_done ~xs x));
	Generic.rm_device_state ~xs x;

	debug "Device.Vbd.hard_shutdown complete"

let clean_shutdown ~xs x = match shutdown_mode_of_device ~xs x with
	| Classic -> Generic.clean_shutdown ~xs x
	| ShutdownRequest -> shutdown_request_clean_shutdown ~xs x

let hard_shutdown ~xs x = match shutdown_mode_of_device ~xs x with
	| Classic -> Generic.hard_shutdown ~xs x
	| ShutdownRequest -> shutdown_request_hard_shutdown ~xs x

let hard_shutdown_request ~xs x = match shutdown_mode_of_device ~xs x with
	| Classic -> Generic.hard_shutdown_request ~xs x
	| ShutdownRequest -> request_shutdown ~xs x true

let hard_shutdown_complete ~xs x = match shutdown_mode_of_device ~xs x with
	| Classic -> Generic.hard_shutdown_complete ~xs x
	| ShutdownRequest -> shutdown_done ~xs x

let release ~xs (x: device) =
	debug "Device.Vbd.release %s" (string_of_device x);
	(* Make sure blktap/blkback fire the udev remove event by deleting the
	   backend now *)
	Generic.safe_rm ~xs (backend_path_of_device ~xs x);
	Hotplug.release ~xs x;
	(* As for add above, if the frontend is in dom0, we can wait for the frontend 
	 * to unplug as well as the backend. CA-13506 *)
	if x.frontend.domid = 0 then Hotplug.wait_for_frontend_unplug ~xs x

(* Add the VBD to the domain, When this command returns, the device is ready. (This isn't as
   concurrent as xend-- xend allocates loopdevices via hotplug in parallel and then
   performs a 'waitForDevices') *)
let add ~xs ~hvm ~mode ~device_number ~phystype ~params ~dev_type ~unpluggable
        ?(protocol=Protocol_Native) ?extra_backend_keys ?(extra_private_keys=[]) ?(backend_domid=0) domid  =
	let back_tbl = Hashtbl.create 16 and front_tbl = Hashtbl.create 16 in
	let devid = Device_number.to_xenstore_key device_number in
	let device = 
	  let backend = { domid = backend_domid; kind = Vbd; devid = devid } 
	  in  device_of_backend backend domid
	in

	debug "Device.Vbd.add (device_number=%s | params=%s | phystype=%s)"
	  (Device_number.to_debug_string device_number) params (string_of_physty phystype);
	(* Notes:
	   1. qemu accesses devices images itself and so needs the path of the original
              file (in params)
           2. when windows PV drivers initialise, the new blockfront connects to the
              up-til-now idle blockback.
           3. when the VM is fully PV, Ioemu devices do not work; all devices must be PV
	   4. in the future an HVM guest might support a mixture of both
	*)

	(match extra_backend_keys with
	 | Some keys ->
	     List.iter (fun (k, v) -> Hashtbl.add back_tbl k v) keys
	 | None -> ());

	Hashtbl.add_list front_tbl [
		"backend-id", string_of_int backend_domid;
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
		"virtual-device", string_of_int devid;
		"device-type", if dev_type = CDROM then "cdrom" else "disk";
	];
	Hashtbl.add_list back_tbl [
		"frontend-id", sprintf "%u" domid;
		(* Prevents the backend hotplug scripts from running if the frontend disconnects.
		   This allows the xenbus connection to re-establish itself *)
		"online", "1";
		"removable", if unpluggable then "1" else "0";
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
		"dev", Device_number.to_linux_device device_number;
		"type", backendty_of_physty phystype;
		"mode", string_of_mode mode;
		"params", params;
	];
    (* We don't have PV drivers for HVM guests for CDROMs. We prevent
       blkback from successfully opening the device since this can
       prevent qemu CD eject (and subsequent vdi_deactivate) *)
	if hvm && (dev_type = CDROM) then
		Hashtbl.add back_tbl "no-physical-device" "";

	if protocol <> Protocol_Native then
		Hashtbl.add front_tbl "protocol" (string_of_protocol protocol);

	let back = Hashtbl.to_list back_tbl in
	let front = Hashtbl.to_list front_tbl in


	Generic.add_device ~xs device back front extra_private_keys;
	Hotplug.wait_for_plug ~xs device;
	(* 'Normally' we connect devices to other domains, and cannot know whether the
	   device is 'available' from their userspace (or even if they have a userspace).
	   The best we can do is just to wait for the backend hotplug scripts to run,
	   indicating that the backend has locked the resource.
	   In the case of domain 0 we can do better: we have custom hotplug scripts
	   which call us back when the device is actually available to userspace. We need
	   to wait for this condition to make the template installers work.
	   NB if the custom hotplug script fires this implies that the xenbus state
	   reached "connected", so we don't have to check for that first. *)
	if domid = 0 then begin
	  try
	    (* CA-15605: clean up on dom0 block-attach failure *)
	    Hotplug.wait_for_frontend_plug ~xs device;
	  with Hotplug.Frontend_device_error _ as e ->
	    debug "Caught Frontend_device_error: assuming it is safe to shutdown the backend";
	    clean_shutdown ~xs device; (* assumes double-failure isn't possible *)
	    release ~xs device;
		(* Attempt to diagnose the error: the error from blkback ("2 creating vbd structure")
		   doesn't give much away. *)
		if backend_domid = 0 && phystype = Phys then begin
		  try
			(* Speculatively query the physical device as if a CDROM *)
			  match Cdrom.query_cdrom_drive_status params with
			  | Cdrom.DISC_OK -> () (* nothing unusual here *)
			  | x -> 
					error "CDROM device %s: %s" params (Cdrom.string_of_cdrom_drive_status x);
					raise Cdrom
		  with 
		  | Cdrom as e' -> raise e'
		  | _ -> () (* assume it wasn't a CDROM *)
		end;
	    raise e
	end;
	device

let qemu_media_change ~xs ~device_number domid _type params =
	let devid = Device_number.to_xenstore_key device_number in
	let back_dom_path = xs.Xs.getdomainpath 0 in
	let backend  = sprintf "%s/backend/vbd/%u/%d" back_dom_path domid devid in
	let back_delta = [
		"type",           _type;
		"params",         params;
	] in
	Xs.transaction xs (fun t -> t.Xst.writev backend back_delta);
	debug "Media changed"

let media_tray_is_locked ~xs ~device_number domid =
	let devid = Device_number.to_xenstore_key device_number in
  let backend = { domid = 0; kind = Vbd; devid = devid } in
  let path = sprintf "%s/locked" (backend_path ~xs backend domid) in
    try
      xs.Xs.read path = "true"
    with _ ->
      false

let media_eject ~xs ~device_number domid =
	qemu_media_change ~xs ~device_number domid "" ""

let media_insert ~xs ~device_number ~params ~phystype domid =
	let _type = backendty_of_physty phystype in
	qemu_media_change ~xs ~device_number domid _type params

let media_refresh ~xs ~device_number ~params domid =
	let devid = Device_number.to_xenstore_key device_number in
	let back_dom_path = xs.Xs.getdomainpath 0 in
	let backend = sprintf "%s/backend/vbd/%u/%d" back_dom_path domid devid in
	let path = backend ^ "/params" in
	(* unfortunately qemu filter the request if on the same string it has,
	   so we trick it by having a different string, but the same path, adding a
	   spurious '/' character at the beggining of the string.  *)
	let oldval = try xs.Xs.read path with _ -> "" in
	let pathtowrite =
		if oldval = params then (
			"/" ^ params
		) else
			params in
	xs.Xs.write path pathtowrite;
	()

let media_is_ejected ~xs ~device_number domid =
	let devid = Device_number.to_xenstore_key device_number in
	let back_dom_path = xs.Xs.getdomainpath 0 in
	let backend = sprintf "%s/backend/vbd/%u/%d" back_dom_path domid devid in
	let path = backend ^ "/params" in
	try xs.Xs.read path = "" with _ -> true

end

(****************************************************************************************)
(** VIFs:                                                                               *)

(**
   Generate a random MAC address, using OUI (Organizationally Unique
   Identifier) 00-16-3E, allocated to Xensource, Inc.

   The remaining 3 fields are random, with the first bit of the first random
   field set 0.
 *)

module Vif = struct

exception Invalid_Mac of string

let check_mac mac =
        try
                if String.length mac <> 17 then failwith "mac length";
	        Scanf.sscanf mac "%2x:%2x:%2x:%2x:%2x:%2x" (fun a b c d e f -> ());
	        mac
        with _ ->
		raise (Invalid_Mac mac)

let add ~xs ~devid ~netty ~mac ~carrier ?mtu ?(rate=None) ?(protocol=Protocol_Native) ?(backend_domid=0) ?(other_config=[]) ?(extra_private_keys=[]) domid =
	debug "Device.Vif.add domid=%d devid=%d mac=%s carrier=%b rate=%s other_config=[%s] extra_private_keys=[%s]" domid devid mac carrier
	      (match rate with None -> "none" | Some (a, b) -> sprintf "(%Ld,%Ld)" a b)
	      (String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) other_config))
	      (String.concat "; " (List.map (fun (k, v) -> k ^ "=" ^ v) extra_private_keys));
	(* Filter the other_config keys using vif_udev_keys as a whitelist *)
	let other_config = List.filter (fun (x, _) -> List.mem x vif_udev_keys) other_config in
	let frontend = { domid = domid; kind = Vif; devid = devid } in
	let backend = { domid = backend_domid; kind = Vif; devid = devid } in
	let device = { backend = backend; frontend = frontend } in

	let mac = check_mac mac in

	let back_options =
		match rate with
		| None                              -> []
		| Some (kbytes_per_s, timeslice_us) ->
			let (^*) = Int64.mul and (^/) = Int64.div in
			let timeslice_us =
				if timeslice_us > 0L then
					timeslice_us
				else
					50000L (* 50ms by default *) in
			let bytes_per_interval = ((kbytes_per_s ^* 1024L) ^* timeslice_us)
			                         ^/ 1000000L in
			if bytes_per_interval > 0L && bytes_per_interval < 0xffffffffL then
				[ "rate", sprintf "%Lu,%Lu" bytes_per_interval timeslice_us ]
			else (
				debug "VIF qos: invalid value for byte/interval: %Lu" bytes_per_interval;
				[]
			)
		in

	let back = [
		"frontend-id", sprintf "%u" domid;
		"online", "1";
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
		"script", (Filename.concat Fhs.scriptsdir "vif");
		"mac", mac;
		"handle", string_of_int devid
	] @ back_options in

	let front_options =
		if protocol <> Protocol_Native then
			[ "protocol", string_of_protocol protocol; ]
		else
			[] in

	let front = [
		"backend-id", string_of_int backend_domid;
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
		"handle", string_of_int devid;
		"mac", mac;
		"disconnect", if carrier then "0" else "1";
	] @ front_options in

	let extra_private_keys = List.map (fun (k, v) -> "other-config/" ^ k, v) other_config @ extra_private_keys in
	(* Add the rest of the important configuration to the private bit of xenstore so we can access it later *)
	let extra_private_keys = extra_private_keys @
	  (match mtu with | Some mtu when mtu > 0 -> [ "MTU", string_of_int mtu ] | _ -> []) @
	  (match netty with
	     | Netman.Bridge b -> [ "bridge", b; "bridge-MAC", if(Xenctrl.is_fake ()) then "fe:fe:fe:fe:fe:fe" else "fe:ff:ff:ff:ff:ff"; ]
	     | Netman.Vswitch b -> [ "bridge", b; "bridge-MAC", if(Xenctrl.is_fake ()) then "fe:fe:fe:fe:fe:fe" else "fe:ff:ff:ff:ff:ff"; ]
	     | Netman.DriverDomain -> []
	     | Netman.Nat -> []) @
	  (match rate with | None -> [] | Some(rate, timeslice) -> [ "rate", Int64.to_string rate; "timeslice", Int64.to_string timeslice ]) in

	Generic.add_device ~xs device back front extra_private_keys;
	Hotplug.wait_for_plug ~xs device;
	device

let clean_shutdown = Generic.clean_shutdown

let hard_shutdown = Generic.hard_shutdown

let set_carrier ~xs (x: device) carrier = 
	debug "Device.Vif.set_carrier %s <- %b" (string_of_device x) carrier;
	let disconnect_path = disconnect_path_of_device ~xs x in
	xs.Xs.write disconnect_path (if carrier then "0" else "1")

let release ~xs (x: device) =
	debug "Device.Vif.release %s" (string_of_device x);
	Hotplug.release ~xs x
end

(*****************************************************************************)
(** Vcpus:                                                                   *)
module Vcpu = struct

let add ~xs ~devid domid =
	let path = sprintf "/local/domain/%d/cpu/%d" domid devid in
	xs.Xs.writev path [
		"availability", "online"
	]

let del ~xs ~devid domid =
	let path = sprintf "/local/domain/%d/cpu/%d" domid devid in
	xs.Xs.rm path

let set ~xs ~devid domid online =
	let path = sprintf "/local/domain/%d/cpu/%d/availability" domid devid in
	xs.Xs.write path (if online then "online" else "offline")

let status ~xs ~devid domid =
	let path = sprintf "/local/domain/%d/cpu/%d/availability" domid devid in
	try match xs.Xs.read path with
	| "online"  -> true
	| "offline" -> false
	| _         -> (* garbage, assuming false *) false
	with Xenbus.Xb.Noent -> false

end

module PV_Vnc = struct

let vncterm_wrapper = Filename.concat Fhs.libexecdir "vncterm-wrapper"

let vnc_pid_path domid = sprintf "/local/domain/%d/vncterm-pid" domid

let pid ~xs domid =
	try
		let pid = xs.Xs.read (vnc_pid_path domid) in
		Some (int_of_string pid)
	with _ ->
		None

let is_vncterm_running ~xs domid =
	match pid ~xs domid with
		| None -> false
		| Some p ->
			try
				Unix.kill p 0;
				true
			with _ -> false

let get_vnc_port ~xs domid =
	if not (is_vncterm_running ~xs domid)
	then None
	else (try Some(int_of_string (xs.Xs.read (Generic.vnc_port_path domid))) with _ -> None)

let get_tc_port ~xs domid =
	if not (is_vncterm_running ~xs domid)
	then None
	else (try Some(int_of_string (xs.Xs.read (Generic.tc_port_path domid))) with _ -> None)


let load_args = function
	| None -> []
	| Some filename ->
		if Sys.file_exists filename
		then ["-l"; filename]
		else []

exception Failed_to_start

let vncterm_statefile pid = sprintf "/var/xen/vncterm/%d/vncterm.statefile" pid

let get_statefile ~xs domid =
	match pid ~xs domid with
	| None -> None
	| Some pid -> 
		  let filename = vncterm_statefile pid in
		  if Sys.file_exists filename then
			  Some filename
		  else
			  None

let save ~xs domid =
	match pid ~xs domid with
	| Some pid -> 
		  Unix.kill pid Sys.sigusr1;
		  let filename = vncterm_statefile pid in
		  let delay = 10. in
		  let start_time = Unix.time () in
		  (* wait at most ten seconds *)
		  while not (Sys.file_exists filename) || Unix.time () -. start_time > delay do
			  debug "Device.PV_Vnc.save: waiting for %s to appear" filename;
			  Thread.delay 1.
		  done;
		  if Unix.time () -. start_time > delay then
			  debug "Device.PV_Vnc.save: timeout while waiting for %s to appear" filename
		  else
			  debug "Device.PV_Vnc.save: %s has appeared" filename
	| None     -> ()

let start ?statefile ~xs domid =
	let l = [ string_of_int domid; (* absorbed by vncterm-wrapper *)
		  (* everything else goes straight through to vncterm: *)
		  "-x"; sprintf "/local/domain/%d/console" domid;
		  "-T"; (* listen for raw connections *)
		] @ load_args statefile in
	(* Now add the close fds wrapper *)
	let pid = Forkhelpers.safe_close_and_exec None None None [] vncterm_wrapper l in
	Forkhelpers.dontwaitpid pid

let stop ~xs domid =
	let open Generic in
	match pid ~xs domid with
		| Some pid ->
			best_effort "killing vncterm"
				(fun () -> Unix.kill (-pid) Sys.sigterm);
			best_effort "removing vncterm-pid from xenstore"
				(fun () -> xs.Xs.rm (vnc_pid_path domid))
		| None -> ()

end

module PCI = struct

type t = {
	domain: int;
	bus: int;
	slot: int;
	func: int;
	irq: int;
	resources: (int64 * int64 * int64) list;
	driver: string;
}

type dev = int * int * int * int

let to_string (domain, bus, dev, func) = Printf.sprintf "%04x:%02x:%02x.%01x" domain bus dev func
let of_string x = Scanf.sscanf x "%04x:%02x:%02x.%02x" (fun a b c d -> (a, b, c, d)) 

exception Cannot_add of dev list * exn (* devices, reason *)
exception Cannot_use_pci_with_no_pciback of t list

(* same as libxl_internal: PROC_PCI_NUM_RESOURCES *)
let _proc_pci_num_resources = 7
(* same as libxl_internal: PCI_BAR_IO *)
let _pci_bar_io = 0x01L

let query_pci_device domain bus slot func =
	let map_resource file =
		let resources = Array.create _proc_pci_num_resources (0L, 0L, 0L) in
		let i = ref 0 in
		Unixext.readfile_line (fun line ->
			if !i < Array.length resources then (
				Scanf.sscanf line "0x%Lx 0x%Lx 0x%Lx" (fun s e f ->
					resources.(!i) <- (s, e, f));
				incr i
			)
		) file;
		List.filter (fun (s, _, _) -> s <> 0L) (Array.to_list resources);
		in
	let map_irq file =
		let irq = ref (-1) in
		try Unixext.readfile_line (fun line -> irq := int_of_string line) file; !irq
		with _ -> -1
		in
		
	let name = to_string (domain, bus, slot, func) in
	let dir = "/sys/bus/pci/devices/" ^ name in
	let resources = map_resource (dir ^ "/resource") in
	let irq = map_irq (dir ^ "/irq") in
	let driver =
		try Filename.basename (Unix.readlink (dir ^ "/driver"))
		with _ -> "" in
	irq, resources, driver

let grant_access_resources xc domid resources v =
	let action = if v then "add" else "remove" in
	List.iter (fun (s, e, flags) ->
		if Int64.logand flags _pci_bar_io = _pci_bar_io then (
			let first_port = Int64.to_int s in
			let nr_ports = (Int64.to_int e) - first_port + 1 in

			debug "pci %s io bar %Lx-%Lx" action s e;
			Xenctrl.domain_ioport_permission xc domid first_port nr_ports v
		) else (
			let size = Int64.(add (sub e s) 1L) in
			let _page_size = 4096L in
			let to_page_round_down m = Int64.(div m _page_size) in
			let to_page_round_up m = Int64.(add m (sub _page_size 1L)) |> to_page_round_down in
			let first_pfn = to_page_round_down s in
			let nr_pfns = to_page_round_up size in

			debug "pci %s mem bar first_pfn=%Lx nr_pfns=%Lx" action first_pfn nr_pfns;
			Xenctrl.domain_iomem_permission xc domid (Int64.to_nativeint first_pfn) (Int64.to_nativeint nr_pfns) v
		)
	) resources

let add_noexn ~xc ~xs ~hvm ~msitranslate ~pci_power_mgmt ?(flrscript=None) pcidevs domid devid =
	let pcidevs = List.map (fun (domain, bus, slot, func) ->
		let (irq, resources, driver) = query_pci_device domain bus slot func in
		{ domain = domain; bus = bus; slot = slot; func = func;
		  irq = irq; resources = resources; driver = driver }
	) pcidevs in

	let baddevs = List.filter (fun t -> t.driver <> "pciback") pcidevs in
	if List.length baddevs > 0 then (
		raise (Cannot_use_pci_with_no_pciback baddevs);
	);

	List.iter (fun dev ->
		let d = to_string (dev.domain, dev.bus, dev.slot, dev.func) in
		debug "Preparing PCI device %s" d;
		List.iter (fun (s, e, flags) ->
			debug "PCI device %s has resource %Lx -> %Lx (%Lx%s)" d s e flags
				(if Int64.logand flags _pci_bar_io = _pci_bar_io then " = PCI_BAR" else "");
		) dev.resources;
		debug "PCI device %s has IRQ %d" d dev.irq;
		if hvm then (
			ignore_bool (Xenctrl.domain_test_assign_device xc domid (dev.domain, dev.bus, dev.slot, dev.func));
			()
		);
		grant_access_resources xc domid dev.resources true;
		(* XXX: libxl calls xc_physdev_map_pirq *)
		if dev.irq > 0 then
			Xenctrl.domain_irq_permission xc domid dev.irq true
	) pcidevs;

	let device = {
		backend = { domid = 0; kind = Pci; devid = devid };
		frontend = { domid = domid; kind = Pci; devid = devid };
	} in

	let others = (match flrscript with None -> [] | Some script -> [ ("script", script) ]) in
	let xsdevs = List.mapi (fun i dev ->
		[
			sprintf "key-%d" i, to_string (dev.domain, dev.bus, dev.slot, dev.func);
			sprintf "dev-%d" i, to_string (dev.domain, dev.bus, dev.slot, dev.func);
			sprintf "opts-%d" i, "msitranslate=0,power_mgmt=0";
			sprintf "state-%d" i, "1";
		]
	) pcidevs |> List.concat in

	let backendlist = [
		"frontend-id", sprintf "%u" domid;
		"online", "1";
		"num_devs", string_of_int (List.length pcidevs);
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] and frontendlist = [
		"backend-id", "0";
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] in

	Generic.add_device ~xs device (others @ xsdevs @ backendlist) frontendlist [];
	()

let pci_info_of ~msitranslate ~pci_power_mgmt = function
    | domain, bus, dev, func ->
        {
            (* XXX: I don't think we can guarantee how the C compiler will
               lay out bitfields.
			   unsigned int reserved1:2;
			   unsigned int reg:6;
			   unsigned int func:3;
			   unsigned int dev:5;
			   unsigned int bus:8;
			   unsigned int reserved2:7;
			   unsigned int enable:1;
            *)
            Xenlight.v = (func lsl 8) lor (dev lsl 11) lor (bus lsl 16);
            domain = domain;
            vdevfn = 0;
            msitranslate = msitranslate = 1;
            power_mgmt = pci_power_mgmt = 1;
        }


(* XXX: this will crash because of the logging policy within the
   Xenlight ocaml bindings. *)
let add_libxl ~msitranslate ~pci_power_mgmt pcidevs domid =
	List.iter
		(fun dev ->
			try
				Xenlight.pci_add (pci_info_of ~msitranslate ~pci_power_mgmt dev) domid
			with e ->
				debug "Xenlight.pci_add: %s" (Printexc.to_string e);
				raise e
		) pcidevs

(* XXX: this will crash because of the logging policy within the
   Xenlight ocaml bindings. *)
let release_libxl ~msitranslate ~pci_power_mgmt pcidevs domid =
	List.iter
		(fun dev ->
			try
				Xenlight.pci_remove (pci_info_of ~msitranslate ~pci_power_mgmt dev) domid
			with e ->
				debug "Xenlight.pci_remove: %s" (Printexc.to_string e);
				raise e
		) pcidevs

(* XXX: we don't want to use the 'xl' command here because the "interface"
   isn't considered as stable as the C API *)
let xl_pci cmd ?(msitranslate=0) ?(pci_power_mgmt=0) pcidevs domid =
	List.iter
		(fun dev ->
			try
				let (_, _) = Forkhelpers.execute_command_get_output
					"/usr/sbin/xl"
					[ cmd; string_of_int domid; to_string dev ] in
				()
			with e ->
				debug "xl %s: %s" cmd (Printexc.to_string e);
				raise e
		) pcidevs

let add_xl = xl_pci "pci-attach"

let release_xl = xl_pci "pci-detach"

let add ~xc ~xs ~hvm ~msitranslate ~pci_power_mgmt ?flrscript pcidevs domid devid =
	try
		if hvm
		then add_noexn ~xc ~xs ~hvm ~msitranslate ~pci_power_mgmt ?flrscript pcidevs domid devid
		else
			(* Switch the PV path over to libxl since the code is better *)
			add_xl ~msitranslate ~pci_power_mgmt pcidevs domid
	with exn ->
		raise (Cannot_add (pcidevs, exn))

let release_exn ~xc ~xs ~hvm pcidevs domid devid =
	let pcidevs = List.map (fun (domain, bus, slot, func) ->
		let (irq, resources, driver) = query_pci_device domain bus slot func in
		{ domain = domain; bus = bus; slot = slot; func = func;
		  irq = irq; resources = resources; driver = driver }
	) pcidevs in

	let baddevs = List.filter (fun t -> t.driver <> "pciback") pcidevs in
	if List.length baddevs > 0 then (
		raise (Cannot_use_pci_with_no_pciback baddevs);
	);

	List.iter (fun dev ->
		grant_access_resources xc domid dev.resources false;
		if dev.irq > 0 then
			Xenctrl.domain_irq_permission xc domid dev.irq false
	) pcidevs;
	()

let release ~xc ~xs ~hvm pcidevs domid devid =
	if hvm
	then release_exn ~xc ~xs ~hvm pcidevs domid devid
	else 
		(* Switch the PV path over to libxl since the code is better *)
		release_xl pcidevs domid

let write_string_to_file file s =
	let fn_write_string fd = Unixext.really_write fd s 0 (String.length s) in
	Unixext.with_file file [ Unix.O_WRONLY ] 0o640 fn_write_string

let do_flr device =
  debug "Doing FLR on pci device: %s" device;
	let doflr = "/sys/bus/pci/drivers/pciback/do_flr" in
	let script = Filename.concat Fhs.libexecdir "pci-flr" in
	let callscript =
                let f s devstr =
	                try ignore (Forkhelpers.execute_command_get_output script [ s; devstr; ])
			        with _ -> ()
			in
			f
		in
        callscript "flr-pre" device;
        ( try write_string_to_file doflr device with _ -> (); );
        callscript "flr-post" device

let bind pcidevs =
	let bind_to_pciback device =
		let newslot = "/sys/bus/pci/drivers/pciback/new_slot" in
		let bind = "/sys/bus/pci/drivers/pciback/bind" in
		write_string_to_file newslot device;
		write_string_to_file bind device;
		do_flr device;
		in
	List.iter (fun (domain, bus, slot, func) ->
		let devstr = to_string (domain, bus, slot, func) in
		let s = "/sys/bus/pci/devices/" ^ devstr in
		let driver =
			try Some (Filename.basename (Unix.readlink (s ^ "/driver")))
			with _ -> None in
		begin match driver with
		| None           ->
			bind_to_pciback devstr
		| Some "pciback" ->
			debug "pci: device %s already bounded to pciback" devstr;
		        do_flr devstr		    
		| Some d         ->
			debug "pci: unbounding device %s from driver %s" devstr d;
			let f = s ^ "/driver/unbind" in
			write_string_to_file f devstr;
			bind_to_pciback devstr
		end;
	) pcidevs;
	()

let enumerate_devs ~xs (x: device) =
	let backend_path = backend_path_of_device ~xs x in
	let num =
		try int_of_string (xs.Xs.read (backend_path ^ "/num_devs"))
		with _ -> 0
		in
	let devs = Array.make num None in
	for i = 0 to num
	do
		try
			let devstr = xs.Xs.read (backend_path ^ "/dev-" ^ (string_of_int i)) in
			let dev = of_string devstr in
			devs.(i) <- Some dev
		with _ ->
			()
	done;
	List.rev (List.fold_left (fun acc dev ->
		match dev with
		| None -> acc
		| Some dev -> dev :: acc
	) [] (Array.to_list devs))

let reset ~xs (x: dev) =
	let devstr = to_string x in
	debug "Device.Pci.reset %s" devstr;
	do_flr devstr

let clean_shutdown ~xs (x: device) =
	debug "Device.Pci.clean_shutdown %s" (string_of_device x);
	let devs = enumerate_devs ~xs x in
	Xenctrl.with_intf (fun xc ->
		let hvm =
			try (Xenctrl.domain_getinfo xc x.frontend.domid).Xenctrl.hvm_guest
			with _ -> false
			in
		try release ~xc ~xs ~hvm devs x.frontend.domid x.frontend.devid
		with _ -> ());
	()

let hard_shutdown ~xs (x: device) =
	debug "Device.Pci.hard_shutdown %s" (string_of_device x);
	clean_shutdown ~xs x

(* This is the global location where PCI device add/remove status is put. We should aim to use
   a per-device location to support parallel requests in future *)
let device_model_state_path xs be_domid fe_domid =
  Printf.sprintf "%s/device-model/%d/state" (xs.Xs.getdomainpath be_domid) fe_domid

let device_model_pci_device_path xs be_domid fe_domid =
  let be_path = xs.Xs.getdomainpath be_domid in
  Printf.sprintf "%s/backend/pci/%d/0" be_path fe_domid


let signal_device_model ~xc ~xs domid cmd parameter = 
	debug "Device.Pci.signal_device_model domid=%d cmd=%s param=%s" domid cmd parameter;
	let be_domid = 0 in (* XXX: assume device model is in domain 0 *)
	let be_path = xs.Xs.getdomainpath be_domid in 
	(* Currently responses go in this global place. Blank it to prevent request/response/request confusion *)
	xs.Xs.rm (device_model_state_path xs be_domid domid);

	Xs.transaction xs (fun t ->
		t.Xst.writev be_path [ Printf.sprintf "device-model/%d/command" domid, cmd;
				       Printf.sprintf "device-model/%d/parameter" domid, parameter ];
	)

let wait_device_model ~xc ~xs domid = 
  let be_domid = 0 in
  let answer = Watch.wait_for ~xs (Watch.value_to_appear (device_model_state_path xs be_domid domid)) in
  xs.Xs.rm (device_model_state_path xs be_domid domid);
  answer
							
(* Given a domid, return a list of [ X, (domain, bus, dev, func) ] where X indicates the order in
   which the device was plugged. *)
let read_pcidir ~xc ~xs domid = 
  let path = device_model_pci_device_path xs 0 domid in
  let prefix = "dev-" in
  let all = List.filter (String.startswith prefix) (try xs.Xs.directory path with Xenbus.Xb.Noent -> []) in
  (* The values are the PCI device (domain, bus, dev, func) strings *)
  let device_number_of_string x =
    (* remove the silly prefix *)
    int_of_string (String.sub x (String.length prefix) (String.length x - (String.length prefix))) in
  let pairs = List.map (fun x -> device_number_of_string x, of_string (xs.Xs.read (path ^ "/" ^ x))) all in
  (* Sort into the order the devices were plugged *)
  List.sort (fun a b -> compare (fst a) (fst b)) pairs

(* Return a list of PCI devices *)
let list ~xc ~xs domid = 
	(* replace the sort index with the default '0' -- XXX must figure out whether this matters to anyone *)
	List.map (fun (_, y) -> (0, y)) (read_pcidir ~xc ~xs domid)


let plug ~xc ~xs (domain, bus, dev, func) domid = 
    let current = read_pcidir ~xc ~xs domid in
	let next_idx = List.fold_left max (-1) (List.map fst current) + 1 in
	
	let pci = to_string (domain, bus, dev, func) in
	signal_device_model ~xc ~xs domid "pci-ins" pci;

	let () = match wait_device_model ~xc ~xs domid with
	| "pci-inserted" -> 
		  (* success *)
		  xs.Xs.write (device_model_pci_device_path xs 0 domid ^ "/dev-" ^ (string_of_int next_idx)) pci;
	| x ->
		failwith
			(Printf.sprintf "Waiting for state=pci-inserted; got state=%s" x) in
	Xenctrl.domain_assign_device xc domid (domain, bus, dev, func)

let unplug ~xc ~xs (domain, bus, dev, func) domid = 
    let current = list ~xc ~xs domid in

	let pci = to_string (domain, bus, dev, func) in
	let idx = fst (List.find (fun x -> snd x = (domain, bus, dev, func)) current) in
	signal_device_model ~xc ~xs domid "pci-rem" pci;

	let () = match wait_device_model ~xc ~xs domid with
	| "pci-removed" -> 
		  (* success *)
		  xs.Xs.rm (device_model_pci_device_path xs 0 domid ^ "/dev-" ^ (string_of_int idx))
	| x ->
		failwith (Printf.sprintf "Waiting for state=pci-removed; got state=%s" x)
	in
	(* CA-62028: tell the device to stop whatever it's doing *)
	do_flr pci;
	Xenctrl.domain_deassign_device xc domid (domain, bus, dev, func)

end

module Vfs = struct

let add ~xc ~xs ?(backend_domid=0) domid =
    debug "Device.Vfs.add domid=%d" domid;
    let frontend = { domid = domid; kind = Vfs; devid = 0 } in
    let backend = { domid = backend_domid; kind = Vfs; devid = 0 } in
    let _ = { backend = backend; frontend = frontend } in

    let frontend_path = Printf.sprintf "/local/domain/%d/device/vfs/%d" domid 0 in
    let backend_path = Printf.sprintf "/local/domain/%d/backend/vfs/%d" backend_domid domid in
    let request_path = Printf.sprintf "/local/domain/%d/backend/vfs/exports/requests/%d" backend_domid domid in

    (* TODO also have a backend?! *)
    let front = [
        "state", "ready"; (* definitely needs to be "ready" *)
        "backend", backend_path;
    ] in
    Xs.transaction xs (fun t ->
        (* Add the frontend *)
        let perms = (domid, Xsraw.PERM_NONE, [(0, Xsraw.PERM_READ)]) in
        t.Xst.mkdir frontend_path;
        t.Xst.setperms frontend_path perms;
        t.Xst.writev frontend_path front;

        (* Now make the request *)
        let perms = (domid, Xsraw.PERM_NONE, []) in
        let request_path = Printf.sprintf "%s/%d" request_path 0 in
        t.Xst.mkdir request_path;
        t.Xst.setperms request_path perms;
        t.Xst.write (request_path ^ "/frontend") frontend_path;
    );
	()

let hard_shutdown ~xs (x: device) =
	debug "Device.Vfs.hard_shutdown %s" (string_of_device x);
	()

let clean_shutdown ~xs (x: device) =
	debug "Device.Vfs.clean_shutdown %s" (string_of_device x);
	()
end


module Vfb = struct

let add ~xc ~xs ?(backend_domid=0) ?(protocol=Protocol_Native) domid =
	debug "Device.Vfb.add %d" domid;

	let frontend = { domid = domid; kind = Vfb; devid = 0 } in
	let backend = { domid = backend_domid; kind = Vfb; devid = 0 } in
	let device = { backend = backend; frontend = frontend } in

	let back = [
		"frontend-id", sprintf "%u" domid;
		"online", "1";
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] in
	let front = [
		"backend-id", string_of_int backend_domid;
		"protocol", (string_of_protocol protocol);
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] in
	Generic.add_device ~xs device back front [];
	()

let hard_shutdown ~xs (x: device) =
	debug "Device.Vfb.hard_shutdown %s" (string_of_device x);
	()

let clean_shutdown ~xs (x: device) =
	debug "Device.Vfb.clean_shutdown %s" (string_of_device x);
	()

end

module Vkbd = struct

let add ~xc ~xs ?(backend_domid=0) ?(protocol=Protocol_Native) domid =
	debug "Device.Vkbd.add %d" domid;

	let frontend = { domid = domid; kind = Vkbd; devid = 0 } in
	let backend = { domid = backend_domid; kind = Vkbd; devid = 0 } in
	let device = { backend = backend; frontend = frontend } in

	let back = [
		"frontend-id", sprintf "%u" domid;
		"online", "1";
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] in
	let front = [
		"backend-id", string_of_int backend_domid;
		"protocol", (string_of_protocol protocol);
		"state", string_of_int (Xenbus_utils.int_of Xenbus_utils.Initialising);
	] in
	Generic.add_device ~xs device back front []; 
	()

let hard_shutdown ~xs (x: device) =
	debug "Device.Vkbd.hard_shutdown %s" (string_of_device x);
	()

let clean_shutdown ~xs (x: device) =
	debug "Device.Vkbd.clean_shutdown %s" (string_of_device x);
	()

end

let hard_shutdown ~xs (x: device) = match x.backend.kind with
  | Vif -> Vif.hard_shutdown ~xs x
  | Vbd | Tap -> Vbd.hard_shutdown ~xs x
  | Pci -> PCI.hard_shutdown ~xs x
  | Vfs -> Vfs.hard_shutdown ~xs x
  | Vfb -> Vfb.hard_shutdown ~xs x
  | Vkbd -> Vkbd.hard_shutdown ~xs x

let clean_shutdown ~xs (x: device) = match x.backend.kind with
  | Vif -> Vif.clean_shutdown ~xs x
  | Vbd | Tap -> Vbd.clean_shutdown ~xs x
  | Pci -> PCI.clean_shutdown ~xs x
  | Vfs -> Vfs.clean_shutdown ~xs x
  | Vfb -> Vfb.clean_shutdown ~xs x
  | Vkbd -> Vkbd.clean_shutdown ~xs x


let can_surprise_remove ~xs (x: device) = Generic.can_surprise_remove ~xs x

module Dm = struct

(* An example one:
 /usr/lib/xen/bin/qemu-dm -d 39 -m 256 -boot cd -serial pty -usb -usbdevice tablet -domain-name bee94ac1-8f97-42e0-bf77-5cb7a6b664ee -net nic,vlan=1,macaddr=00:16:3E:76:CE:44,model=rtl8139 -net tap,vlan=1,bridge=xenbr0 -vnc 39 -k en-us -vnclisten 127.0.0.1
*)

let max_emulated_nics = 8 (** Should be <= the hardcoded maximum number of emulated NICs *)

(* How the display appears to the guest *)
type disp_intf_opt =
    | Std_vga
    | Cirrus

(* Display output / keyboard input *)
type disp_opt =
	| NONE
	| VNC of disp_intf_opt * bool * int * string (* auto-allocate, port if previous false, keymap *)
	| SDL of disp_intf_opt * string (* X11 display *)
	| Passthrough of int option
	| Intel of disp_intf_opt * int option

type media = Disk | Cdrom
let string_of_media = function Disk -> "disk" | Cdrom -> "cdrom"

type info = {
	memory: int64;
	boot: string;
	serial: string;
	vcpus: int;
	usb: string list;
	nics: (string * string * int) list;
	disks: (int * string * media) list;
	acpi: bool;
	disp: disp_opt;
	pci_emulations: string list;
	pci_passthrough: bool;
	
	(* Xenclient extras *)
	xenclient_enabled : bool;
	hvm : bool;
	sound : string option;
	power_mgmt : int option;
	oem_features : int option;
	inject_sci : int option;
	video_mib : int;

	extras: (string * string option) list;
}

(* Where qemu-dm-wrapper writes its pid *)
let qemu_pid_path domid = sprintf "/local/domain/%d/qemu-pid" domid

(* Where qemu writes its state and is signalled *)
let device_model_path domid = sprintf "/local/domain/0/device-model/%d" domid

let pid ~xs domid =
	try
		let pid = xs.Xs.read (qemu_pid_path domid) in
		Some (int_of_string pid)
	with _ ->
		None

let is_qemu_running ~xs domid =
	match pid ~xs domid with
		| None -> false
		| Some p ->
			try
				Unix.kill p 0;
				true
			with _ -> false

let get_vnc_port ~xs domid =
	if not (is_qemu_running ~xs domid)
	then None
	else (try Some(int_of_string (xs.Xs.read (Generic.vnc_port_path domid))) with _ -> None)

let get_tc_port ~xs domid =
	if not (is_qemu_running ~xs domid)
	then None
	else (try Some(int_of_string (xs.Xs.read (Generic.tc_port_path domid))) with _ -> None)


(* Xenclient specific paths *)
let power_mgmt_path domid = sprintf "/local/domain/0/device-model/%d/xen_extended_power_mgmt" domid
let oem_features_path domid = sprintf "/local/domain/0/device-model/%d/oem_features" domid
let inject_sci_path domid = sprintf "/local/domain/0/device-model/%d/inject-sci" domid

let xenclient_specific ~xs info domid =
  (match info.power_mgmt with 
    | Some i -> begin
	try 
	  if (Unix.stat "/proc/acpi/battery").Unix.st_kind == Unix.S_DIR then
	    xs.Xs.write (power_mgmt_path domid) (string_of_int i);
	with _ -> ()
      end
    | None -> ());
  
  (match info.oem_features with 
    | Some i -> xs.Xs.write (oem_features_path domid) (string_of_int i);
    | None -> ());
  
  (match info.inject_sci with 
    | Some i -> xs.Xs.write (inject_sci_path domid) (string_of_int i)
    | None -> ());
  
  let sound_options =
    match info.sound with
      | None        -> []
      | Some device -> [ "-soundhw"; device ]
  in

  ["-videoram"; string_of_int info.video_mib;
   "-M"; (if info.hvm then "xenfv" else "xenpv")] 
  @ sound_options
   
let signal ~xs ~domid ?wait_for ?param cmd =
	let cmdpath = device_model_path domid in
	Xs.transaction xs (fun t ->
		t.Xst.write (cmdpath ^ "/command") cmd;
		match param with
		| None -> ()
		| Some param -> t.Xst.write (cmdpath ^ "/parameter") param
	);
	match wait_for with
	| Some state ->
		let pw = cmdpath ^ "/state" in
               (* MTC: The default timeout for this operation was 20mins, which is
                * way too long for our software to recover successfully.
                * Talk to Citrix about this
                *) 
		Watch.wait_for ~xs ~timeout:30. (Watch.value_to_become pw state)
	| None -> ()

let get_state ~xs domid =
	let cmdpath = device_model_path domid in
	let statepath = cmdpath ^ "/state" in
	try Some (xs.Xs.read statepath)
	with _ -> None

(* Returns the allocated vnc port number *)
let __start ~xs ~dmpath ~restore ?(timeout = !Xapi_globs.qemu_dm_ready_timeout) info domid =
	debug "Device.Dm.start domid=%d" domid;
	let usb' =
		if info.usb = [] then
			[]
		else
			("-usb" :: (List.concat (List.map (fun device ->
					   [ "-usbdevice"; device ]) info.usb))) in
	(* Sort the VIF devices by devid *)
	let nics = List.stable_sort (fun (_,_,a) (_,_,b) -> compare a b) info.nics in
	if List.length nics > max_emulated_nics then debug "Limiting the number of emulated NICs to %d" max_emulated_nics;
	(* Take the first 'max_emulated_nics' elements from the list. *)
	let take xs n  = List.map snd (List.filter (fun (x, _) -> x < n) (List.combine (Range.to_list (Range.make 0 (List.length xs))) xs)) in
	let nics = take nics max_emulated_nics in
	
	(* qemu need a different id for every vlan, or things get very bad *)
	let nics' =
		if List.length nics > 0 then
	let vlan_id = ref 0 in
			List.map (fun (mac, bridge, devid) ->
		let r = [
		"-net"; sprintf "nic,vlan=%d,macaddr=%s,model=rtl8139" !vlan_id mac;
		"-net"; sprintf "tap,vlan=%d,bridge=%s,ifname=%s" !vlan_id bridge (Printf.sprintf "tap%d.%d" domid devid)] in
		incr vlan_id;
		r
			) nics
		else [["-net"; "none"]] in

	let disks' = List.map (fun (index, file, media) -> [
		"-drive"; sprintf "file=%s,if=ide,index=%d,media=%s" file index (string_of_media media)
	]) info.disks in

	let restorefile = sprintf qemu_restore_path domid in
	let vga_type_opts x = 
	  match x with
	    | Std_vga -> ["-std-vga"]
	    | Cirrus -> []
	in
	let dom0_input_opts x =
	  (maybe_with_default [] (fun i -> ["-dom0-input"; string_of_int i]) x)
	in
	let disp_options, wait_for_port =
		match info.disp with
		| NONE -> 
		    ([], false)
		| Passthrough dom0_input -> 
		    let vga_type_opts = ["-vga-passthrough"] in
		    let dom0_input_opts = dom0_input_opts dom0_input in
		    (vga_type_opts @ dom0_input_opts), false		
		| SDL (opts,x11name) ->
		    ( [], false)
		| VNC (disp_intf, auto, port, keymap) ->
		    let vga_type_opts = vga_type_opts disp_intf in
		    let vnc_opts = 
		      if auto
		      then [ "-vncunused"; "-k"; keymap ]
		      else [ "-vnc"; string_of_int port; "-k"; keymap ]
		    in
		    (vga_type_opts @ vnc_opts), true
		| Intel (opt,dom0_input) -> 
		    let vga_type_opts = vga_type_opts opt in
		    let dom0_input_opts = dom0_input_opts dom0_input in
		    (["-intel"] @ vga_type_opts @ dom0_input_opts), false
	in

	let xenclient_specific_options = xenclient_specific ~xs info domid in

	let l = [ string_of_int domid; (* absorbed by qemu-dm-wrapper *)
		  (* everything else goes straight through to qemu-dm: *)
		  "-d"; string_of_int domid;
		  "-m"; Int64.to_string (Int64.div info.memory 1024L);
		  "-boot"; info.boot;
		  "-serial"; info.serial;
		  "-vcpus"; string_of_int info.vcpus; ]
		@ disp_options @ usb' @ List.concat nics' @ List.concat disks'
	   @ (if info.acpi then [ "-acpi" ] else [])
	   @ (if restore then [ "-loadvm"; restorefile ] else [])
	   @ (List.fold_left (fun l pci -> "-pciemulation" :: pci :: l) [] (List.rev info.pci_emulations))
	   @ (if info.pci_passthrough then ["-priv"] else [])
	   @ xenclient_specific_options
	   @ (List.fold_left (fun l (k, v) -> ("-" ^ k) :: (match v with None -> l | Some v -> v :: l)) [] info.extras)
	   @ [ "-monitor"; "pty"; "-vnc"; "127.0.0.1:1" ]
		in
	(* Execute qemu-dm-wrapper, forwarding stdout to the syslog, with the key "qemu-dm-<domid>" *)
	let syslog_stdout = Forkhelpers.Syslog_WithKey (Printf.sprintf "qemu-dm-%d" domid) in
	let pid = Forkhelpers.safe_close_and_exec None None None [] ~syslog_stdout dmpath l in

        debug "qemu-dm: should be running in the background (stdout redirected to syslog)";

	(* There are two common-cases:
	   1. (in development) the qemu process may crash
	   2. (in production) We know qemu is ready (and the domain may be unpaused) when
	      device-misc/dm-ready is set in the store. See xs-xen.pq.hg:hvm-late-unpause *)

    let dm_ready = Printf.sprintf "/local/domain/0/device-model/%d/state" domid in
	let qemu_pid = Forkhelpers.getpid pid in
	debug "qemu-dm: pid = %d. Waiting for %s" qemu_pid dm_ready;
	(* We can't block for both a xenstore key and a process disappearing so we
	   block for 5s at a time *)
	begin
		let finished = ref false in
		let start = Unix.gettimeofday () in
		while Unix.gettimeofday () -. start < timeout && not !finished do
			try
			  let state = Watch.wait_for ~xs ~timeout:5. (Watch.value_to_appear dm_ready) in
				if state = "running" 
				then finished := true
				else raise (Ioemu_failed (Printf.sprintf "qemu-dm state not running (%s)" state))
			with Watch.Timeout _ ->
				begin match Forkhelpers.waitpid_nohang pid with
					| 0, Unix.WEXITED 0 -> () (* still running *)
					| _, Unix.WEXITED n ->
						error "qemu-dm: unexpected exit with code: %d" n;
						raise (Ioemu_failed "qemu-dm exitted unexpectedly")
					| _, (Unix.WSIGNALED n | Unix.WSTOPPED n) ->
						error "qemu-dm: unexpected signal: %d" n;
						raise (Ioemu_failed "qemu-dm exitted unexpectedly")
				end
		done
	end;
		
	(* At this point we expect qemu to outlive us; we will never call waitpid *)	
	Forkhelpers.dontwaitpid pid

let start ~xs ~dmpath ?timeout info domid = __start ~xs ~restore:false ~dmpath ?timeout info domid
let restore ~xs ~dmpath ?timeout info domid = __start ~xs ~restore:true ~dmpath ?timeout info domid

(* suspend/resume is a done by sending signals to qemu *)
let suspend ~xs domid =
	signal ~xs ~domid "save" ~wait_for:"paused"
let resume ~xs domid =
	signal ~xs ~domid "continue" ~wait_for:"running"

(* Called by every domain destroy, even non-HVM *)
let stop ~xs domid  =
	let qemu_pid_path = qemu_pid_path domid in
	match (pid ~xs domid) with
		| None -> () (* nothing to do *)
		| Some qemu_pid ->
			debug "qemu-dm: stopping qemu-dm with SIGTERM (domid = %d)" domid;

			let open Generic in
			best_effort "killing qemu-dm"
				(fun () -> really_kill qemu_pid);
			best_effort "removing qemu-pid from xenstore"
				(fun () -> xs.Xs.rm qemu_pid_path);
			(* best effort to delete the qemu chroot dir; we deliberately want this to fail if the dir is not empty cos it may contain
			   core files that bugtool will pick up; the xapi init script cleans out this directory with "rm -rf" on boot *)
			best_effort "removing core files from /var/xen/qemu"
				(fun () -> Unix.rmdir ("/var/xen/qemu/"^(string_of_int qemu_pid)));
			best_effort "removing device model path from xenstore"
				(fun () -> xs.Xs.rm (device_model_path domid))

end

let get_vnc_port ~xs domid = 
	(* Check whether a qemu exists for this domain *)
	let qemu_exists = Dm.is_qemu_running ~xs domid in
	if qemu_exists
	then Dm.get_vnc_port ~xs domid
	else PV_Vnc.get_vnc_port ~xs domid

let get_tc_port ~xs domid = 
	(* Check whether a qemu exists for this domain *)
	let qemu_exists = Dm.is_qemu_running ~xs domid in
	if qemu_exists
	then Dm.get_tc_port ~xs domid
	else PV_Vnc.get_tc_port ~xs domid


