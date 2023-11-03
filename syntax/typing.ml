open Stt

exception Type_error of string

let error ?loc fmt =
  Format.(kasprintf (fun s -> raise (Type_error (
      asprintf "%a: %s" (pp_print_option Loc.pp) loc s
    ))))
    fmt

module Name = Base.Hstring
module NameTable = Hashtbl.Make (Name)
module NameSet = Set.Make (Name)
module NameMap = Map.Make (Name)

let mk_name = let i = ref 0 in
  fun () -> incr i;
    Name.cons ("#RE_" ^ (string_of_int !i))

let is_gen_name n =
  let s = Name.(!!n) in
  String.length s = 0 || s.[0] = '#'

module Re_compile : sig
  val compile : Ast.re -> Ast.typ_expr
end = struct
  (* Glushkov automata, aka Berry-Sethi construction. Our alphabet is the set of
     occurrences of (Re_typ t) in the regexp. No need to linerize since each t
     is localized and therefore unique.
  *)

  let rec first re = match snd re with
    | `Re_epsilon -> NameSet.empty
    | `Re_typ t -> NameSet.singleton t
    | `Re_alt (r1, r2) -> NameSet.union (first r1) (first r2)
    | `Re_concat ((eps1,_) as r1, r2) when eps1 -> NameSet.union (first r1) (first r2)
    | `Re_concat (r1, _) -> first r1
    | `Re_star r -> first r

  let rec last re = match snd re with
    | `Re_epsilon -> NameSet.empty
    | `Re_typ t -> NameSet.singleton t
    | `Re_alt (r1, r2) -> NameSet.union (last r1) (last r2)
    | `Re_concat (r1, (eps2,_ as r2)) when eps2 -> NameSet.union (last r2) (last r1)
    | `Re_concat (_, r2) -> last r2
    | `Re_star r -> last r

  let rec follow t re = match snd re with
    | `Re_epsilon | `Re_typ _ -> NameSet.empty
    | `Re_alt (r1, r2) -> NameSet.union (follow t r1) (follow t r2)
    | `Re_concat (r1, r2) ->
      NameSet.union (follow t r1)
        (NameSet.union (follow t r2)
           (if NameSet.mem t (last r1) then first r2 else NameSet.empty))
    | `Re_star r ->
      NameSet.union (follow t r)
        (if NameSet.mem t (last r) then first r else NameSet.empty)

  let compile re =
    let open Loc in
    let names = NameTable.create 16 in
    let fresh t =
      let n = mk_name () in
      NameTable.add names n t; n
    in
    let rec unique re =
      match re.descr with
        Ast.Re_epsilon -> (true,`Re_epsilon)
      | Re_typ t -> (false,`Re_typ (fresh t))
      | Re_alt (r1, r2) ->
        let r1 = unique r1 in let r2 = unique r2 in
        (fst r1 || fst r2,`Re_alt (r1, r2))
      | Re_concat (r1, r2) ->
        let r1 = unique r1 in let r2 = unique r2 in
        (fst r1 && fst r2,`Re_alt (r1, r2))
      | Re_star r -> true,`Re_star (unique r)
    in
    let start = mk_name () in
    let rel = unique re in
    let first = first rel and last = last rel in
    let htypes = NameTable.create 16 in
    let nil = with_loc re.loc (Ast.Typ Stt.Builtins.nil) in
    let node loc name =
      let name = with_loc loc name in
      with_loc loc Ast.(Node (ref (Inst (name, []))))
    in
    let add_trans q_in t =
      let t_orig = NameTable.find names t in
      let prod = copy_loc t_orig (Pair(t_orig, node t_orig.loc t)) in
      let new_t = try copy_loc t_orig (Cup (NameTable.find htypes q_in, prod)) with Not_found -> prod in
      NameTable.replace htypes q_in new_t
    in
    let set_final q = NameTable.replace htypes q nil in
    let () = if fst rel then set_final start in
    let () = names
             |> NameTable.iter (fun t _ ->
                 if NameSet.mem t last then set_final t;
                 if NameSet.mem t first then add_trans start t;
                 NameSet.iter (add_trans t) (follow t rel))
    in
    with_loc re.loc
      Ast.(Node (ref (Rec (node re.loc start,
                           NameTable.fold (fun x te acc ->
                               (with_loc re.loc x, te) :: acc)
                             htypes []))))

end

module Env : sig
  type 'a t
  val empty : 'a t
  val add : Ast.lident -> 'a -> 'a t -> 'a t
  val replace : Ast.lident -> 'a -> 'a t -> 'a t
  val find : Ast.lident -> 'a t -> 'a
  val find_loc : Ast.lident -> 'a t -> 'a * Loc.t
  val find_unloc : Name.t -> 'a t -> 'a * Loc.t
  val find_opt : Ast.lident -> 'a t -> 'a option
  val find_loc_opt : Ast.lident -> 'a t -> ('a * Loc.t) option
  val find_unloc_opt : Name.t -> 'a t -> ('a * Loc.t) option

  val mem : Ast.lident -> 'a t -> bool
  val mem_unloc : Name.t -> 'a t -> bool
