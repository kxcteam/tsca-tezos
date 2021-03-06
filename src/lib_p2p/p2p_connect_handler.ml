(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(*                                                                           *)
(* Permission is hereby granted, free of charge, to any person obtaining a   *)
(* copy of this software and associated documentation files (the "Software"),*)
(* to deal in the Software without restriction, including without limitation *)
(* the rights to use, copy, modify, merge, publish, distribute, sublicense,  *)
(* and/or sell copies of the Software, and to permit persons to whom the     *)
(* Software is furnished to do so, subject to the following conditions:      *)
(*                                                                           *)
(* The above copyright notice and this permission notice shall be included   *)
(* in all copies or substantial portions of the Software.                    *)
(*                                                                           *)
(* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR*)
(* IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,  *)
(* FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL   *)
(* THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER*)
(* LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING   *)
(* FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER       *)
(* DEALINGS IN THE SOFTWARE.                                                 *)
(*                                                                           *)
(*****************************************************************************)

module Events = struct
  include Internal_event.Simple

  let section = ["p2p"; "connect_handler"]

  let disconnected =
    declare_2
      ~section
      ~name:"disconnected"
      ~msg:"Disconnected: {peer} ({point})"
      ~level:Debug
      ("peer", P2p_peer.Id.encoding)
      ("point", P2p_connection.Id.encoding)

  let peer_rejected =
    declare_0
      ~section
      ~name:"peer_rejected"
      ~msg:"[private node] incoming connection from untrusted peer rejected!"
      ~level:Notice
      ()

  let authenticate =
    declare_3
      ~section
      ~name:"authenticate"
      ~msg:"authenticate: {point} {type} -> {state}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("type", Data_encoding.(option string))
      ("state", Data_encoding.(option string))

  let authenticate_status =
    declare_3
      ~section
      ~name:"authenticate_status"
      ~msg:"authenticate: {point} {type} -> {peer}"
      ~level:Debug
      ("type", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)

  let authenticate_error =
    declare_2
      ~section
      ~name:"authentication_error"
      ~msg:"authenticate: {point} {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

  let connection_rejected_by_peers =
    declare_3
      ~section
      ~name:"connection_rejected_by_peers"
      ~msg:
        "Connection to {point} rejected by peer. Reason {reason}. Peer list \
         received: {points}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("reason", P2p_rejection.encoding)
      ("points", Data_encoding.list P2p_point.Id.encoding)

  let connection_error =
    declare_2
      ~section
      ~name:"connection_error"
      ~msg:"Connection to {point} rejected by peer : {errors}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

  let connect_status =
    declare_2
      ~section
      ~name:"connect_status"
      ~msg:"connect: {point} {state}"
      ~level:Debug
      ("state", Data_encoding.string)
      ("point", P2p_point.Id.encoding)

  let connect_error =
    declare_3
      ~section
      ~name:"connect_error"
      ~msg:"connect: {point} {state} : {errors}"
      ~level:Debug
      ("state", Data_encoding.string)
      ("point", P2p_point.Id.encoding)
      ("errors", Error_monad.trace_encoding)

  let authenticate_reject_protocol_mismatch =
    declare_8
      ~section
      ~name:"authenticate_reject_protocol_mismatch"
      ~msg:"No common protocol with {peer}"
      ~level:Debug
      ("point", P2p_point.Id.encoding)
      ("peer", P2p_peer.Id.encoding)
      ("local_chain", Distributed_db_version.Name.encoding)
      ("remote_chain", Distributed_db_version.Name.encoding)
      ("local_db_versions", Data_encoding.list Distributed_db_version.encoding)
      ("remote_db_version", Distributed_db_version.encoding)
      ("local_p2p_version", Data_encoding.list P2p_version.encoding)
      ("remote_p2p_version", P2p_version.encoding)
end

type config = {
  incoming_app_message_queue_size : int option;
  private_mode : bool;
  min_connections : int;
  max_connections : int;
  max_incoming_connections : int;
  incoming_message_queue_size : int option;
  outgoing_message_queue_size : int option;
  binary_chunks_size : int option;
  identity : P2p_identity.t;
  connection_timeout : Time.System.Span.t;
  authentication_timeout : Time.System.Span.t;
  greylisting_config : P2p_point_state.Info.greylisting_config;
  proof_of_work_target : Crypto_box.target;
  listening_port : P2p_addr.port option;
}

type ('msg, 'peer_meta, 'conn_meta) t = {
  config : config;
  pool : ('msg, 'peer_meta, 'conn_meta) P2p_pool.t;
  log : P2p_connection.P2p_event.t -> unit;
  triggers : P2p_trigger.t;
  io_sched : P2p_io_scheduler.t;
  announced_version : Network_version.t;
  conn_meta_config : 'conn_meta P2p_params.conn_meta_config;
  message_config : 'msg P2p_params.message_config;
  custom_p2p_versions : P2p_version.t list;
  encoding : 'msg P2p_message.t Data_encoding.t;
  incoming : Lwt_canceler.t P2p_point.Table.t;
  mutable new_connection_hook :
    (P2p_peer.Id.t -> ('msg, 'peer_meta, 'conn_meta) P2p_conn.t -> unit) list;
  answerer : 'msg P2p_answerer.t Lazy.t;
}

let create ?(p2p_versions = P2p_version.supported) config pool message_config
    conn_meta_config io_sched triggers ~log ~answerer =
  {
    config;
    conn_meta_config;
    message_config;
    announced_version =
      Network_version.announced
        ~chain_name:message_config.P2p_params.chain_name
        ~distributed_db_versions:
          message_config.P2p_params.distributed_db_versions
        ~p2p_versions;
    custom_p2p_versions = p2p_versions;
    incoming = P2p_point.Table.create 53;
    io_sched;
    encoding = P2p_message.encoding message_config.P2p_params.encoding;
    triggers;
    new_connection_hook = [];
    log;
    pool;
    answerer;
  }

let config t = t.config

let create_connection t p2p_conn id_point point_info peer_info
    negotiated_version =
  let peer_id = P2p_peer_state.Info.peer_id peer_info in
  let canceler = Lwt_canceler.create () in
  let size =
    Option.map t.config.incoming_app_message_queue_size ~f:(fun qs ->
        ( qs,
          fun (size, _) ->
            (Sys.word_size / 8 * 11) + size + Lwt_pipe.push_overhead ))
  in
  let messages = Lwt_pipe.create ?size () in
  let conn =
    P2p_conn.create
      p2p_conn
      point_info
      peer_info
      messages
      canceler
      (Lazy.force t.answerer)
      negotiated_version
  in
  let conn_meta = P2p_socket.remote_metadata p2p_conn in
  Option.iter point_info ~f:(fun point_info ->
      let point = P2p_point_state.Info.point point_info in
      P2p_point_state.set_running point_info peer_id conn ;
      P2p_pool.Points.add_connected t.pool point point_info) ;
  t.log (Connection_established (id_point, peer_id)) ;
  P2p_peer_state.set_running peer_info id_point conn conn_meta ;
  P2p_pool.Peers.add_connected t.pool peer_id peer_info ;
  P2p_trigger.broadcast_new_connection t.triggers ;
  Lwt_canceler.on_cancel canceler (fun () ->
      Events.(emit disconnected) (peer_id, id_point)
      >>= fun () ->
      Option.iter
        ~f:(P2p_point_state.set_disconnected t.config.greylisting_config)
        point_info ;
      t.log (Disconnection peer_id) ;
      P2p_peer_state.set_disconnected peer_info ;
      Option.iter point_info ~f:(fun point_info ->
          P2p_pool.Points.remove_connected t.pool point_info) ;
      P2p_pool.Peers.remove_connected t.pool peer_id ;
      if t.config.max_connections <= P2p_pool.active_connections t.pool then (
        P2p_trigger.broadcast_too_many_connections t.triggers ;
        t.log Too_many_connections ) ;
      Lwt_pipe.close messages ;
      P2p_conn.close conn) ;
  List.iter (fun f -> f peer_id conn) t.new_connection_hook ;
  if P2p_pool.active_connections t.pool < t.config.min_connections then (
    P2p_trigger.broadcast_too_few_connections t.triggers ;
    t.log Too_few_connections ) ;
  conn

let is_acceptable t connection_point_info peer_info incoming version =
  (* Private mode only accept trusted *)
  let unexpected =
    t.config.private_mode
    && (not
          (Option.unopt_map
             ~default:false
             ~f:P2p_point_state.Info.trusted
             connection_point_info))
    && not (P2p_peer_state.Info.trusted peer_info)
  in
  if unexpected then (
    Lwt_utils.dont_wait
      (fun exc ->
        Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc))
      (fun () -> Events.(emit peer_rejected) ()) ;
    error P2p_errors.Private_mode )
  else
    (* checking if point is acceptable *)
    Option.unopt_map
      connection_point_info
      ~default:(ok version)
      ~f:(fun connection_point_info ->
        match P2p_point_state.get connection_point_info with
        | Accepted _ | Running _ ->
            P2p_rejection.(rejecting Already_connected)
        | Requested _ when incoming ->
            P2p_rejection.(rejecting Already_connected)
        | Requested _ | Disconnected ->
            ok version)
    >>? fun version ->
    (* Point is acceptable, checking if peer is. *)
    match P2p_peer_state.get peer_info with
    | Accepted _
    (* TODO: in some circumstances cancel and accept... *)
    | Running _ ->
        P2p_rejection.(rejecting Already_connected)
    (* All right, welcome ! *)
    | Disconnected ->
        ok version

let may_register_my_id_point pool = function
  | [P2p_errors.Myself (addr, Some port)] ->
      P2p_pool.add_to_id_points pool (addr, port)
  | _ ->
      ()

let raw_authenticate t ?point_info canceler fd point =
  let incoming = point_info = None in
  let incoming_opt = if incoming then Some "incoming" else None in
  Events.(emit authenticate) (point, incoming_opt, None)
  >>= fun () ->
  protect
    ~canceler
    (fun () ->
      P2p_socket.authenticate
        ~canceler
        ~proof_of_work_target:t.config.proof_of_work_target
        ~incoming
        fd
        point
        ?listening_port:t.config.listening_port
        t.config.identity
        t.announced_version
        t.conn_meta_config)
    ~on_error:(fun err ->
      ( match err with
      | [Canceled] ->
          (* Currently only on time out *)
          Events.(emit authenticate) (point, incoming_opt, Some "canceled")
      | err ->
          (* Authentication incorrect! Temp ban the offending points/peers *)
          List.iter
            (function
              | P2p_errors.Not_enough_proof_of_work _
              | P2p_errors.Invalid_auth
              | P2p_errors.Decipher_error
              | P2p_errors.Invalid_message_size
              | P2p_errors.Encoding_error
              | P2p_errors.Decoding_error
              | P2p_errors.Invalid_chunks_size _ ->
                  P2p_pool.greylist_addr t.pool (fst point)
              | _ ->
                  ())
            err ;
          Events.(emit authenticate) (point, incoming_opt, Some "failed") )
      >>= fun () ->
      Events.(emit authenticate_error) (point, err)
      >>= fun () ->
      may_register_my_id_point t.pool err ;
      t.log (Authentication_failed point) ;
      if incoming then P2p_point.Table.remove t.incoming point
      else
        Option.iter
          ~f:(P2p_point_state.set_disconnected t.config.greylisting_config)
          point_info ;
      Lwt.return_error err)
  >>=? fun (info, auth_fd) ->
  (* Authentication correct! *)
  Events.(emit authenticate_status) ("auth", point, info.peer_id)
  >>= fun () ->
  fail_when
    (P2p_pool.Peers.banned t.pool info.peer_id)
    (P2p_errors.Peer_banned info.peer_id)
  >>=? fun () ->
  let remote_point_info =
    match info.id_point with
    | (addr, Some port) ->
        P2p_pool.register_new_point t.pool (addr, port)
    | _ ->
        None
  in
  let connection_point_info =
    match (point_info, remote_point_info) with
    | (None, None) ->
        None
    | ((Some _ as point_info), _) | (_, (Some _ as point_info)) ->
        point_info
  in
  let peer_info = P2p_pool.register_peer t.pool info.peer_id in
  (* [acceptable] is either Ok with a network version, or a Rejecting
     error with a motive  *)
  let acceptable =
    Network_version.select
      ~chain_name:t.message_config.chain_name
      ~distributed_db_versions:t.message_config.distributed_db_versions
      ~p2p_versions:t.custom_p2p_versions
      info.announced_version
    >>? fun version ->
    (* we have a common version, checking if there is an available slot *)
    ( if
      (* randomly allow one additional incoming connection *)
      t.config.max_connections + Random.int 2
      > P2p_pool.active_connections t.pool
    then ok version
    else P2p_rejection.(rejecting Too_many_connections) )
    >>? fun version ->
    (* we have a slot, checking if point and peer are acceptable *)
    is_acceptable t connection_point_info peer_info incoming version
  in
  (* To Verify : the thread must ? not be interrupted between
     point removal from incoming and point registration into
     active connection to prevent flooding attack.
     incoming_connections + active_connection must reflect/dominate
     the actual number of ongoing connections.
     On the other hand, if we wait too long for Ack, we will reject
     incoming connections, thus giving an entry point for dos attack
     by giving late Nack.
  *)
  if incoming then P2p_point.Table.remove t.incoming point ;
  Option.iter connection_point_info ~f:(fun point_info ->
      (* set the point to private or not, depending on the [info] gathered
           during authentication *)
      P2p_point_state.set_private point_info info.private_node) ;
  match acceptable with
  | Error
      (P2p_rejection.Rejecting
         { motive =
             ( Too_many_connections
             | Unknown_chain_name
             | Deprecated_p2p_version
             | Deprecated_distributed_db_version
             | Already_connected ) as motive }
      :: _) -> (
      (* non-acceptable point, kicking it. *)
      t.log (Rejecting_request (point, info.id_point, info.peer_id)) ;
      Events.(emit authenticate_status ("kick", point, info.peer_id))
      >>= fun () ->
      P2p_pool.list_known_points ~ignore_private:true t.pool
      >>= fun point_list ->
      P2p_socket.kick auth_fd motive point_list
      >>= fun () ->
      if not incoming then
        Option.iter
          ~f:
            (P2p_point_state.set_disconnected
               ~requested:true
               t.config.greylisting_config)
          point_info ;
      match motive with
      | Unknown_chain_name
      | Deprecated_distributed_db_version
      | Deprecated_p2p_version ->
          Events.(emit authenticate_reject_protocol_mismatch)
            ( point,
              info.peer_id,
              t.message_config.chain_name,
              info.announced_version.chain_name,
              t.message_config.distributed_db_versions,
              info.announced_version.distributed_db_version,
              t.custom_p2p_versions,
              info.announced_version.p2p_version )
          >>= fun () ->
          fail
            (P2p_errors.Rejected_no_common_protocol
               {announced = info.announced_version})
      | _ ->
          fail (P2p_errors.Rejected {peer = info.peer_id; motive}) )
  | Error errs as err ->
      Events.(emit authenticate_status) ("reject", point, info.peer_id)
      >>= fun () ->
      Events.(emit authenticate_error) (point, errs)
      >>= fun () -> Lwt.return err
  | Ok version ->
      t.log (Accepting_request (point, info.id_point, info.peer_id)) ;
      Option.iter connection_point_info ~f:(fun point_info ->
          P2p_point_state.set_accepted point_info info.peer_id canceler) ;
      P2p_peer_state.set_accepted peer_info info.id_point canceler ;
      Events.(emit authenticate_status) ("accept", point, info.peer_id)
      >>= fun () ->
      protect
        ~canceler
        (fun () ->
          P2p_socket.accept
            ?incoming_message_queue_size:t.config.incoming_message_queue_size
            ?outgoing_message_queue_size:t.config.outgoing_message_queue_size
            ?binary_chunks_size:t.config.binary_chunks_size
            ~canceler
            auth_fd
            t.encoding
          >>=? fun conn ->
          Events.(emit authenticate_status) ("connected", point, info.peer_id)
          >>= fun () -> return conn)
        ~on_error:(fun err ->
          if incoming then
            t.log
              (Request_rejected (point, Some (info.id_point, info.peer_id))) ;
          ( match err with
          | P2p_errors.Rejected_by_nack
              {alternative_points = Some points; motive}
            :: _ ->
              Events.(emit connection_rejected_by_peers) (point, motive, points)
              >>= fun () ->
              P2p_pool.register_list_of_new_points
                ~medium:"Nack"
                ~source:info.peer_id
                t.pool
                points ;
              Lwt.return_unit
          | _ ->
              Events.(emit connection_error) (point, err)
              >>= fun () -> Lwt.return_unit )
          >>= fun () ->
          Events.(emit authenticate_status) ("rejected", point, info.peer_id)
          >>= fun () ->
          Option.iter
            connection_point_info
            ~f:(P2p_point_state.set_disconnected t.config.greylisting_config) ;
          P2p_peer_state.set_disconnected peer_info ;
          Lwt.return_error err)
      >>=? fun conn ->
      let id_point =
        match
          (info.id_point, Option.map ~f:P2p_point_state.Info.point point_info)
        with
        | ((addr, _), Some (_, port)) ->
            (addr, Some port)
        | (id_point, None) ->
            id_point
      in
      return
        (create_connection
           t
           conn
           id_point
           connection_point_info
           peer_info
           version)

let authenticate t ?point_info canceler fd point =
  let fd = P2p_io_scheduler.register t.io_sched fd in
  raw_authenticate t ?point_info canceler fd point
  >>= function
  | Ok connection ->
      return connection
  | Error
      (P2p_errors.Rejected {motive = P2p_rejection.Unknown_chain_name; _} :: _)
    as err ->
      (* We don't register point that belong to another network.
        They are useless, and we don't want to advertize them.
        They are not greylisted as their might be node from our
        network on the same IP.
      *)
      P2p_pool.unregister_point t.pool point ;
      P2p_io_scheduler.close fd >>=? fun () -> Lwt.return err
  | Error _ as err ->
      P2p_io_scheduler.close fd >>=? fun () -> Lwt.return err

let accept t fd point =
  t.log (Incoming_connection point) ;
  if
    t.config.max_incoming_connections <= P2p_point.Table.length t.incoming
    (* silently ignore banned points *)
    || P2p_pool.Points.banned t.pool point
  then
    Lwt_utils.dont_wait
      (fun exc ->
        Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc) ;
        Lwt_exit.exit 1)
      (fun () -> P2p_fd.close fd)
  else
    let canceler = Lwt_canceler.create () in
    P2p_point.Table.add t.incoming point canceler ;
    Lwt_utils.dont_wait
      (fun exc ->
        Format.eprintf "Uncaught exception: %s\n%!" (Printexc.to_string exc) ;
        Lwt_exit.exit 1)
      (fun () ->
        with_timeout
          ~canceler
          (Systime_os.sleep t.config.authentication_timeout)
          (fun canceler -> authenticate t canceler fd point)
        >>= fun _ -> Lwt.return_unit)

let fail_unless_disconnected_point point_info =
  match P2p_point_state.get point_info with
  | Disconnected ->
      return_unit
  | Requested _ | Accepted _ ->
      fail P2p_errors.Pending_connection
  | Running _ ->
      fail P2p_errors.Connected

let connect ?timeout t point =
  fail_when
    (P2p_pool.Points.banned t.pool point)
    (P2p_errors.Point_banned point)
  >>=? fun () ->
  let timeout = Option.unopt ~default:t.config.connection_timeout timeout in
  fail_unless
    (P2p_pool.active_connections t.pool <= t.config.max_connections)
    P2p_errors.Too_many_connections
  >>=? fun () ->
  let canceler = Lwt_canceler.create () in
  with_timeout ~canceler (Systime_os.sleep timeout) (fun canceler ->
      let point_info = P2p_pool.register_point t.pool point in
      let ((addr, port) as point) = P2p_point_state.Info.point point_info in
      fail_unless
        ((not t.config.private_mode) || P2p_point_state.Info.trusted point_info)
        P2p_errors.Private_mode
      >>=? fun () ->
      fail_unless_disconnected_point point_info
      >>=? fun () ->
      P2p_point_state.set_requested point_info canceler ;
      P2p_fd.socket PF_INET6 SOCK_STREAM 0
      >>= fun fd ->
      let uaddr =
        Lwt_unix.ADDR_INET (Ipaddr_unix.V6.to_inet_addr addr, port)
      in
      Events.(emit connect_status) ("start", point)
      >>= fun () ->
      protect
        ~canceler
        (fun () ->
          t.log (Outgoing_connection point) ;
          P2p_fd.connect fd uaddr >>= fun () -> return_unit)
        ~on_error:(fun err ->
          Events.(emit connect_error) ("disconnect", point, err)
          >>= fun () ->
          P2p_point_state.set_disconnected
            t.config.greylisting_config
            point_info ;
          P2p_fd.close fd
          >>= fun () ->
          match err with
          | [Exn (Unix.Unix_error (Unix.ECONNREFUSED, _, _))] ->
              fail P2p_errors.Connection_refused
          | err ->
              Lwt.return_error err)
      >>=? fun () ->
      Events.(emit connect_status) ("authenticate", point)
      >>= fun () -> authenticate t ~point_info canceler fd point)

let stat t = P2p_io_scheduler.global_stat t.io_sched

let on_new_connection t f = t.new_connection_hook <- f :: t.new_connection_hook

let destroy t =
  P2p_point.Table.fold
    (fun _point canceler acc -> Lwt_canceler.cancel canceler >>= fun () -> acc)
    t.incoming
    Lwt.return_unit
