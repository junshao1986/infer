(*
 * Copyright (c) 2009 - 2013 Monoidics ltd.
 * Copyright (c) 2013 - present Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD style license found in the
 * LICENSE file in the root directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *)

open! Utils

(** mutate the cfg/cg to add dynamic dispatch handling *)
let add_dispatch_calls pdesc cg tenv =
  let node_add_dispatch_calls caller_pname node =
    (* TODO: handle dynamic dispatch for virtual calls as well *)
    let call_flags_is_dispatch call_flags =
      (* if sound dispatch is turned off, only consider dispatch for interface calls *)
      (Config.sound_dynamic_dispatch && call_flags.Sil.cf_virtual) ||
      call_flags.Sil.cf_interface in
    let instr_is_dispatch_call = function
      | Sil.Call (_, _, _, _, call_flags) -> call_flags_is_dispatch call_flags
      | _ -> false in
    let has_dispatch_call instrs =
      IList.exists instr_is_dispatch_call instrs in
    let replace_dispatch_calls = function
      | Sil.Call (ret_ids, (Sil.Const (Sil.Cfun callee_pname) as call_exp),
                  (((_, receiver_typ) :: _) as args), loc, call_flags) as instr
        when call_flags_is_dispatch call_flags ->
          (* the frontend should not populate the list of targets *)
          assert (call_flags.Sil.cf_targets = []);
          let receiver_typ_no_ptr = match receiver_typ with
            | Sil.Tptr (typ', _) ->
                typ'
            | _ ->
                receiver_typ in
          let sorted_overrides =
            let overrides = Prover.get_overrides_of tenv receiver_typ_no_ptr callee_pname in
            IList.sort (fun (_, p1) (_, p2) -> Procname.compare p1 p2) overrides in
          (match sorted_overrides with
           | ((_, target_pname) :: _) as all_targets ->
               let targets_to_add =
                 if Config.sound_dynamic_dispatch then
                   IList.map snd all_targets
                 else
                   (* if sound dispatch is turned off, consider only the first target. we do this
                      because choosing all targets is too expensive for everyday use *)
                   [target_pname] in
               IList.iter
                 (fun target_pname -> Cg.add_edge cg caller_pname target_pname)
                 targets_to_add;
               let call_flags' = { call_flags with Sil.cf_targets = targets_to_add; } in
               Sil.Call (ret_ids, call_exp, args, loc, call_flags')
           | [] -> instr)

      | instr -> instr in
    let instrs = Cfg.Node.get_instrs node in
    if has_dispatch_call instrs then
      IList.map replace_dispatch_calls instrs
      |> Cfg.Node.replace_instrs node in
  let pname = Cfg.Procdesc.get_proc_name pdesc in
  if Procname.is_java pname then
    Cfg.Procdesc.iter_nodes (node_add_dispatch_calls pname) pdesc

(** add instructions to perform abstraction *)
let add_abstraction_instructions pdesc =
  let open Cfg in
  (* true if there is a succ node s.t.: it is an exit node, or the succ of >1 nodes *)
  let converging_node node =
    let is_exit node = match Node.get_kind node with
      | Node.Exit_node _ -> true
      | _ -> false in
    let succ_nodes = Node.get_succs node in
    if IList.exists is_exit succ_nodes then true
    else match succ_nodes with
      | [] -> false
      | [h] -> IList.length (Node.get_preds h) > 1
      | _ -> false in
  let node_requires_abstraction node =
    match Node.get_kind node with
    | Node.Start_node _
    | Node.Join_node ->
        false
    | Node.Exit_node _
    | Node.Stmt_node _
    | Node.Prune_node _
    | Node.Skip_node _ ->
        converging_node node in
  let do_node node =
    let loc = Node.get_last_loc node in
    if node_requires_abstraction node then Node.append_instrs node [Sil.Abstract loc] in
  Cfg.Procdesc.iter_nodes do_node pdesc

module BackwardCfg = ProcCfg.Backward(ProcCfg.Exceptional)

module LivenessAnalysis =
  AbstractInterpreter.Make
    (BackwardCfg)
    (Scheduler.ReversePostorder)
    (Liveness.TransferFunctions)

module VarDomain = AbstractDomain.FiniteSet(Var.Set)

(** computes the non-nullified reaching definitions at the end of each node by building on the
    results of a liveness analysis to be precise, what we want to compute is:
    to_nullify := (live_before U non_nullifed_reaching_defs) - live_after
    non_nullified_reaching_defs := non_nullified_reaching_defs - to_nullify
    Note that this can't be done with by combining the results of reaching definitions and liveness
    after the fact, nor can it be done with liveness alone. We will insert nullify instructions for
    each pvar in to_nullify afer we finish the analysis. Nullify instructions speed up the analysis
    by enabling it to GC state that will no longer be read. *)
module NullifyTransferFunctions = struct
  (* (reaching non-nullified vars) * (vars to nullify) *)
  module Domain = AbstractDomain.Pair (VarDomain) (VarDomain)
  module CFG = ProcCfg.Exceptional
  type extras = LivenessAnalysis.inv_map

  let postprocess ((reaching_defs, _) as astate) node_id { ProcData.extras; } =
    match LivenessAnalysis.extract_state node_id extras with
    (* note: because the analysis backward, post and pre are reversed *)
    | Some { AbstractInterpreter.post = live_before; pre = live_after; } ->
        let to_nullify = VarDomain.diff (VarDomain.union live_before reaching_defs) live_after in
        let reaching_defs' = VarDomain.diff reaching_defs to_nullify in
        (reaching_defs', to_nullify)
    | None -> astate

  let is_last_instr_in_node instr node =
    let rec is_last_instr instr = function
      | [] -> true
      | last_instr :: [] -> Sil.instr_compare instr last_instr = 0
      | _ :: instrs -> is_last_instr instr instrs in
    is_last_instr instr (CFG.instrs node)

  let exec_instr ((active_defs, to_nullify) as astate) extras node instr =
    let astate' = match instr with
      | Sil.Letderef (lhs_id, _, _, _) ->
          VarDomain.add (Var.of_id lhs_id) active_defs, to_nullify
      | Sil.Call (lhs_ids, _, _, _, _) ->
          let active_defs' =
            IList.fold_left
              (fun acc id -> VarDomain.add (Var.of_id id) acc)
              active_defs
              lhs_ids in
          active_defs', to_nullify
      | Sil.Set (Sil.Lvar lhs_pvar, _, _, _) ->
          VarDomain.add (Var.of_pvar lhs_pvar) active_defs, to_nullify
      | Sil.Set _ | Prune _ | Declare_locals _ | Stackop _ | Remove_temps _
      | Abstract _ ->
          astate
      | Sil.Nullify _ ->
          failwith "Should not add nullify instructions before running nullify analysis!" in
    if is_last_instr_in_node instr node
    then postprocess astate' (CFG.id node) extras
    else astate'
end

module NullifyAnalysis =
  AbstractInterpreter.MakeNoCFG
    (Scheduler.ReversePostorder (ProcCfg.Exceptional))
    (NullifyTransferFunctions)

let add_nullify_instrs pdesc tenv =
  let liveness_proc_cfg = BackwardCfg.from_pdesc pdesc in
  let proc_data_no_extras = ProcData.make_default pdesc tenv in
  let liveness_inv_map = LivenessAnalysis.exec_cfg liveness_proc_cfg proc_data_no_extras in

  let address_taken_vars =
    if Procname.is_java (Cfg.Procdesc.get_proc_name pdesc)
    then AddressTaken.Domain.empty (* can't take the address of a variable in Java *)
    else
      match AddressTaken.Analyzer.compute_post proc_data_no_extras with
      | Some post -> post
      | None -> AddressTaken.Domain.empty in

  let nullify_proc_cfg = ProcCfg.Exceptional.from_pdesc pdesc in
  let nullify_proc_data = ProcData.make pdesc tenv liveness_inv_map in
  let nullify_inv_map = NullifyAnalysis.exec_cfg nullify_proc_cfg nullify_proc_data in

  (* only nullify pvars that are local; don't nullify those that can escape *)
  let is_local pvar =
    not (Pvar.is_return pvar || Pvar.is_global pvar) in

  let node_add_nullify_instructions node pvars =
    let loc = Cfg.Node.get_last_loc node in
    let nullify_instrs =
      IList.filter is_local pvars
      |> IList.map (fun pvar -> Sil.Nullify (pvar, loc)) in
    if nullify_instrs <> []
    then Cfg.Node.append_instrs node (IList.rev nullify_instrs) in

  let node_add_removetmps_instructions node ids =
    if ids <> [] then
      let loc = Cfg.Node.get_last_loc node in
      Cfg.Node.append_instrs node [Sil.Remove_temps (IList.rev ids, loc)] in

  IList.iter
    (fun node ->
       match NullifyAnalysis.extract_post (ProcCfg.Exceptional.id node) nullify_inv_map with
       | Some (_, to_nullify) ->
           let pvars_to_nullify, ids_to_remove =
             Var.Set.fold
               (fun var (pvars_acc, ids_acc) -> match Var.to_exp var with
                  (* we nullify all address taken variables at the end of the procedure *)
                  | Sil.Lvar pvar when not (AddressTaken.Domain.mem pvar address_taken_vars) ->
                      pvar :: pvars_acc, ids_acc
                  | Sil.Var id ->
                      pvars_acc, id :: ids_acc
                  | _ -> pvars_acc, ids_acc)
               to_nullify
               ([], []) in
           node_add_removetmps_instructions node ids_to_remove;
           node_add_nullify_instructions node pvars_to_nullify
       | None -> ())
    (ProcCfg.Exceptional.nodes nullify_proc_cfg);
  (* nullify all address taken variables *)
  if not (AddressTaken.Domain.is_empty address_taken_vars)
  then
    let exit_node = ProcCfg.Exceptional.exit_node nullify_proc_cfg in
    node_add_nullify_instructions exit_node (AddressTaken.Domain.elements address_taken_vars)

let doit pdesc cg tenv =
  add_nullify_instrs pdesc tenv;
  add_dispatch_calls pdesc cg tenv;
  add_abstraction_instructions pdesc;