end =
struct
  open Name
  type 'a t = ('a * Loc.t) NameMap.t
  let empty = NameMap.empty

  let add n v env =
    NameMap.update n.Loc.descr
      (function None -> Some (v,n.Loc.loc)
              | Some (_, other) ->
                error ~loc:n.Loc.loc "Name %s is already defined at %a" !!(n.Loc.descr)
                  Loc.pp other)
      env

  let replace n v env : 'a t =
    NameMap.add n.Loc.descr (v, n.Loc.loc) env

  let find_unloc n env =
    try (NameMap.find n env) with Not_found -> error "Name %s is undefined" !!n

  let find_loc n env = find_unloc n.Loc.descr env

  let find n env = fst (find_loc n env)

  let find_unloc_opt n env =
    NameMap.find_opt n env

  let find_loc_opt n env =
    find_unloc_opt n.Loc.descr env

  let find_opt n env =
    Option.map fst (find_loc_opt n env)

  let mem_unloc = NameMap.mem

  let mem n = NameMap.mem n.Loc.descr

end
type global_decl = {
  decl : Ast.typ_decl;
  vars : (Name.t * Var.t) list;
  typ : Typ.t;
  recs : Ast.typ_expr Env.t
}
type global = global_decl Env.t
let empty = Env.empty

let enter_builtin name t (env : global) : global =
  let open Loc in
  let open Ast in
  let dummy_decl = {decl = {
      name = with_loc dummy name;
      params = [];
      expr = with_loc dummy (Typ t) } ;
     vars = [];
     typ = t;
     recs = Env.empty }
  in
  Env.add dummy_decl.decl.name dummy_decl env


let default =
  List.fold_left (fun acc (n, t) -> enter_builtin n t acc)
    empty
    Stt.Builtins.by_names

let dummy_expr : Ast.typ_expr =
  Loc.(with_loc dummy (Ast.Typ Stt.Typ.empty))

