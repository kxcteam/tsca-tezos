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

(* ------------------------------------------------------------------------- *)
(* Mockup protocol parameters *)

type mockup_protocol_parameters = {
  initial_timestamp : Time.Protocol.t;
  bootstrap_accounts : Protocol.Parameters_repr.bootstrap_account list;
  bootstrap_contracts : Protocol.Parameters_repr.bootstrap_contract list;
  constants : Protocol.Constants_repr.parametric;
}

type protocol_constants_overrides = {
  hard_gas_limit_per_operation : Z.t option;
  hard_gas_limit_per_block : Z.t option;
  hard_storage_limit_per_operation : Z.t option;
  cost_per_byte : Protocol.Tez_repr.t option;
}

type parsed_account_repr = {
  name : string;
  sk_uri : Client_keys.sk_uri;
  amount : Protocol.Tez_repr.t;
}

let bootstrap_account_encoding :
    Protocol.Parameters_repr.bootstrap_account Data_encoding.t =
  let open Data_encoding in
  let open Protocol.Parameters_repr in
  conv
    (fun {public_key_hash; public_key; amount} ->
      (public_key_hash, public_key, amount))
    (fun (public_key_hash, public_key, amount) ->
      {public_key_hash; public_key; amount})
    (obj3
       (req "public_key_hash" Signature.Public_key_hash.encoding)
       (opt "public_key" Signature.Public_key.encoding)
       (req "amount" Protocol.Tez_repr.encoding))

let bootstrap_contract_encoding :
    Protocol.Parameters_repr.bootstrap_contract Data_encoding.t =
  let open Data_encoding in
  let open Protocol.Parameters_repr in
  conv
    (fun {delegate; amount; script} -> (delegate, amount, script))
    (fun (delegate, amount, script) -> {delegate; amount; script})
    (obj3
       (req "delegate" Signature.Public_key_hash.encoding)
       (req "amount" Protocol.Tez_repr.encoding)
       (req "script" Protocol.Script_repr.encoding))

let mockup_protocol_parameters_encoding :
    mockup_protocol_parameters Data_encoding.t =
  let open Data_encoding in
  conv
    (fun p ->
      ( p.initial_timestamp,
        p.bootstrap_accounts,
        p.bootstrap_contracts,
        p.constants ))
    (fun (initial_timestamp, bootstrap_accounts, bootstrap_contracts, constants)
         ->
      {initial_timestamp; bootstrap_accounts; bootstrap_contracts; constants})
    (obj4
       (req "initial_timestamp" Time.Protocol.encoding)
       (req "bootstrap_accounts" (list bootstrap_account_encoding))
       (req "bootstrap_contracts" (list bootstrap_contract_encoding))
       (req "constants" Protocol.Constants_repr.parametric_encoding))

let protocol_constants_overrides_encoding =
  let open Data_encoding in
  conv
    (fun p ->
      ( p.hard_gas_limit_per_operation,
        p.hard_gas_limit_per_block,
        p.hard_storage_limit_per_operation,
        p.cost_per_byte ))
    (fun ( hard_gas_limit_per_operation,
           hard_gas_limit_per_block,
           hard_storage_limit_per_operation,
           cost_per_byte ) ->
      {
        hard_gas_limit_per_operation;
        hard_gas_limit_per_block;
        hard_storage_limit_per_operation;
        cost_per_byte;
      })
    (obj4
       (opt "hard_gas_limit_per_operation" z)
       (opt "hard_gas_limit_per_block" z)
       (opt "hard_storage_limit_per_operation" z)
       (opt "cost_per_byte" Protocol.Tez_repr.encoding))

let default_mockup_parameters : mockup_protocol_parameters =
  let parameters =
    Default_parameters.parameters_of_constants
      Default_parameters.constants_sandbox
  in
  {
    initial_timestamp = Time.Protocol.epoch;
    bootstrap_accounts = parameters.bootstrap_accounts;
    bootstrap_contracts = parameters.bootstrap_contracts;
    constants = parameters.constants;
  }

let protocol_constants_no_overrides =
  {
    hard_gas_limit_per_operation = None;
    hard_gas_limit_per_block = None;
    hard_storage_limit_per_operation = None;
    cost_per_byte = None;
  }

let apply_protocol_overrides (o : protocol_constants_overrides)
    (c : Protocol.Constants_repr.parametric) =
  {
    c with
    hard_gas_limit_per_operation =
      Option.unopt
        ~default:c.hard_gas_limit_per_operation
        o.hard_gas_limit_per_operation;
    hard_gas_limit_per_block =
      Option.unopt
        ~default:c.hard_gas_limit_per_block
        o.hard_gas_limit_per_block;
    hard_storage_limit_per_operation =
      Option.unopt
        ~default:c.hard_storage_limit_per_operation
        o.hard_storage_limit_per_operation;
    cost_per_byte = Option.unopt ~default:c.cost_per_byte o.cost_per_byte;
  }

let parsed_account_repr_encoding =
  let open Data_encoding in
  conv
    (fun p -> (p.name, (p.sk_uri :> Uri.t), p.amount))
    (fun (name, sk_uri, amount) ->
      {name; sk_uri = Client_keys.make_sk_uri sk_uri; amount})
    (obj3
       (req "name" string)
       (req "sk_uri" RPC_encoding.uri_encoding)
       (req "amount" Protocol.Tez_repr.encoding))

let parsed_accounts_reprs = Data_encoding.list parsed_account_repr_encoding

