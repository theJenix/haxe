open Globals
open Ast
open DisplayTypes
open Common
open Typecore
open CompilationServer
open ImportHandling

type reference_kind =
	| KVar
	| KIdent
	| KAnyField
	| KClassField
	| KEnumField
	| KModuleType
	| KConstructor

let find_possible_references kind name (pack,decls) =
	(* Employ some heuristics: We know what kind of symbol we are looking for, so let's
	   filter where we can. *)
	let check kind' name' =
		if name = name' then match kind',kind with
			| KIdent,_
			| KAnyField,(SKField _ | SKConstructor _ | SKEnumField _)
			| KClassField,SKField _
			| KEnumField,SKEnumField _
			| KModuleType,(SKClass _ | SKEnum _ | SKTypedef _ | SKAbstract _)
			| KConstructor,(SKConstructor _ | SKClass _) ->
				raise Exit
			| _ ->
				()
	in
	let rec type_path kind path =
		check KModuleType path.tname;
		Option.may (check KModuleType) path.tsub;
		List.iter (function
			| TPType th -> type_hint th
			| TPExpr e -> expr e
		) path.tparams
	and type_hint th = match fst th with
		| CTPath path -> type_path KModuleType path
		| CTParent th | CTOptional th | CTNamed(_,th) -> type_hint th
		| CTFunction(thl,th) ->
			List.iter type_hint thl;
			type_hint th;
		| CTAnonymous cffl ->
			List.iter field cffl
		| CTExtend(tl,cffl) ->
			List.iter (fun (path,_) -> type_path KModuleType path) tl;
			List.iter field cffl;
		| CTIntersection tl ->
			List.iter type_hint tl
	and type_param tp =
		List.iter type_param tp.tp_params;
		Option.may type_hint tp.tp_constraints
	and expr (e,p) =
		begin match e with
		| EConst(Ident s) ->
			check KIdent s
		| EField(e1,s) ->
			expr e1;
			check KAnyField s;
		| EVars vl ->
			List.iter (fun (_,_,tho,eo) ->
				Option.may type_hint tho;
				expr_opt eo
			) vl;
		| ECast(e1,tho) ->
			expr e1;
			Option.may type_hint tho;
		| ENew((path,_),el) ->
			type_path KConstructor path;
			List.iter expr el;
		| EFunction(_,f) ->
			func f
		| ETry(e1,catches) ->
			expr e1;
			List.iter (fun (_,th,e,_) ->
				type_hint th;
				expr e
			) catches;
		| ECheckType(e1,th) ->
			expr e1;
			type_hint th;
		| _ ->
			iter_expr expr (e,p)
		end
	and expr_opt eo = match eo with
		| None -> ()
		| Some e -> expr e
	and func f =
		List.iter (fun ((s,p),_,_,tho,eo) ->
			Option.may type_hint tho;
			expr_opt eo
		) f.f_args;
		List.iter type_param f.f_params;
		Option.may type_hint f.f_type;
		expr_opt f.f_expr
	and field cff =
		check KClassField (fst cff.cff_name);
		match cff.cff_kind with
		| FVar(tho,eo) ->
			Option.may type_hint tho;
			expr_opt eo
		| FFun f ->
			func f
		| FProp(_,_,tho,eo) ->
			Option.may type_hint tho;
			expr_opt eo
	in
	List.iter (fun (td,p) -> match td with
		| EImport(path,_) | EUsing path ->
			begin match fst (ImportHandling.convert_import_to_something_usable null_pos path) with
			| IDKModule(_,s) -> check KModuleType s
			| IDKSubType(_,s1,s2) ->
				check KModuleType s1;
				check KModuleType s2;
			| IDKSubTypeField(_,s1,s2,s3) ->
				check KModuleType s1;
				check KModuleType s2;
				check KAnyField s3;
			| IDKModuleField(_,s1,s2) ->
				check KModuleType s1;
				check KAnyField s2;
			| IDKPackage _ | IDK ->
				()
			end;
		| EClass d ->
			check KModuleType (fst d.d_name);
			List.iter (function
				| HExtends(path,_) | HImplements(path,_) -> type_path KModuleType path
				| _ -> ()
			) d.d_flags;
			List.iter type_param d.d_params;
			List.iter field d.d_data
		| EEnum d ->
			check KModuleType (fst d.d_name);
			List.iter (fun ef ->
				Option.may type_hint ef.ec_type;
				check KEnumField (fst ef.ec_name);
				List.iter type_param ef.ec_params;
			) d.d_data;
			List.iter type_param d.d_params;
		| ETypedef d ->
			check KModuleType (fst d.d_name);
			List.iter type_param d.d_params;
			type_hint d.d_data;
		| EAbstract d ->
			check KModuleType (fst d.d_name);
			List.iter field d.d_data;
			List.iter type_param d.d_params;
			List.iter (function
				| AbFrom th | AbTo th | AbOver th -> type_hint th
				| _ -> ()
			) d.d_flags;
	) decls