let derecurse global te =
  let open Ast in
  let open Loc in
  let recs = ref Env.empty in
  let rec loop collect params env te =
    let do_loop = loop collect params env in
    copy_loc te @@
    match te.descr with
      Typ _ as d -> d
    | Pair (t1, t2) -> Pair (do_loop t1, do_loop t2)
    | Arrow (t1, t2) -> Arrow (do_loop t1, do_loop t2)
    | Cup (t1, t2) -> Cup (do_loop t1, do_loop t2)
    | Cap (t1, t2) -> Cap (do_loop t1, do_loop t2)
    | Diff (t1, t2) -> Diff (do_loop t1, do_loop t2)
    | Neg t -> Neg (do_loop t)
    | Var n as d -> begin
        match Env.find_opt n params with
          None -> d
        | Some e -> (do_loop e).descr end
    | Regexp re ->
      (do_loop (Re_compile.compile re)).descr
    | Node r -> Node (loop_node collect params env r)
  and loop_node collect params env r =
    let rnode = !r in
    match rnode with
    | Rec (t, l) ->
      let new_r = ref (Expr dummy_expr) in
      r := !new_r;
      let todo, env' =
        List.fold_left (fun (atodo, aenv) (n, d) ->
            match Env.find_loc_opt n aenv with
              None ->
              let rd = ref (Expr dummy_expr) in
              rd :: atodo, Env.add n (d, rd) aenv
            | Some (_, loc) ->
              error ~loc:n.loc
                "Multiple definitions of recursive type variable %s, the previous one was at %a"
                Name.(!!(n.descr)) Loc.pp loc) ([], env) l
      in
      let nt = loop collect params env' t in
      let nl = List.rev_map (fun (n, te) -> (n, loop collect params env' te)) l in
      let () = List.iter2 (fun rd ((x, nte)) ->
          rd := Expr nte;
          if collect && not (is_gen_name x.descr) then recs := Env.add x nte !recs
        ) todo nl
      in new_r := Expr nt; new_r
    | Inst (x, args) -> begin
        match args, Env.find_opt x env with
          _, None -> let new_r = ref (Expr dummy_expr) in
          inline_global collect params env x args new_r None
        | [], Some (_, r) -> r
        | _ -> error ~loc:x.loc "Name %s is a recursive type variable, it cannot be instantiated"
                 Name.(!!(x.descr))
      end

    | From (x, (y, args)) ->
      let new_r = ref (Expr dummy_expr) in
      inline_global collect params env y args new_r  (Some x)
    | Expr _  -> r
  and inline_global collect params env x args new_r teopt =
    let args = List.map (loop collect params env) args in
    let decl = Env.find x global in
    let nparams =
      try
        List.fold_left2 (fun acc x arg ->
            Env.add x arg acc
          ) Env.empty
          decl.decl.params args
      with Invalid_argument _ ->
        let num_params = List.length decl.decl.params in
        error ~loc:x.loc "Parametric type %s expects %d argument%s but was applied to %d"
          Name.(!!(x.descr))
          num_params
          (if num_params < 2 then "" else "s")
          (List.length args)
    in
    let te = match teopt with
        None -> decl.decl.expr
      | Some n -> Env.find n decl.recs
    in
    let d = loop false nparams env te in
    new_r := Expr d;
    new_r
  in
  let res = loop true Env.empty Env.empty te in
  res, !recs

module Memo = Hashtbl.Make (struct
    type t = Ast.node ref
    let hash = Hashtbl.hash
    let equal a b = a == b
  end)
let expand te =
  let open Loc in
  let open Ast in
  let memo = Memo.create 16 in
  let rec loop te =
    with_loc te.loc @@
    match te.descr with
    | (Typ _ | Pair _ | Arrow _ | Var _ | Regexp _) as d -> d
    | Cup (t1, t2) -> Cup (loop t1, loop t2)
    | Cap (t1, t2) -> Cap (loop t1, loop t2)
    | Diff (t1, t2) -> Diff (loop t1, loop t2)
    | Neg t -> Neg (loop t)
    | Node r -> Node (follow te.loc r)
  and follow loc r =
    try
      let visiting = Memo.find memo r in
      if visiting then
        error ~loc "Ill-founded recursion"
      else r
    with Not_found ->
      Memo.add memo r true;
      begin
        match !r with
          Expr { descr = Node r' ; loc } ->
          let r' = follow loc r' in
          r := !r'
        | Expr te -> r := Expr (loop te)
        | _ -> assert false
      end;
      Memo.replace memo r false;
      r
  in loop te


let build_type var_map te =
  let open Ast in
  let open Stt.Typ in
  let memo = Memo.create 16 in
  let rec loop te =
    match te.Loc.descr with
      Typ t -> node t
    | Pair (t1, t2) -> node @@ product (loop t1) (loop t2)
    | Arrow (t1, t2) -> node @@ arrow (loop t1) (loop t2)
    | Cup (t1, t2) -> node @@ cup (descr (loop t1)) (descr (loop t2))
    | Cap (t1, t2) -> node @@ cap (descr (loop t1)) (descr (loop t2))
    | Diff (t1, t2) -> node @@ diff (descr (loop t1)) (descr (loop t2))
    | Neg t -> node @@ neg (descr (loop t))
    | Var lident ->
      (try
         NameMap.find lident.descr var_map
       with Not_found -> error ~loc:te.Loc.loc "Unbound polymorphic variable '%s"
                           Name.(!!(lident.descr)))
    | Regexp _ -> assert false
    | Node r -> begin
        match Memo.find memo r with
        | None -> let n = make () in Memo.replace memo r (Some n); n
        | Some n -> n
        | exception Not_found ->
          Memo.add memo r None;
          let nte =
            match !r with
              Expr te -> loop te
            | _ -> assert false
          in
          match Memo.find memo r with
            None -> Memo.replace memo r (Some nte); nte
          | Some n ->
            def n (descr nte);n
      end
  in loop te

let type_decl global decl =
  let open Ast in
  let te, recs = derecurse global decl.expr in
  let te = expand te in
  let var_list, var_map = List.fold_left (fun (al, am) x ->
      let s = Name.(!!(x.Loc.descr)) in
      let v = Var.make s in
      let vt = Stt.Typ.(node @@ var v) in
      (x.Loc.descr, v)::al, NameMap.add x.Loc.descr vt am
    ) ([], NameMap.empty) decl.params
  in
  let typ = Stt.Typ.descr @@ build_type var_map te in
  let gd = {
    decl;
    vars = List.rev var_list;
    typ;
    recs;
  }
  in
  gd, Env.add decl.name gd global

