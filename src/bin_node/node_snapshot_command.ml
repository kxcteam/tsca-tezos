(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2018 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2018 Nomadic Labs. <nomadic@tezcore.com>                    *)
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

open Genesis_chain
open Node_logging

let (//) = Filename.concat
let context_dir data_dir = data_dir // "context"
let store_dir data_dir = data_dir // "store"

let compute_export_limit
    block_store _chain_data_store
    block_header export_rolling =
  let block_hash = Block_header.hash block_header in
  Store.Block.Contents.read
    (block_store, block_hash) >>=? fun block_content ->
  let max_op_ttl = block_content.max_operations_ttl in
  begin
    if not export_rolling then
      return 1l
    else
      return (Int32.(sub block_header.Block_header.shell.level (of_int max_op_ttl)))
  end >>=? fun export_limit ->
  (* never include genesis *)
  return (max 1l export_limit)

let load_pruned_blocks block_store block_header export_limit =
  let cpt = ref 0 in
  let rec load_pruned (bh : Block_header.t) acc limit =
    Tezos_stdlib.Utils.display_progress
      ~refresh_rate:(!cpt, 1_000)
      "Retrieving history: %iK/%iK blocks"
      (!cpt / 1_000)
      ((!cpt + (Int32.to_int bh.shell.level - Int32.to_int limit)) / 1_000);
    incr cpt;
    if bh.shell.level <= limit then
      return acc
    else
      let pbh = bh.shell.predecessor in
      Store.Block.Header.read (block_store, pbh) >>=? fun pbhd ->
      Store.Block.Operations.bindings (block_store, pbh) >>= fun operations ->
      Store.Block.Operation_hashes.bindings (block_store, pbh) >>= fun operation_hashes ->
      let pruned_block = ({
          block_header = pbhd ;
          operations ;
          operation_hashes ;
        } : Context.Pruned_block.t ) in
      load_pruned pbhd (pruned_block :: acc) limit in
  load_pruned block_header [] export_limit >>= fun pruned_blocks ->
  Tezos_stdlib.Utils.display_progress_end () ;
  Lwt.return pruned_blocks

let export ?(export_rolling=false) data_dir filename block =
  let data_dir =
    match data_dir with
    | None -> Node_config_file.default_data_dir
    | Some dir -> dir
  in
  let context_root = context_dir data_dir in
  let store_root = store_dir data_dir in
  let chain_id = Chain_id.of_block_hash genesis.block in
  Store.init store_root >>=? fun store ->
  let chain_store = Store.Chain.get store chain_id in
  let chain_data_store = Store.Chain_data.get chain_store in
  let block_store = Store.Block.get chain_store in
  begin
    match block with
    | Some block_hash ->
        Lwt.return (Block_hash.of_b58check_exn block_hash)
    | None ->
        Store.Chain_data.Current_head.read_exn chain_data_store >>= fun head ->
        Store.Block.Predecessors.read_exn (block_store, head) 6 >>= fun sixteenth_pred ->
        lwt_log_notice "No block hash specified with the `--block` option. Using %a by default (64th predecessor from the current head)"
          Block_hash.pp sixteenth_pred >>= fun () ->
        Lwt.return sixteenth_pred
  end >>= fun block_hash ->
  Store.Block.Header.read_opt (block_store, block_hash) >>=
  begin function
    | None ->
        failwith "Skipping unknown block %a"
          Block_hash.pp block_hash
    | Some block_header ->
        lwt_log_notice "Dumping: %a"
          Block_hash.pp block_hash >>= fun () ->

        (* Get block precessor's block header*)
        Store.Block.Predecessors.read
          (block_store, block_hash) 0 >>=? fun pred_block_hash ->
        Store.Block.Header.read
          (block_store, pred_block_hash) >>=? fun pred_block_header ->

        (* Get operation list*)
        let validations_passes = block_header.shell.validation_passes in
        Error_monad.map_s
          (fun i -> Store.Block.Operations.read (block_store, block_hash) i)
          (0 -- (validations_passes - 1)) >>=? fun operations ->

        compute_export_limit
          block_store
          chain_data_store
          block_header
          export_rolling >>=? fun export_limit ->

        (* Retreive the list of pruned blocks to export *)
        load_pruned_blocks
          block_store
          block_header
          export_limit >>=? fun old_pruned_blocks_rev ->

        let block_data =
          ({block_header = block_header ;
            operations } : Context.Block_data.t ) in
        return (pred_block_header, block_data, List.rev old_pruned_blocks_rev)
  end
  >>=? fun data_to_dump ->
  Store.close store;
  Context.init ~readonly:true context_root
  >>= fun context_index ->
  Context.dump_contexts
    context_index
    [ data_to_dump ]
    ~filename >>=? fun () ->
  lwt_log_notice "Sucessful export (in file %s)" filename >>= fun () ->
  return_unit
(** Main *)

module Term = struct

  type subcommand = Export

  let process subcommand config_file file blocks export_rolling =
    let res =
      match subcommand with
      | Export -> export ~export_rolling config_file file blocks
    in
    match Lwt_main.run res with
    | Ok () -> `Ok ()
    | Error err -> `Error (false, Format.asprintf "%a" pp_print_error err)

  let subcommand_arg =
    let parser = function
      | "export" -> `Ok Export
      | s -> `Error ("invalid argument: " ^ s)
    and printer ppf = function
      | Export -> Format.fprintf ppf "export"
    in
    let open Cmdliner.Arg in
    let doc =
      "Operation to perform. \
       Possible value: $(b,export)." in
    required & pos 0 (some (parser, printer)) None & info [] ~docv:"OPERATION" ~doc

  let file_arg =
    let open Cmdliner.Arg in
    required & pos 1 (some string) None & info [] ~docv:"FILE"

  let blocks =
    let open Cmdliner.Arg in
    let doc ="Block hash of the block to export." in
    value & opt (some string) None & info ~docv:"<block_hash>" ~doc ["block"]

  let export_rolling =
    let open Cmdliner in
    let doc =
      "Force export command to dump a minimal snapshot based on the rolling mode." in
    Arg.(value & flag &
         info ~docs:Node_shared_arg.Manpage.misc_section ~doc ["rolling"])

  let term =
    let open Cmdliner.Term in
    ret (const process $ subcommand_arg
         $ Node_shared_arg.Term.data_dir
         $ file_arg
         $ blocks
         $ export_rolling)

end

module Manpage = struct

  let command_description =
    "The $(b,snapshot) command is meant to export snapshots files."

  let description = [
    `S "DESCRIPTION" ;
    `P (command_description ^ " Several operations are possible: ");
    `P "$(b,export) allows to export a snapshot of the current node state into a file." ;
  ]

  let options = [
    `S "OPTIONS" ;
  ]

  let examples =
    [
      `S "EXAMPLES" ;
      `I ("$(b,Export a snapshot using the rolling mode)",
          "$(mname) snapshot export latest.rolling --rolling") ;
    ]

  let man =
    description @
    options @
    examples @
    Node_shared_arg.Manpage.bugs

  let info =
    Cmdliner.Term.info
      ~doc:"Manage snapshots"
      ~man
      "snapshot"

end

let cmd =
  Term.term, Manpage.info