let to_bootstrap_account repr =
  Tezos_client_base.Client_keys.neuterize repr.sk_uri
  >>=? fun pk_uri ->
  Tezos_client_base.Client_keys.public_key pk_uri
  >>=? fun public_key ->
  let public_key_hash = Signature.Public_key.hash public_key in
  return
    Protocol.Parameters_repr.
      {public_key_hash; public_key = Some public_key; amount = repr.amount}

(* ------------------------------------------------------------------------- *)
(* Blocks *)

type block = {
  hash : Block_hash.t;
  header : Protocol.Alpha_context.Block_header.t;
  operations : Protocol.Alpha_context.Operation.packed list;
  context : Protocol.Environment.Context.t;
}

let block_encoding : block Data_encoding.t =
  let open Data_encoding in
  conv
    (fun {hash; header; operations; context} ->
      (hash, header, operations, context))
    (fun (hash, header, operations, context) ->
      {hash; header; operations; context})
    (obj4
       (req "hash" Block_hash.encoding)
       (req "header" Protocol.Alpha_context.Block_header.encoding)
       (req
          "operations"
          (list (dynamic_size Protocol.Alpha_context.Operation.encoding)))
       (req "context" Memory_context.encoding))

module Forge = struct
  let default_proof_of_work_nonce =
    Bytes.create Protocol.Alpha_context.Constants.proof_of_work_nonce_size

  let make_shell ~level ~predecessor ~timestamp ~fitness ~operations_hash =
    Tezos_base.Block_header.
      {
        level;
        predecessor;
        timestamp;
        fitness;
        operations_hash;
        proto_level = 0;
        validation_passes = 0;
        context = Context_hash.zero;
      }
end

(* ------------------------------------------------------------------------- *)
(* RPC context *)

let initial_context (header : Block_header.shell_header)
    (params : mockup_protocol_parameters) =
  let parameters =
    Default_parameters.parameters_of_constants
      ~bootstrap_accounts:params.bootstrap_accounts
      ~bootstrap_contracts:params.bootstrap_contracts
      ~with_commitments:false
      params.constants
  in
  let json = Default_parameters.json_of_parameters parameters in
  let proto_params =
    Data_encoding.Binary.to_bytes_exn Data_encoding.json json
  in
  Tezos_protocol_environment.Context.(
    let empty = Memory_context.empty in
    set empty ["version"] (Bytes.of_string "genesis")
    >>= fun ctxt -> set ctxt ["protocol_parameters"] proto_params)
  >>= fun ctxt ->
  Protocol.Main.init ctxt header
  >|= Protocol.Environment.wrap_error
  >>=? fun {context; _} -> return context

let mem_init :
    parameters:mockup_protocol_parameters ->
    constants_overrides_json:Data_encoding.json option ->
    bootstrap_accounts_json:Data_encoding.json option ->
    Tezos_protocol_environment.rpc_context tzresult Lwt.t =
 fun ~parameters ~constants_overrides_json ~bootstrap_accounts_json ->
  let hash =
    Block_hash.of_b58check_exn
      "BLockGenesisGenesisGenesisGenesisGenesisCCCCCeZiLHU"
  in
  let shell =
    Forge.make_shell
      ~level:0l
      ~predecessor:hash
      ~timestamp:parameters.initial_timestamp
      ~fitness:(Protocol.Fitness_repr.from_int64 0L)
      ~operations_hash:Operation_list_list_hash.zero
  in
  ( match constants_overrides_json with
  | None ->
      return protocol_constants_no_overrides
  | Some json -> (
    match
      Data_encoding.Json.destruct protocol_constants_overrides_encoding json
    with
    | x ->
        return x
    | exception error ->
        failwith
          "cannot read protocol constants overrides: %a"
          (Data_encoding.Json.print_error ?print_unknown:None)
          error ) )
  >>=? fun protocol_overrides ->
  ( match bootstrap_accounts_json with
  | None ->
      return None
  | Some json -> (
    match Data_encoding.Json.destruct parsed_accounts_reprs json with
    | accounts ->
        Tezos_base.TzPervasives.map_s to_bootstrap_account accounts
        >>=? fun r -> return (Some r)
    | exception error ->
        failwith
          "cannot read definitions of bootstrap accounts: %a"
          (Data_encoding.Json.print_error ?print_unknown:None)
          error ) )
  >>=? fun bootstrap_accounts_custom ->
  initial_context
    shell
    {
      parameters with
      bootstrap_accounts =
        Option.unopt
          ~default:parameters.bootstrap_accounts
          bootstrap_accounts_custom;
      constants =
        apply_protocol_overrides protocol_overrides parameters.constants;
    }
  >>=? fun context ->
  return
    {
      Tezos_protocol_environment.block_hash = hash;
      block_header = shell;
      context;
    }

(* ------------------------------------------------------------------------- *)
(* Register mockup *)

let () =
  let open Tezos_mockup_registration.Registration in
  let module M : Mockup_sig = struct
    type parameters = mockup_protocol_parameters

    let parameters_encoding = mockup_protocol_parameters_encoding

    let default_parameters = default_mockup_parameters

    let protocol_hash = Protocol.hash

    module Protocol = Protocol_client_context.Lifted_protocol
    module Block_services = Protocol_client_context.Alpha_block_services

    let directory = Protocol.rpc_services

    let init = mem_init
  end in
  register_mockup_context (module M)