let find_possible_references tctx cs =
	let name,pos,kind = Display.ReferencePosition.get () in
	DisplayToplevel.init_or_update_server cs tctx.com ["display";"references"];
	let cc = CommonCache.get_cache cs tctx.com in
	let files = cc#get_files in
	let modules = cc#get_modules in
	let t = Timer.timer ["display";"references";"candidates"] in
	Hashtbl.iter (fun file cfile ->
		let module_name = CompilationServer.get_module_name_of_cfile file cfile in
		if not (Hashtbl.mem modules (cfile.c_package,module_name)) then try
			find_possible_references kind name (cfile.c_package,cfile.c_decls);
		with Exit ->
			begin try
				ignore(tctx.g.do_load_module tctx (cfile.c_package,module_name) null_pos);
				(* We have to flush immediately so we catch exceptions from weird modules *)
				Typecore.flush_pass tctx Typecore.PFinal "final";
			with _ ->
				()
			end
	) files;
	t();
	()

let find_references tctx com with_definition name pos kind =
	let t = Timer.timer ["display";"references";"collect"] in
	let symbols,relations = Statistics.collect_statistics tctx (SFPos pos) true in
	t();
	let rec loop acc relations = match relations with
		| (Statistics.Referenced,p) :: relations -> loop (p :: acc) relations
		| _ :: relations -> loop acc relations
		| [] -> acc
	in
	let t = Timer.timer ["display";"references";"filter"] in
	let usages = Hashtbl.fold (fun p sym acc ->
		let acc = if with_definition then p :: acc else acc in
		(try loop acc (Hashtbl.find relations p)
		with Not_found -> acc)
	) symbols [] in
	let usages = List.sort (fun p1 p2 ->
		let c = compare p1.pfile p2.pfile in
		if c <> 0 then c else compare p1.pmin p2.pmin
	) usages in
	t();
	Display.ReferencePosition.set ("",null_pos,SKOther);
	DisplayException.raise_positions usages

let find_references tctx com with_definition =
	let name,pos,kind = Display.ReferencePosition.get () in
	if pos <> null_pos then find_references tctx com with_definition name pos kind
	else DisplayException.raise_positions []

let find_implementations tctx com name pos kind =
	let t = Timer.timer ["display";"implementations";"collect"] in
	let symbols,relations = Statistics.collect_statistics tctx (SFPos pos) false in
	t();
	let rec loop acc relations = match relations with
		| ((Statistics.Implemented | Statistics.Overridden | Statistics.Extended),p) :: relations -> loop (p :: acc) relations
		| _ :: relations -> loop acc relations
		| [] -> acc
	in
	let t = Timer.timer ["display";"implementations";"filter"] in
	let usages = Hashtbl.fold (fun p sym acc ->
		(try loop acc (Hashtbl.find relations p)
		with Not_found -> acc)
	) symbols [] in
	let usages = List.sort (fun p1 p2 ->
		let c = compare p1.pfile p2.pfile in
		if c <> 0 then c else compare p1.pmin p2.pmin
	) usages in
	t();
	Display.ReferencePosition.set ("",null_pos,SKOther);
	DisplayException.raise_positions usages

let find_implementations tctx com =
	let name,pos,kind = Display.ReferencePosition.get () in
	if pos <> null_pos then find_implementations tctx com name pos kind
	else DisplayException.raise_positions []