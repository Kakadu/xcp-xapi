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
(** Controlling the management interface.
 *  @group Networking
 *)
 
(** Block until an IP address appears on the management interface *)
val wait_for_management_ip : unit -> string

(** Called anywhere we suspect dom0's networking (hostname, IP address) has been changed
    underneath us (eg by dhclient) *)
val on_dom0_networking_change : __context:Context.t -> unit

(** Change the interface and IP address on which we listen for management traffic *)
val change_ip : string  -> string -> unit

(** Rebind to the management IP address, useful after reconfiguring the interface *)
val rebind : unit -> unit

(** Stop the server thread listening on the management interface *)
val stop : unit -> unit
