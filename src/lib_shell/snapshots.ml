(*****************************************************************************)
(*                                                                           *)
(* Open Source License                                                       *)
(* Copyright (c) 2019 Dynamic Ledger Solutions, Inc. <contact@tezos.com>     *)
(* Copyright (c) 2019 Nomadic Labs. <nomadic@tezcore.com>                    *)
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

include Tezos_stdlib.Logging.Make(struct let name = "node.snapshots" end)

let (//) = Filename.concat
let context_dir data_dir = data_dir // "context"
let store_dir data_dir = data_dir // "store"

type error += Wrong_snapshot_export of History_mode.t * History_mode.t
type error += Wrong_block_export of
    Block_hash.t * [ `Pruned | `Too_few_predecessors | `Cannot_be_found ]
type error += Inconsistent_imported_block of Block_hash.t * Block_hash.t
type error += Snapshot_import_failure of string
type error += Wrong_reconstrcut_mode
type error += Wrong_protocol_hash of Protocol_hash.t
type error += Inconsistent_operation_hashes of
    (Operation_list_list_hash.t * Operation_list_list_hash.t)

let () = begin
  let open Data_encoding in

  register_error_kind
    `Permanent
    ~id:"WrongSnapshotExport"
    ~title:"Wrong snapshot export"
    ~description:"Snapshot exports is not compatible with the current configuration."
    ~pp:begin fun ppf (src,dst) ->
      Format.fprintf ppf
        "Cannot export a %a snapshot from a %a node."
        History_mode.pp dst History_mode.pp src
    end
    (obj2
       (req "src" History_mode.encoding)
       (req "dst" History_mode.encoding))
    (function Wrong_snapshot_export (src,dst) -> Some (src, dst) | _ -> None)
    (fun (src, dst) -> Wrong_snapshot_export (src, dst)) ;

  let pp_wrong_block_export_error ppf kind =
    let str =
      match kind with
      | `Pruned -> "is pruned"
      | `Too_few_predecessors -> "has not enough predecessors"
      | `Cannot_be_found ->  "cannot be found" in
    Format.fprintf ppf "%s" str in
  let error_kind_encoding =
    string_enum
      [ "pruned", `Pruned ;
        "too_few_predecessors", `Too_few_predecessors ;
        "cannot_be_found", `Cannot_be_found ] in
  register_error_kind
    `Permanent
    ~id:"WrongBlockExport"
    ~title:"Wrong block export"
    ~description:"The block to export in the snapshot is not valid."
    ~pp:(fun ppf (bh,kind) ->
        Format.fprintf ppf
          "Fails to export snapshot as the block with block hash %a %a."
          Block_hash.pp bh pp_wrong_block_export_error kind)
    (obj2
       (req "block_hash" Block_hash.encoding)
       (req "kind" error_kind_encoding))
    (function Wrong_block_export (bh, kind) -> Some (bh, kind) | _ -> None)
    (fun (bh, kind) -> Wrong_block_export (bh, kind)) ;

  register_error_kind
    `Permanent
    ~id:"InconsistentImportedBlock"
    ~title:"Inconsistent imported block"
    ~description:"The imported block is not the expected one."
    ~pp:begin fun ppf (got,exp) ->
      Format.fprintf ppf
        "The block contained in the file is %a instead of %a."
        Block_hash.pp got Block_hash.pp exp
    end
    (obj2
       (req "block_hash" Block_hash.encoding)
       (req "block_hash_expected" Block_hash.encoding))
    (function Inconsistent_imported_block (got, exp) -> Some (got, exp) | _ -> None)
    (fun (got, exp) -> Inconsistent_imported_block (got, exp)) ;

  register_error_kind
    `Permanent
    ~id:"SnapshotImportFailure"
    ~title:"Snapshot import failure"
    ~description:"The imported snapshot is malformed."
    ~pp:begin fun ppf msg ->
      Format.fprintf ppf
        "The data contained in the snapshot is not valid. The import mechanism \
         failed to validate the file: %s."
        msg
    end
    (obj1 (req "message" string))
    (function Snapshot_import_failure str -> Some str | _ -> None)
    (fun str -> Snapshot_import_failure str) ;

  register_error_kind
    `Permanent
    ~id:"WrongReconstructMode"
    ~title:"Wrong reconstruct mode"
    ~description:"Reconstruction of contexts while importing is comptible \
                  with full mode snapshots only"
    ~pp:(fun ppf () ->
        Format.fprintf ppf
          "Contexts reconstruction is available with full mode snapshots only.")
    empty
    (function Wrong_reconstrcut_mode -> Some () | _ -> None)
    (fun () -> Wrong_reconstrcut_mode) ;

  register_error_kind
    `Permanent
    ~id:"WrongProtocolHash"
    ~title:"Wrong protocol hash"
    ~description:"Wrong protocol hash"
    ~pp:(fun ppf p ->
        Format.fprintf ppf
          "Wrong protocol hash (%a) found in snapshot. Snapshot is corrupted."
          Protocol_hash.pp p)
    (obj1 (req "protocol_hash" Protocol_hash.encoding))
    (function Wrong_protocol_hash p -> Some p | _ -> None)
    (fun p -> Wrong_protocol_hash p) ;

  register_error_kind
    `Permanent
    ~id:"InconsistentOperationHashes"
    ~title:"Inconsistent operation hashes"
    ~description:"The operations given do not match their hashes."
    ~pp:(fun ppf (oph, oph') ->
        Format.fprintf ppf
          "Inconsistent operation hashes. Expected: %a, got: %a."
          Operation_list_list_hash.pp oph Operation_list_list_hash.pp oph')
    (obj2
       (req "expected_operation_hashes" Operation_list_list_hash.encoding)
       (req "received_operation_hashes" Operation_list_list_hash.encoding))
    (function
      | Inconsistent_operation_hashes (oph, oph') -> Some (oph, oph')
      | _ -> None)
    (fun (oph, oph') -> Inconsistent_operation_hashes (oph, oph')) ;
end

let compute_export_limit
    block_store chain_data_store
    block_header export_rolling =
  let block_hash = Block_header.hash block_header in
  Store.Block.Contents.read_opt
    (block_store, block_hash) >>= begin function
    | Some contents -> return contents
    | None -> fail (Wrong_block_export (block_hash, `Pruned))
  end >>=? fun { max_operations_ttl } ->
  if not export_rolling then
    Store.Chain_data.Caboose.read chain_data_store >>=? fun (caboose_level, _) ->
    return (max 1l caboose_level)
  else
    let limit = Int32.(sub
                         block_header.Block_header.shell.level
                         (of_int max_operations_ttl)) in
    (* fails when the limit exceeds the genesis or the genesis is
       included in the export limit *)
    fail_when
      (limit <= 0l)
      (Wrong_block_export (block_hash, `Too_few_predecessors)) >>=? fun () ->
    return limit

(** When called with a block, returns its predecessor if it exists and
    its protocol_data if the block is a transition block (i.e. protocol
    level changing block) or when there is no more predecessor. *)
let pruned_block_iterator index block_store limit
  : (Block_header.t -> (Context.Pruned_block.t option * Context.Protocol_data.t option) tzresult Lwt.t) =
  fun header ->
    if header.Block_header.shell.level <= limit then
      Context.get_protocol_data_from_header index header >>= fun protocol_data ->
      return (None, Some protocol_data)
    else
      let pred_hash = header.Block_header.shell.predecessor in
      Store.Block.Header.read (block_store, pred_hash) >>=? fun pred_header ->
      Store.Block.Operations.bindings (block_store, pred_hash) >>= fun pred_operations ->
      Store.Block.Operation_hashes.bindings (block_store, pred_hash) >>= fun pred_operation_hashes ->
      let pruned_block = {
        Context.Pruned_block.block_header = pred_header ;
        operations = pred_operations ;
        operation_hashes = pred_operation_hashes ;
      } in
      let header_proto_level = header.Block_header.shell.proto_level in
      let pred_header_proto_level = pred_header.Block_header.shell.proto_level in
      if header_proto_level <> pred_header_proto_level then
        Context.get_protocol_data_from_header index header >>= fun proto_data ->
        return (Some pruned_block, Some proto_data)
      else
        return (Some pruned_block, None)

let export ?(export_rolling=false) ~data_dir ~genesis filename block  =
  let context_root = context_dir data_dir in
  let store_root = store_dir data_dir in
  let chain_id = Chain_id.of_block_hash genesis in
  Store.init store_root >>=? fun store ->
  let chain_store = Store.Chain.get store chain_id in
  let chain_data_store = Store.Chain_data.get chain_store in
  let block_store = Store.Block.get chain_store in
  begin Store.Configuration.History_mode.read_opt store >>= function
    | Some (Archive | Full) | None -> return_unit
    | Some (Rolling as history_mode) ->
        if export_rolling then return_unit else
          fail (Wrong_snapshot_export (history_mode, History_mode.Full))
  end >>=? fun () ->
  begin match block with
    | Some block_hash -> return (Block_hash.of_b58check_exn block_hash)
    | None ->
        Store.Chain_data.Checkpoint.read_exn (chain_data_store) >>= fun last_checkpoint ->
        if last_checkpoint.shell.level = 0l then
          fail (Wrong_block_export (genesis, `Too_few_predecessors))
        else
          let last_checkpoint_hash = Block_header.hash last_checkpoint in
          lwt_log_notice "No block hash specified with the `--block` option. Using %a by default (last checkpoint)"
            Block_hash.pp last_checkpoint_hash >>= fun () ->
          return last_checkpoint_hash
  end >>=? fun checkpoint_block_hash ->
  Context.init ~readonly:true context_root >>= fun context_index ->
  begin Store.Block.Header.read_opt
      (block_store, checkpoint_block_hash) >>= function
    | None ->
        fail (Wrong_block_export (checkpoint_block_hash, `Cannot_be_found))
    | Some block_header ->
        lwt_log_notice "Dumping: %a" Block_hash.pp checkpoint_block_hash >>= fun () ->
        (* Get block precessor's block header*)
        Store.Block.Predecessors.read
          (block_store, checkpoint_block_hash) 0 >>=? fun pred_block_hash ->
        Store.Block.Header.read
          (block_store, pred_block_hash) >>=? fun pred_block_header ->
        (* Get operation list*)
        let validations_passes = block_header.shell.validation_passes in
        map_s
          (fun i -> Store.Block.Operations.read (block_store, checkpoint_block_hash) i)
          (0 -- (validations_passes - 1)) >>=? fun operations ->
        compute_export_limit
          block_store chain_data_store block_header export_rolling >>=? fun export_limit ->
        let iterator = pruned_block_iterator context_index block_store export_limit in
        let block_data = { Context.Block_data.block_header ; operations } in
        let starting_block_header = block_header in
        return (pred_block_header, block_data, iterator, starting_block_header)
  end >>=? fun data_to_dump ->
  Context.dump_contexts context_index [ data_to_dump ] ~filename >>=? fun () ->
  Store.close store ;
  lwt_log_notice "Sucessful export (in file %s)" filename >>= fun () ->
  return_unit

let check_operations_consistency pruned_block =
  let { Context.Pruned_block.block_header ;
        operations ;
        operation_hashes ; _ } =
    pruned_block in
  (* Compute operations hashes and compare*)
  List.iter2
    (fun (_,op) (_,oph) ->
       let expeced_op_hash = List.map Operation.hash op in
       List.iter2 (fun excpected found ->
           assert (Operation_hash.equal excpected found)
         ) expeced_op_hash oph;
    )
    operations operation_hashes ;
  (* Check header hashes based on merkel tree*)
  let hashes = List.map (fun (_,opl) ->
      List.map Operation.hash opl)
      (List.rev operations) in
  let computed_hash =
    Operation_list_list_hash.compute
      (List.map Operation_list_hash.compute hashes) in
  let are_oph_equal = Operation_list_list_hash.equal
      computed_hash
      block_header.Block_header.shell.operations_hash in
  fail_unless are_oph_equal
    (Inconsistent_operation_hashes
       (computed_hash, block_header.Block_header.shell.operations_hash))

let check_history_consistency
    ~genesis
    (block_header : Block_header.t)
    (history: (Block_hash.t * Context.Pruned_block.t) array) =
  let nb_blocks = Array.length history in
  let oldest_header = (snd history.(0)).block_header in
  let oldest_level = oldest_header.shell.level in
  assert (Block_hash.equal block_header.shell.predecessor (fst history.(nb_blocks - 1))) ;
  assert (oldest_level >= 1l) ;
  if Compare.Int32.(oldest_level = 1l) then
    assert (Block_hash.equal oldest_header.shell.predecessor genesis) ;
  check_operations_consistency (snd history.(0)) >>=? fun () ->
  let rec check = function
    | 1 -> return_unit
    | n -> Tezos_stdlib.Utils.display_progress
             ~refresh_rate:(n - 1, 1_000)
             "Progress: %iK/%iK"
             ((nb_blocks - n) / 1_000)
             ((nb_blocks - n ) / 1_000) ;
        check_operations_consistency (snd history.(n)) >>=? fun () ->
        let { Context.Pruned_block.block_header ; _ } = snd history.(n) in
        assert (block_header.shell.level >= 2l) ;
        assert (Block_hash.equal
                  block_header.shell.predecessor
                  (fst history.(n - 1))) ;
        check (n - 1)
  in
  check (nb_blocks - 1) >>=? fun () ->
  Tezos_stdlib.Utils.display_progress_end () ;
  return_unit

let compute_predecessors_tables
    ~genesis
    (history: (Block_hash.t * Context.Pruned_block.t) array) =
  let nb_blocks = Array.length history in
  let oldest_header = (snd history.(0)).block_header in
  let oldest_level = oldest_header.shell.level in
  Array.init nb_blocks begin fun i ->
    let rec step s d acc =
      if oldest_level = 1l && i - d = -1 then
        List.rev ((s, genesis) :: acc)
      else if i - d < 0 then
        List.rev acc
      else
        step (succ s) (d * 2) ((s, fst history.(i - d)) :: acc) in
    step 0 1 []
  end

let store_pruned_blocks
    store block_store chain_data
    ~genesis
    (history: (Block_hash.t * Context.Pruned_block.t) array) =
  let nb_blocks = Array.length history in
  lwt_log_notice "Computing predecessor tables" >>= fun () ->
  let predecessors = compute_predecessors_tables ~genesis history in
  let rec loop_on_chunks cpt =
    Store.with_atomic_rw store begin fun () ->
      let rec loop_on_chunk cpt =
        if cpt = nb_blocks then Lwt.return cpt else begin
          Tezos_stdlib.Utils.display_progress
            ~refresh_rate:(cpt, 1000)
            "Storing blocks: %iK/%iK"
            (cpt / 1000)
            (nb_blocks / 1000) ;
          let pruned_block_hash, {Context.Pruned_block.block_header ; operations ; operation_hashes } = history.(cpt) in
          Store.Block.Header.store
            (block_store, Block_header.hash block_header) block_header >>= fun () ->
          Lwt_list.iter_s
            (fun (i, v) -> Store.Block.Operations.store (block_store, pruned_block_hash) i v)
            operations >>= fun () ->
          Lwt_list.iter_s
            (fun (i, v) -> Store.Block.Operation_hashes.store (block_store, pruned_block_hash) i v)
            operation_hashes >>= fun () ->
          Lwt_list.iter_s
            (fun (l, h) -> Store.Block.Predecessors.store (block_store, pruned_block_hash) l h)
            predecessors.(cpt) >>= fun () ->
          begin match predecessors.(cpt) with
            | (0, pred_hash) :: _ ->
                Store.Chain_data.In_main_branch.store (chain_data, pred_hash) pruned_block_hash
            | [] -> Lwt.return_unit
            | _ :: _ -> assert false
          end >>= fun () ->
          loop_on_chunk (succ cpt)
        end in
      if (succ cpt) mod 5000 = 0 then Lwt.return cpt else
        loop_on_chunk cpt end >>= fun cpt ->
    if cpt = nb_blocks then Lwt.return () else
      loop_on_chunks cpt in
  loop_on_chunks 0 >>= fun () ->
  Tezos_stdlib.Utils.display_progress_end () ;
  return_unit

let check_context_hash_consistency
    (block_validation_result : Tezos_validation.Block_validation.result)
    (block_header : Block_header.t) =
  (* we expect to match the context_hash …*)
  fail_unless
    (Context_hash.equal
       block_validation_result.context_hash
       block_header.shell.context)
    (Snapshot_import_failure "Resulting context hash does not match")

let is_snapshot_full history =
  (snd history.(0)).Context.Pruned_block.block_header.shell.level = 1l

let set_history_mode store history =
  if is_snapshot_full history then
    lwt_log_notice "Setting history-mode to %a" History_mode.pp Full >>= fun () ->
    Store.Configuration.History_mode.store store Full
  else
    lwt_log_notice "Setting history-mode to %a" History_mode.pp Rolling >>= fun () ->
    Lwt.return ()

let store_new_head
    chain_state chain_data
    ~genesis block_header
    operations block_validation_result =
  let { Tezos_validation.Block_validation.
        validation_result ;
        block_metadata ;
        ops_metadata ;
        forking_testchain ;
        context_hash } = block_validation_result in
  let validation_store = {
    State.Block.context_hash ;
    message = validation_result.message ;
    max_operations_ttl = validation_result.max_operations_ttl ;
    last_allowed_fork_level = validation_result.last_allowed_fork_level ;
  } in
  State.Block.store
    chain_state
    block_header block_metadata
    operations ops_metadata
    ~forking_testchain
    validation_store >>=? fun new_head ->
  begin match new_head with
    | None ->
        (* Should not happen as the data-dir must be empty *)
        assert false
    | Some new_head ->
        (* New head is set*)
        Store.Chain_data.Known_heads.remove chain_data genesis >>= fun () ->
        Store.Chain_data.Known_heads.store chain_data (State.Block.hash new_head) >>= fun () ->
        Store.Chain_data.Current_head.store chain_data (State.Block.hash new_head)
  end  >>= fun _old_head -> return_unit

let update_checkpoint chain_state checkpoint_header =
  let block_hash = Block_header.hash checkpoint_header in
  (* Imported block is set as the current checkpoint/save_point … *)
  let new_checkpoint = (checkpoint_header.Block_header.shell.level, block_hash) in
  State.Chain.set_checkpoint chain_state checkpoint_header >>= fun () ->
  State.update_chain_data chain_state begin fun _ data ->
    let new_data = { data with save_point = new_checkpoint ; } in
    Lwt.return (Some new_data, ())
  end >>= fun () -> Lwt.return new_checkpoint

let update_savepoint chain_data new_savepoint =
  Store.Chain_data.Save_point.store chain_data new_savepoint

let update_caboose chain_data ~genesis block_header oldest_header max_op_ttl =
  let oldest_level = oldest_header.Block_header.shell.level in
  let caboose_level =
    if oldest_level = 1l then 0l else oldest_level in
  let caboose_hash =
    if oldest_level = 1l then genesis else Block_header.hash oldest_header in
  let minimal_caboose_level =
    Int32.(sub
             block_header.Block_header.shell.level
             (of_int max_op_ttl)) in
  assert Compare.Int32.(caboose_level <= minimal_caboose_level) ;
  Store.Chain_data.Caboose.store chain_data (caboose_level, caboose_hash)

let reconstruct_contexts
    store context_index chain_id block_store
    (history : (Block_hash.t * Context.Pruned_block.t) array) =
  lwt_log_notice "Reconstructing all the contexts from the genesis." >>= fun () ->
  let limit = Array.length history in
  let rec reconstruct_chunks level =
    Store.with_atomic_rw store begin fun () ->
      let rec reconstruct_chunks level =
        Tezos_stdlib.Utils.display_progress
          "Reconstructing contexts: %i/%i"
          level
          limit ;
        if level = limit then
          return level
        else
          begin
            let block_hash, pb = history.(level) in
            Store.Block.Header.read
              (block_store, block_hash) >>=? fun block_header ->
            let operations = List.rev (List.map snd pb.operations) in
            let predecessor_block_hash = pb.block_header.shell.predecessor in
            Store.Block.Header.read
              (block_store, predecessor_block_hash) >>=? fun pred_block_header ->
            let context_hash = pred_block_header.shell.context in
            Context.checkout_exn context_index context_hash >>= fun pred_context ->

            Tezos_validation.Block_validation.apply
              chain_id
              ~max_operations_ttl:(Int32.to_int pred_block_header.shell.level)
              ~predecessor_block_header:pred_block_header
              ~predecessor_context:pred_context
              ~block_header
              operations >>=? fun block_validation_result ->

            check_context_hash_consistency
              block_validation_result
              block_header >>=? fun () ->

            reconstruct_chunks (level + 1)
          end
      in
      if level + 1 mod 1000 = 0 then return level
      else reconstruct_chunks level end >>=? fun level ->
    if level = limit then return_unit
    else reconstruct_chunks limit in
  reconstruct_chunks 0 >>=? fun _cpt ->
  Tezos_stdlib.Utils.display_progress_end ();
  return_unit

let import_protocol_data index store pruned_blocks level_oldest_block (level, protocol_data) =
  (* Retrieve the original context hash of the block. *)
  let block_header =
    let delta = Int32.(to_int (sub level level_oldest_block)) in
    let pruned_block = snd (pruned_blocks.(delta)) in
    pruned_block.Context.Pruned_block.block_header
  in
  let expected_context_hash = block_header.shell.context in
  (* Retrieve the input info. *)
  let info = protocol_data.Context.Protocol_data.info in
  let test_chain = protocol_data.test_chain_status in
  let data_hash = protocol_data.data_key in
  let parents = protocol_data.parents in
  let protocol_hash = protocol_data.protocol_hash in
  (* Validate the context hash consistency, and so the protocol data. *)
  Context.validate_context_hash_consistency_and_commit
    ~author:info.author
    ~timestamp:info.timestamp
    ~message:info.message
    ~data_hash
    ~parents
    ~expected_context_hash
    ~test_chain
    ~protocol_hash
    ~index >>= function
  | true ->
      let protocol_level = block_header.shell.proto_level in
      Store.Chain.Protocol_hash.store store protocol_level protocol_hash >>= fun () ->
      return_unit
  | false -> fail (Wrong_protocol_hash protocol_hash)

let import_protocol_data_list index store pruned_blocks protocol_data =
  let level_oldest_block =
    let b = snd pruned_blocks.(0) in
    b.Context.Pruned_block.block_header.shell.level in
  let rec aux = function
    | [] -> return_unit
    | (level, protocol_data) :: xs ->
        import_protocol_data index store pruned_blocks level_oldest_block (level, protocol_data) >>=? fun () ->
        aux xs
  in aux protocol_data

let import ?(reconstruct = false) ~data_dir ~dir_cleaner ~patch_context ~genesis filename block =
  let context_root = context_dir data_dir in
  let store_root = store_dir data_dir in
  let chain_id = Chain_id.of_block_hash genesis.State.Chain.block in

  (* FIXME: use config value ?*)
  State.init
    ~context_root ~store_root
    ~history_mode:Rolling genesis
    ~patch_context:(patch_context None) >>=? fun (_state, chain_state, context_index, _history_mode) ->

  Store.init ~mapsize:40_960_000_000L store_root >>=? fun store ->
  let chain_store = Store.Chain.get store chain_id in
  let chain_data = Store.Chain_data.get chain_store in
  let block_store = Store.Block.get chain_store in

  let open Context in
  Lwt.try_bind
    (fun () ->
       (* Restore context *)
       restore_contexts context_index ~filename >>=? fun restored_data ->

       (* Process data imported from snapshot *)
       Error_monad.iter_s
         begin fun ((predecessor_block_header : Block_header.t),
                    meta, old_blocks, protocol_data) ->
           let ({ block_header ; operations } :
                  Block_data.t) = meta in
           let block_hash = Block_header.hash block_header in
           (* Checks that the block hash imported by the snapshot is the expected one *)
           begin
             match block with
             | Some str ->
                 let bh = Block_hash.of_b58check_exn str in
                 fail_unless
                   (Block_hash.equal bh block_hash)
                   (Inconsistent_imported_block (bh,block_hash))
             | None ->
                 lwt_log_notice "You should consider using the --block <block_hash> \
                                 argument to check that the block imported using the \
                                 snapshot is the one you expect." >>= fun () -> return ()
           end >>=? fun () ->
           Store.Block.Contents.known (block_store, block_hash) >>= fun known ->
           if known then
             (* should not happen as the data-dir must be empty *)
             assert false
           else
             begin
               lwt_log_notice "Importing block %a"
                 Block_hash.pp (Block_header.hash block_header) >>= fun () ->
               (* To validate block_header we need ... *)
               (* ... its predecessor context ... *)
               let pred_context_hash = predecessor_block_header.shell.context in
               checkout_exn
                 context_index
                 pred_context_hash >>= fun predecessor_context ->

               (* ... we can now call apply ... *)
               Tezos_validation.Block_validation.apply
                 chain_id
                 ~max_operations_ttl:(Int32.to_int predecessor_block_header.shell.level)
                 ~predecessor_block_header:predecessor_block_header
                 ~predecessor_context
                 ~block_header
                 operations >>=? fun block_validation_result ->

               check_context_hash_consistency
                 block_validation_result
                 block_header >>=? fun () ->

               (* ... we check the history and compute the predecessor tables ...*)
               let old_blocks = List.rev_map (fun pruned_block ->
                   let hash = Block_header.hash pruned_block.Pruned_block.block_header in
                   (hash, pruned_block))
                   old_blocks in
               let history = Array.of_list old_blocks in

               lwt_log_notice "Checking history consistency" >>= fun () ->
               check_history_consistency
                 ~genesis:genesis.block block_header history >>=? fun () ->

               (* ... we set the history mode to full if it looks like a full snapshot ... *)
               set_history_mode store history >>= fun () ->

               (* ... and we import protocol data...*)
               import_protocol_data_list
                 context_index chain_store history protocol_data >>=? fun () ->

               (* ... and we write data in store.*)
               store_pruned_blocks
                 store block_store chain_data
                 ~genesis:genesis.block history >>=? fun () ->

               (* Everything is ok. We can store the new hea d*)
               store_new_head
                 chain_state
                 chain_data
                 ~genesis:genesis.block
                 block_header
                 operations
                 block_validation_result >>=? fun () ->

               (* Update history mode flags *)
               update_checkpoint chain_state block_header >>= fun new_checkpoint ->
               update_savepoint chain_data new_checkpoint >>= fun () ->
               let oldest_header = (snd history.(0)).block_header in
               update_caboose
                 chain_data
                 ~genesis:genesis.block block_header oldest_header
                 block_validation_result.validation_result.max_operations_ttl >>= fun () ->

               (* Reconstruct all the contexts if requested *)
               match reconstruct with
               | true ->
                   if is_snapshot_full history then
                     reconstruct_contexts store context_index chain_id block_store history
                   else
                     fail Wrong_reconstrcut_mode
               | false -> return_unit
             end
         end
         restored_data >>=? fun () ->
       Store.close store ;
       return_unit)
    (function
      | Ok () ->
          lwt_log_notice "Sucessfull import (from file %s)" filename >>= fun () ->
          return_unit
      | Error errors ->
          dir_cleaner data_dir >>= fun () ->
          Format.kasprintf
            Lwt.fail_with
            "%a" Error_monad.pp_print_error errors
    )
    (fun exn ->
       dir_cleaner data_dir >>= fun () ->
       Lwt.fail exn)