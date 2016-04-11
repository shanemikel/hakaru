# Teach Maple (through depends and eval) about our new binding forms.
# Integrand and LO bind from 1st arg to 2nd arg.

`depends/Integrand` := proc(v, e, x) depends(e, x minus {v}) end proc:
`depends/LO`        := proc(v, e, x) depends(e, x minus {v}) end proc:

`eval/Integrand` := proc(e, eqs)
  local v, ee;
  v, ee := op(e);
  eval(op(0,e), eqs)(BindingTools:-generic_evalat(v, ee, eqs))
end proc:

`eval/LO` := proc(e, eqs)
  local v, ee;
  v, ee := op(e);
  eval(op(0,e), eqs)(BindingTools:-generic_evalat(v, ee, eqs))
end proc:

#############################################################################

NewSLO := module ()
  option package;
  local t_pw,
        integrate_known, known_continuous, known_discrete,
        recognize_continuous, recognize_discrete, get_de, get_se,
        recognize_de, mysolve, Shiftop, Diffop, Recognized,
        factorize, bind, weight,
        reduce_IntSum, reduce_IntsSums, get_indicators,
        elim_intsum, do_elim_intsum, elim_metric, banish,
        reduce_pw, nub_piecewise, piecewise_if,
        find_vars, kb_from_path, interpret, reconstruct, invert, 
        get_var_pos, get_int_pos,
        avoid_capture, change_var, disint2,
        mk_sym, mk_ary, mk_idx, mk_HArray,
        ModuleLoad;
  export
     # These first few are smart constructors (for themselves):
         integrate, applyintegrand,
     # while these are "proper functions"
         RoundTrip, Simplify, SimplifyKB, TestSimplify, TestHakaru,
         toLO, fromLO, unintegrate, unweight, improve, reduce, Banish,
         density, bounds,
         ReparamDetermined, determined, Reparam, disint;
  # these names are not assigned (and should not be).  But they are
  # used as global names, so document that here.
  global LO, Integrand, Indicator;
  uses Hakaru, KB, Loop;

  RoundTrip := proc(e, t::t_type)
    lprint(eval(ToInert(Simplify(_passed)), _Inert_ATTRIBUTE=NULL))
  end proc;

  Simplify := proc(e, t::t_type, {ctx :: list := []}, $)
    SimplifyKB(e, t, foldr(assert, empty, op(ctx)))
  end proc;

  SimplifyKB := proc(e, t::t_type, kb::t_kb, $)
    local patterns, x, kb1, ex;
    if t :: HMeasure(anything) then
      fromLO(improve(toLO(e), _ctx=kb), _ctx=kb)
    elif t :: HFunction(anything, anything) then
      patterns := htype_patterns(op(1,t));
      if patterns :: Branches(Branch(PVar(name),anything)) then
        # Eta-expand the function type
        x := `if`(e::lam(name,anything,anything), op(1,e),
                  op([1,1,1],patterns));
        x, kb1 := genType(x, op(1,t), kb, e);
        ex := app(e,x);
        lam(x, op(1,t), SimplifyKB(ex, op(2,t), kb1))
      else
        # Eta-expand the function type and the sum-of-product argument-type
        x := `if`(e::lam(name,anything,anything), op(1,e), d);
        if depends([e,t,kb], x) then x := gensym(x) end if;
        ex := app(e,x);
        lam(x, op(1,t), 'case'(x,
          map(proc(branch)
                local eSubst, pSubst, p1, binds, y, kb1, i, pSubst1;
                eSubst, pSubst := pattern_match([x,e], x, op(1,branch));
                p1 := subs(pSubst, op(1,branch));
                binds := [pattern_binds(p1)];
                kb1 := kb;
                pSubst1 := table();
                for i from 1 to nops(binds) do
                  y, kb1 := genType(op(i,binds), op([2,i],branch), kb1);
                  pSubst1[op(i,binds)] := y;
                end do;
                pSubst1 := op(op(pSubst1));
                Branch(subs(pSubst1, p1),
                       SimplifyKB(eval(eval(ex,eSubst),pSubst1), op(2,t), kb1))
              end proc,
              patterns)))
      end if
    else
      simplify_assuming(e, kb)
    end if
  end proc;

# Testing

  TestSimplify := proc(m, t, n::algebraic:=m, {verify:=simplify})
    local s, r;
    # How to pass keyword argument {ctx::list:=[]} on to Simplify?
    s, r := selectremove(type, [_rest], 'identical(ctx)=anything');
    CodeTools[Test](Simplify(m,t,op(s)), n, measure(verify), op(r))
  end proc;

  TestHakaru := proc(m, n::algebraic:=m,
                     {simp:=improve, verify:=simplify, ctx::list:=[]})
    local kb;
    kb := foldr(assert, empty, op(ctx));
    CodeTools[Test](fromLO(simp(toLO(m), _ctx=kb), _ctx=kb), n,
      measure(verify), _rest)
  end proc;

  t_pw := 'specfunc(piecewise)';

# An integrand h is either an Integrand (our own binding construct for a
# measurable function to be integrated) or something that can be applied
# (probably proc, which should be applied immediately, or a generated symbol).

  applyintegrand := proc(h, x, $)
    if h :: 'Integrand(name, anything)' then
      eval(op(2,h), op(1,h) = x)
    elif h :: appliable then
      h(x)
    else
      'procname(_passed)'
    end if
  end proc;

# Step 1 of 3: from Hakaru to Maple LO (linear operator)

  toLO := proc(m, $)
    local h;
    h := gensym('h');
    LO(h, integrate(m, h, []))
  end proc;

  integrate := proc(m, h, loops :: list(name = range) := [], $)
    local x, n, i, res, l;

    if m :: known_continuous then
      integrate_known(Int, Ints, 'xx', m, h, loops)
    elif m :: known_discrete then
      integrate_known(Sum, Sums, 'kk', m, h, loops)
    elif m :: 'Ret(anything)' then
      applyintegrand(h, mk_ary(op(1,m), loops))
    elif m :: 'Bind(anything, name, anything)' then
      res := eval(op(3,m), op(2,m) = mk_idx(op(2,m), loops));
      res := eval(Integrand(op(2,m), 'integrate'(res, x, loops)), x=h);
      integrate(op(1,m), res, loops);
    elif m :: 'specfunc(Msum)' and nops(loops) = 0 then
      `+`(op(map(integrate, [op(m)], h, loops)))
    elif m :: 'Weight(anything, anything)' then
      foldl(product, op(1,m), op(loops)) * integrate(op(2,m), h, loops)
    elif m :: t_pw
      and not depends([seq(op(i,m), i=1..nops(m)-1, 2)], map(lhs, loops)) then
      n := nops(m);
      piecewise(seq(`if`(i::even or i=n, integrate(op(i,m), h, loops), op(i,m)),
                    i=1..n))
    elif m :: t_case and not depends(op(1,m), map(lhs, loops)) then
      subsop(2=map(proc(b :: Branch(anything, anything))
                     eval(subsop(2='integrate'(op(2,b), x, loops),b), x=h)
                   end proc,
                   op(2,m)),
             m);
    elif m :: 'LO(name, anything)' then
      eval(op(2,m), op(1,m) = h)
    elif m :: 'Plate(nonnegint, name, anything)' then
      # Unroll Plate when the bound is known. We unroll Plate here (instead
      # of unrolling Ints in reduce, for example) because we have no other
      # way to integrate certain Plates, namely those whose bodies' control
      # flows depend on the index.
      x := mk_sym('pp', h);
      x := [seq(cat(x,i), i=0..op(1,m)-1)];
      if op(1,m) = 0 then
        res := undefined;
      else
        if op(1,m) = 1 then
          res := op(1,x);
        else
          res := piecewise(seq(op([op(2,m)=i-1, op(i,x)]), i=2..op(1,m)),
                           op(1,x));
        end if;
        res := mk_idx(res, loops);
      end if;
      res := applyintegrand(h, mk_ary('ary'(op(1,m), op(2,m), res), loops));
      for i from op(1,m) to 1 by -1 do
        res := integrate(eval(op(3,m), op(2,m)=i-1),
                         Integrand(op(i,x), res), loops);
      end do;
      res
    elif m :: 'Plate(anything, name, anything)' then
      integrate(op(3,m), h, [op(2,m)=0..op(1,m)-1, op(loops)])
    elif m :: 'Context(anything, anything)' then
      applyop(integrate, 2, m, h, loops)
    elif h :: appliable then
      x := gensym('xa');
      'integrate'(m, Integrand(x, h(x)), loops)
    else
      'procname(_passed)'
    end if
  end proc;

  integrate_known := proc(make, makes, var, m, h, loops :: list(name=range), $)
    local x, dens, bds;
    x := mk_sym(var, h);
    dens := density[op(0,m)](op(m));
    bds := bounds[op(0,m)](op(m));
    if loops = [] then
      make(dens(x) * applyintegrand(h, x), x = bds);
    else
      makes(foldl(product, dens(mk_idx(x,loops)), op(loops))
              * applyintegrand(h, x),
            x, bds, loops)
    end if;
  end proc;

  known_continuous := '{Lebesgue(), Uniform(anything, anything),
    Gaussian(anything, anything), Cauchy(anything, anything),
    StudentT(anything, anything, anything),
    BetaD(anything, anything), GammaD(anything, anything)}':

  known_discrete := '{Counting(anything, anything),
    NegativeBinomial(anything), PoissonD(anything)}';

# Step 3 of 3: from Maple LO (linear operator) back to Hakaru

  fromLO := proc(lo :: LO(name, anything), {_ctx :: t_kb := empty}, $)
    local h;
    h := gensym(op(1,lo));
    unintegrate(h, eval(op(2,lo), op(1,lo) = h), _ctx)
  end proc;

  unintegrate := proc(h :: name, e, kb :: t_kb, $)
    local x, c, lo, hi, make, m, mm, w, w0, w1, recognition, subintegral,
          i, kb1, loops, subst, hh, pp, t, bnds;
    if e :: 'And'('specfunc({Int,int})',
                  'anyfunc'('anything','name'='range'('freeof'(h)))) then
      (lo, hi) := op(op([2,2],e));
      x, kb1 := genLebesgue(op([2,1],e), lo, hi, kb);
      subintegral := eval(op(1,e), op([2,1],e) = x);
      (w, m) := unweight(unintegrate(h, subintegral, kb1));
      recognition := recognize_continuous(w, x, lo, hi)
        assuming op(kb_to_assumptions(kb1));
      if recognition :: 'Recognized(anything, anything)' then
        # Recognition succeeded
        (w, w0) := factorize(op(2,recognition), x);
        weight(w0, bind(op(1,recognition), x, weight(w, m)))
      else
        # Recognition failed
        (w, w0) := factorize(w, x);
        m := weight(w, m);
        if hi <> infinity then
          m := piecewise(x < hi, m, Msum())
        end if;
        if lo <> -infinity then
          m := piecewise(lo < x, m, Msum())
        end if;
        weight(w0, bind(Lebesgue(), x, m))
      end if
    elif e :: 'And'('specfunc({Sum,sum})',
                    'anyfunc'('anything','name'='range'('freeof'(h)))) then
      (lo, hi) := op(op([2,2],e));
      x, kb1 := genType(op([2,1],e), HInt(closed_bounds(lo..hi)), kb);
      subintegral := eval(op(1,e), op([2,1],e) = x);
      (w, m) := unweight(unintegrate(h, subintegral, kb1));
      recognition := recognize_discrete(w, x, lo, hi)
        assuming op(kb_to_assumptions(kb1));
      if recognition :: 'Recognized(anything, anything)' then
        (w, w0) := factorize(op(2,recognition), x);
        weight(w0, bind(op(1,recognition), x, weight(w, m)))
      else error "recognize_discrete is never supposed to fail" end if
    elif e :: 'And'('specfunc({Ints,ints,Sums,sums})',
                    'anyfunc'('anything', 'name', 'range'('freeof'(h)),
                              'list(name=range)')) then
      loops := op(4,e);
      bnds  := op(3,e);
      if op(0,e) in {Ints,ints} then
        t := HReal(open_bounds(bnds));
        make := Int;
      else
        t := HInt(closed_bounds(bnds));
        make := Sum;
      end if;
      x, kb1 := genType(op(2,e), mk_HArray(t, loops), kb);
      subintegral := eval(op(1,e), op(2,e) = x);
      (w, m) := unweight(unintegrate(h, subintegral, kb1));
      bnds, loops, kb1 := genLoop(bnds, loops, kb, 'Integrand'(x,[w,m]));
      w, pp := unproducts(w, x, loops, kb1);
      w, w0 := selectremove(depends, convert(w, 'list', `*`), x);
      hh := gensym('ph');
      subintegral := make(pp * applyintegrand(hh,x), x=bnds);
      (w1, mm) := unweight(unintegrate(hh, subintegral, kb1));
      weight(simplify_assuming(`*`(op(w0)) * foldl(product, w1, op(loops)), kb),
        bind(foldl(((mmm,loop) ->
                    Plate(op([2,2],loop) - op([2,1],loop) + 1,
                          op(1,loop),
                          eval(mmm, op(1,loop) = op(1,loop) - op([2,1],loop)))),
                   mm, op(loops)),
             x, weight(`*`(op(w)), m)))
    elif e :: 'applyintegrand'('identical'(h), 'freeof'(h)) then
      Ret(op(2,e))
    elif e = 0 then
      Msum()
    elif e :: `+` then
      map2(unintegrate, h, Msum(op(e)), kb)
    elif e :: `*` then
      (subintegral, w) := selectremove(depends, e, h);
      if subintegral :: `*` then error "Nonlinear integral %1", e end if;
      (w0, w) := selectremove(type, convert(w,'list',`*`), Indicator(anything));
      m := weight(`*`(op(w)), unintegrate(h, subintegral, kb));
      if m :: Weight(anything, anything) then
        m := weight(simplify_assuming(op(1,m), kb), op(2,m));
      end if;
      `if`(nops(w0)=0, m, piecewise(And(op(map2(op,1,w0))),m,Msum()))
    elif e :: t_pw
         and `and`(seq(not (depends(op(i,e), h)),
                       i=1..nops(e)-1, 2)) then
      kb_piecewise(e, kb, ((lhs, kb) -> lhs),
                          ((rhs, kb) -> unintegrate(h, rhs, kb)))
    elif e :: t_case then
      subsop(2=map(proc(b :: Branch(anything, anything))
                     eval(subsop(2='unintegrate'(x,op(2,b),c),b),
                          {x=h, c=kb})
                   end proc,
                   op(2,e)),
             e);
    elif e :: 'Context(anything, anything)' then
      subsop(2=unintegrate(h, op(2,e), assert(op(1,e), kb)), e)
    elif e :: 'integrate'('freeof'(h), 'anything', identical([])) then
      x := mk_sym('x', op(2,e));
      # If we had HType information for op(1,e),
      # then we could use it to tell kb about x.
      (w, m) := unweight(unintegrate(h, applyintegrand(op(2,e), x), kb));
      (w, w0) := factorize(w, x);
      weight(w0, bind(op(1,e), x, weight(w, m)))
    else
      # Failure: return residual LO
      LO(h, e)
    end if
  end proc;

  recognize_continuous := proc(weight0, x, lo, hi, $)
    local Constant, de, Dx, f, w, res, rng;
    res := FAIL;
    # gfun[holexprtodiffeq] contains a test for {radfun,algfun} that seems like
    # it should test for {radfun(anything,x),algfun(anything,x)} instead.
    # Consequently, it issues the error "expression is not holonomic: %1" for
    # actually holonomic expressions such as exp(x*sum(g(i,j),j=1..n)).
    # Moreover, mysolve has trouble solve-ing constraints involving sum, etc.
    # To work around these weaknesses, we wrap sum(...), etc. in Constant[...].
    # Unlike sum(...), Constant[sum(...)] passes the type test {radfun,algfun},
    # which we need to handle exp(x*sum(...)) using gfun[holexprtodiffeq].
    # Like sum(...i...), Constant[sum(...i...)] depends on i, which we need so
    # that product(sum(...i...),i=1..m) doesn't simplify to ...^m.
    w := subsindets[flat](weight0,
           And(# Not(radfun), Not(algfun),
               'specfunc({%product, product, sum, idx})',
               'freeof'(x)),
           proc(e) Constant[e] end);
    w := subsindets[flat](w, {`^`, specfunc(exp)},
           proc(e)
             applyop(proc(e)
                       evalindets[flat](e,
                         And({`^`, specfunc(exp)},
                             Not(radfun), Not(algfun), 'freeof'(x)),
                         proc(e) Constant[e] end)
                     end,
                     -1, e)
             end);
    de := get_de(w, x, Dx, f);
    if de :: 'Diffop(anything, anything)' then
      res := recognize_de(op(de), Dx, f, x, lo, hi)
    end if;
    if res = FAIL then
      rng := hi - lo;
      w := simplify(w * (hi - lo));
      # w could be piecewise and simplify will hide the problem
      if not (rng :: 'SymbolicInfinity'
              or w :: {'SymbolicInfinity', 'undefined'}) then
        res := Recognized(Uniform(lo, hi), w)
      end if
    end if;
    # Undo Constant[...] wrapping
    subsindets[flat](res, 'specindex'(anything, Constant), x -> op(1,x))
  end proc;

  recognize_discrete := proc(w, k, lo, hi, $)
    local se, Sk, f, a0, a1, lambda, r;
    if lo = 0 and hi = infinity then
      se := get_se(w, k, Sk, f);
      if se :: 'Shiftop(anything, anything, identical(ogf))' and
         ispoly(op(1,se), 'linear', Sk, 'a0', 'a1') then
        lambda := normal(-a0/a1*(k+1));
        if not depends(lambda, k) then
          return Recognized(PoissonD(lambda),
                            simplify(eval(w,k=0)/exp(-lambda)));
        end if;
        if ispoly(lambda, 'linear', k, 'b0', 'b1') then
          r := b0/b1;
          return Recognized(NegativeBinomial(r, b1),
                            simplify(eval(w,k=0)/(1-b1)^r))
        end if
      end if;
    end if;
    # fallthrough here is like recognizing Lebesgue for all continuous
    # measures.  Ultimately correct, although fairly unsatisfying.
    Recognized(Counting(lo, hi), w)
  end proc;

  get_de := proc(dens, var, Dx, f, $)
    :: Or(Diffop(anything, set(function=anything)), identical(FAIL));
    local de, init;
    try
      de := gfun[holexprtodiffeq](dens, f(var));
      de := gfun[diffeqtohomdiffeq](de, f(var));
      if not (de :: set) then
        de := {de}
      end if;
      init, de := selectremove(type, de, `=`);
      if nops(de) = 1 then
        if nops(init) = 0 then
          # TODO: Replace {0, 1/2, 1} by PyMC's distribution-specific "testval"
          init := map(proc (val)
                        try f(val) = eval(dens, var=val)
                        catch: NULL
                        end try
                      end proc,
                      {0, 1/2, 1})
        end if;
        return Diffop(DEtools[de2diffop](de[1], f(var), [Dx, var]), init)
      end if
    catch: # do nothing
    end try;
    FAIL
  end proc;

  get_se := proc(dens, var, Sk, u, $)
    :: Or(Shiftop(anything, set(function=anything), name), identical(FAIL));
    local x, de, re, gftype, init, f;
    try
      # ser := series(sum(dens * x^var, var=0..infinity), x);
      # re := gfun[seriestorec](ser, f(var));
      # re, gftype := op(re);
      de := gfun[holexprtodiffeq](sum(dens*x^var, var=0..infinity), f(x));
      re := gfun[diffeqtorec](de, f(x), u(var));
      re := gfun[rectohomrec](re, u(var));
      if not (re :: set) then
        re := {re}
      end if;
      init, re := selectremove(type, re, `=`);
      if nops(re) = 1 then
        if nops(init) = 0 then
          init := {u(0) = eval(rens, var=0)};
        end if;
        re := map(proc(t)
                    local s, r;
                    s, r := selectremove(type, convert(t, 'list', `*`),
                                         u(polynom(nonnegint, var)));
                    if nops(s) <> 1 then
                      error "rectohomrec result nonhomogeneous";
                    end if;
                    s := op([1,1],s) - var;
                    if s :: nonnegint and r :: list(polynom(anything, var)) then
                      `*`(op(r), Sk^s);
                    else
                      error "unexpected result from rectohomrec"
                    end if
                  end proc,
                  convert(re[1], 'list', `+`));
        return Shiftop(`+`(op(re)), init, 'ogf')
      end if
    catch: # do nothing
    end try;
    FAIL
  end proc;

  recognize_de := proc(diffop, init, Dx, f, var, lo, hi, $)
    local dist, ii, constraints, w, a0, a1, a, b0, b1, c0, c1, c2, loc, nu;
    dist := FAIL;
    if lo = -infinity and hi = infinity
       and ispoly(diffop, 'linear', Dx, 'a0', 'a1') then
      a := normal(a0/a1);
      if ispoly(a, 'linear', var, 'b0', 'b1') then
        dist := Gaussian(-b0/b1, sqrt(1/b1))
      elif ispoly(numer(a), 'linear', var, 'b0', 'b1') and
           ispoly(denom(a), 'quadratic', var, 'c0', 'c1', 'c2') then
        loc := -c1/c2/2;
        if Testzero(b0 + loc * b1) then
          nu := b1/c2 - 1;
          if Testzero(nu - 1) then
            dist := Cauchy(loc, sqrt(c0/c2-loc^2))
          else
            dist := StudentT(nu, loc, sqrt((c0/c2-loc^2)/nu))
          end if
        end if
      end if;
    elif lo = 0 and hi = 1
         and ispoly(diffop, 'linear', Dx, 'a0', 'a1')
         and ispoly(normal(a0*var*(1-var)/a1), 'linear', var, 'b0', 'b1') then
      dist := BetaD(1-b0, 1+b0+b1)
    elif lo = 0 and hi = infinity
         and ispoly(diffop, 'linear', Dx, 'a0', 'a1')
         and ispoly(normal(a0*var/a1), 'linear', var, 'b0', 'b1') then
      dist := GammaD(1-b0, 1/b1)
    end if;
    if dist <> FAIL then
      try
        ii := map(convert, init, 'diff');
        constraints := eval(ii, f = (x -> w*density[op(0,dist)](op(dist))(x)));
        w := eval(w, mysolve(simplify(constraints), w));
        if not (has(w, 'w')) then
          return Recognized(dist, simplify(w))
        end if
      catch: # do nothing
      end try;
      WARNING("recognized %1 as %2 but could not solve %3", f, dist, init)
    end if;
    FAIL
  end proc;

  mysolve := proc(constraints)
    # This wrapper around "solve" works around the problem that Maple sometimes
    # thinks there is no solution to a set of constraints because it doesn't
    # recognize the solution to each constraint is the same.  For example--
    # This fails     : solve({c*2^(-1/2-alpha) = sqrt(2)/2, c*4^(-alpha) = 2^(-alpha)}, {c}) assuming alpha>0;
    # This also fails: solve(simplify({c*2^(-1/2-alpha) = sqrt(2)/2, c*4^(-alpha) = 2^(-alpha)}), {c}) assuming alpha>0;
    # But this works : map(solve, {c*2^(-1/2-alpha) = sqrt(2)/2, c*4^(-alpha) = 2^(-alpha)}, {c}) assuming alpha>0;
    # And the difference of the two solutions returned simplifies to zero.

    local result;
    if nops(constraints) = 0 then return NULL end if;
    result := solve(constraints, _rest);
    if result <> NULL or not (constraints :: {set,list}) then
      return result
    end if;
    result := mysolve(subsop(1=NULL,constraints), _rest);
    if result <> NULL
       and op(1,constraints) :: 'anything=anything'
       and simplify(eval(op([1,1],constraints) - op([1,2],constraints),
                         result)) <> 0 then
      return NULL
    end if;
    result
  end proc;

  unweight := proc(m, $)
    local total, ww, mm;
    if m :: 'Weight(anything, anything)' then
      op(m)
    elif m :: 'specfunc(Msum)' then
      total := `+`(op(map((mi -> unweight(mi)[1]), m)));
      (total, map((mi -> weight(1/total, mi)), m))
    else
      (1, m)
    end if;
  end proc;

  factorize := proc(w, x, $)
    if w :: `*` then
      selectremove(depends, w, x)
    elif depends(w, x) then
      (w, 1)
    else
      (1, w)
    end if
  end proc;

  ###
  # smart constructors for our language

  bind := proc(m, x, n, $)
    if n = 'Ret'(x) then
      m # monad law: right identity
    elif m :: 'Ret(anything)' then
      eval(n, x = op(1,m)) # monad law: left identity
    else
      'Bind(_passed)'
    end if;
  end proc;

  weight := proc(p, m, $)
    if p = 1 then
      m
    elif p = 0 then
      Msum()
    elif m :: 'Weight(anything, anything)' then
      weight(p * op(1,m), op(2,m))
    else
      'Weight(_passed)'
    end if;
  end proc;

# Step 2 of 3: computer algebra

  improve := proc(lo :: LO(name, anything), {_ctx :: t_kb := empty}, $)
    LO(op(1,lo), reduce(op(2,lo), op(1,lo), _ctx))
  end proc;

  # Walk through integrals and simplify, recursing through grammar
  # h - name of the linear operator above us
  # kb - domain information
  reduce := proc(ee, h :: name, kb :: t_kb, $)
    local e, subintegral, w, ww, x, c, kb1;
    e := elim_intsum(ee, h, kb);
    if e :: 'And(specfunc({Int,Sum}), anyfunc(anything,name=range))' then
      x, kb1 := `if`(op(0,e)=Int,
        genLebesgue(op([2,1],e), op([2,2,1],e), op([2,2,2],e), kb),
        genType(op([2,1],e), HInt(closed_bounds(op([2,2],e))), kb));
      reduce_IntSum(op(0,e),
        reduce(subs(op([2,1],e)=x, op(1,e)), h, kb1), h, kb1, kb)
    elif e :: 'Ints(anything, name, range, list(name=range))' then
      x, kb1 := genType(op(2,e),
                        mk_HArray(HReal(open_bounds(op(3,e))), op(4,e)),
                        kb);
      reduce_IntsSums(Ints, reduce(subs(op(2,e)=x, op(1,e)), h, kb1), x,
        op(3,e), op(4,e), h, kb1)
    elif e :: 'Sums(anything, name, range, list(name=range))' then
      x, kb1 := genType(op(2,e),
                        mk_HArray(HInt(closed_bounds(op([3,1],e))), op(4,e)),
                        kb);
      reduce_IntsSums(Sums, reduce(subs(op(2,e)=x, op(1,e)), h, kb1), x,
        op(3,e), op(4,e), h, kb1)
    elif e :: `+` then
      map(reduce, e, h, kb)
    elif e :: `*` then
      (subintegral, w) := selectremove(depends, e, h);
      if subintegral :: `*` then error "Nonlinear integral %1", e end if;
      subintegral := convert(reduce(subintegral, h, kb), 'list', `*`);
      (subintegral, ww) := selectremove(depends, subintegral, h);
      reduce_pw(simplify_assuming(`*`(w, op(ww)), kb))
        * `*`(op(subintegral));
    elif e :: t_pw then
      e := kb_piecewise(e, kb, simplify_assuming,
                        ((rhs, kb) -> %reduce(rhs, h, kb)));
      e := eval(e, %reduce=reduce);
      # big hammer: simplify knows about bound variables, amongst many
      # other things
      Testzero := x -> evalb(simplify(x) = 0);
      reduce_pw(e)
    elif e :: t_case then
      subsop(2=map(proc(b :: Branch(anything, anything))
                     eval(subsop(2='reduce'(op(2,b),x,c),b),
                          {x=h, c=kb})
                   end proc,
                   op(2,e)),
             e);
    elif e :: 'Context(anything, anything)' then
      applyop(reduce, 2, e, h, assert(op(1,e), kb))
    elif e :: 'integrate(anything, Integrand(name, anything), list)' then
      x := gensym(op([2,1],e));
      # If we had HType information for op(1,e),
      # then we could use it to tell kb about x.
      subsop(2=Integrand(x, reduce(subs(op([2,1],e)=x, op([2,2],e)), h, kb)), e)
    else
      simplify_assuming(e, kb)
    end if;
  end proc;

  reduce_IntSum := proc(mk :: identical(Int, Sum),
                        ee, h :: name, kb1 :: t_kb, kb0 :: t_kb, $)
    local e, dom_spec, w, rest, var, new_rng, make, i;

    # if there are domain restrictions, try to apply them
    (dom_spec, e) := get_indicators(ee);
    rest := kb_subtract(foldr(assert, kb1, op(dom_spec)), kb0);
    new_rng, rest := selectremove(type, rest,
      {`if`(mk=Int, [identical(genLebesgue), name, anything, anything], NULL),
       `if`(mk=Sum, [identical(genType), name, specfunc(HInt)], NULL),
       [identical(genLet), name, anything]});
    if not (new_rng :: [list]) then
      error "kb_subtract should return exactly one gen*"
    end if;
    make    := mk;
    new_rng := op(new_rng);
    var     := op(2,new_rng);
    if op(1,new_rng) = genLebesgue then
      new_rng := op(3,new_rng)..op(4,new_rng);
    elif op(1,new_rng) = genType then
      new_rng := range_of_HInt(op(3,new_rng));
    else # op(1,new_rng) = genLet
      if mk=Int then return 0 else make := eval; new_rng := op(3,new_rng) end if
    end if;
    dom_spec, rest := selectremove(depends,
      map(proc(a::[identical(assert),anything]) op(2,a) end proc, rest), var);
    if type(e, `*`) then
      (e, w) := selectremove(depends, e, var); # pull out weight
      w := simplify_assuming(w, kb1);
    else
      w := 1;
    end if;
    e := make(`if`(dom_spec=[], e, piecewise(And(op(dom_spec)), e, 0)),
              var=new_rng);
    e := w*elim_intsum(e, h, kb0);
    e := mul(Indicator(i), i in rest)*e;
    e
  end proc;

  reduce_IntsSums := proc(makes, ee, var::name, rng, bds, h::name, kb::t_kb, $)
    # TODO we should apply domain restrictions like reduce_IntSum does.
    makes(ee, var, rng, bds);
  end proc;

  get_indicators := proc(e, $)
    local sub, inds, rest;
    if e::`*` then
      sub := map((s -> [get_indicators(s)]), [op(e)]);
      `union`(op(map2(op,1,sub))), `*`(op(map2(op,2,sub)))
    elif e::`^` then
      inds, rest := get_indicators(op(1,e));
      inds, subsop(1=rest, e)
    elif e::'Indicator(anything)' then
      {op(1,e)}, 1
    else
      {}, e
    end if
  end proc;

  elim_intsum := proc(ee, h :: name, kb :: t_kb, $)
    local e, hh, m, var, elim, my;

    e := ee;
    do
      hh := gensym('h');
      if e :: Int(anything, name=anything) and
         not hastype(op(1,e), 'applyintegrand'('identical'(h),
                                               'dependent'(op([2,1],e)))) then
        var := op([2,1],e);
        m := LO(hh, my(kb, int, applyintegrand(hh,var), op(2,e)));
      elif e :: Sum(anything, name=anything) and
         not hastype(op(1,e), 'applyintegrand'('identical'(h),
                                               'dependent'(op([2,1],e)))) then
        var := op([2,1],e);
        m := LO(hh, my(kb, sum, applyintegrand(hh,var), op(2,e)));
      elif e :: Ints(anything, name, range, list(name=range)) and
           not hastype(op(1,e), 'applyintegrand'('identical'(h),
                                                 'dependent'(op(2,e)))) then
        var := op(2,e);
        m := LO(hh, my(kb, ((e,x,r,l)->ints(e,x,r,l,kb)),
                       applyintegrand(hh,var), op(2..4,e)));
      elif e :: Sums(anything, name, range, list(name=range)) and
           not hastype(op(1,e), 'applyintegrand'('identical'(h),
                                                 'dependent'(op(2,e)))) then
        var := op(2,e);
        m := LO(hh, my(kb, ((e,x,r,l)->sums(e,x,r,l,kb)),
                       applyintegrand(hh,var), op(2..4,e)));
      else
        break;
      end if;
      # try to eliminate unused var
      elim := eval(banish(m, var, h, op(1,e), infinity), my=do_elim_intsum);
      if has(elim, {MeijerG, undefined})
         or elim_metric(elim,h) >= elim_metric(e,h) then
        # Maple was too good at integration
        break;
      end if;
      e := elim;
    end do;
    e;
  end proc;

  do_elim_intsum := proc(kb, f, ee)
    local e;
    e := simplify_assuming(ee,kb);
    e := simplify_assuming(f(e,_rest), kb);
    subs(int=Int, ints=Ints, sum=Sum, sums=Sums, e)
  end proc;

  elim_metric := proc(e, h::name, $)
    numboccur(e, select(hastype,
      indets(e, specfunc({Int,Sum,int,sum,Ints,Sums,ints,sums})),
      'applyintegrand'('identical'(h), 'anything')))
  end proc;

  Banish := proc(e :: Int(anything, name=anything), h :: name,
                 levels :: extended_numeric := infinity, $)
    local hh;
    hh := gensym('h');
    subs(int=Int,
      banish(LO(hh, int(applyintegrand(hh,op([2,1],e)), op(2,e))),
        op([2,1],e), h, op(1,e), levels));
  end proc;

  banish := proc(m, x :: name, h :: name, g, levels :: extended_numeric, $)
    # LO(h, banish(m, x, h, g)) should be equivalent to Bind(m, x, LO(h, g))
    # but performs integration over x innermost rather than outermost.
    local guard, subintegral, w, y, yRename, lo, hi, mm, loops, xx, hh, gg, ll;
    guard := proc(m, c) Bind(m, x, piecewise(c, Ret(x), Msum())) end proc;
    if g = 0 then
      0
    elif levels <= 0 then
      integrate(m, Integrand(x, g), []) # is [] right ?
    elif not depends(g, x) then
      integrate(m, x->1, []) * g
    elif g :: `+` then
      map[4](banish, m, x, h, g, levels)
    elif g :: `*` then
      (subintegral, w) := selectremove(depends, g, h);
      if subintegral :: `*` then error "Nonlinear integral %1", g end if;
      banish(Bind(m, x, Weight(w, Ret(x))), x, h, subintegral, levels)
    elif g :: 'And'('specfunc({Int,int,Sum,sum})',
                    'anyfunc'('anything','name'='range'('freeof'(h)))) then
      subintegral := op(1, g);
      y           := op([2,1], g);
      lo, hi      := op(op([2,2], g));
      if x = y or depends(m, y) then
        yRename     := gensym(y);
        subintegral := subs(y=yRename, subintegral);
        y           := yRename;
      end if;
      mm := m;
      if depends(lo, x) then
        mm := guard(mm, lo<y);
        lo := -infinity;
      end if;
      if depends(hi, x) then
        mm := guard(mm, y<hi);
        hi := infinity;
      end if;
      op(0,g)(banish(mm, x, h, subintegral, levels-1), y=lo..hi)
    elif g :: 'And'('specfunc({Ints,ints,Sums,sums})',
                    'anyfunc'('anything', 'name', 'range'('freeof'(h)),
                              'list(name=range)')) then
      subintegral := op(1, g);
      y           := op(2, g);
      lo, hi      := op(op(3, g));
      loops       := op(4, g);
      xx          := map(lhs, loops);
      if x = y or depends(m, y) then
        yRename     := gensym(y);
        subintegral := subs(y=yRename, subintegral);
        y           := yRename;
      end if;
      mm := m;
      if depends(lo, x) then
        mm := guard(mm, forall(xx, lo<mk_idx(y,loops)));
        lo := -infinity;
      end if;
      if depends(hi, x) then
        mm := guard(mm, forall(xx, mk_idx(y,loops)<hi));
        hi := infinity;
      end if;
      op(0,g)(banish(mm, x, h, subintegral, levels-1), y, lo..hi, op(4,g));
    elif g :: t_pw then
      foldr_piecewise(
        proc(cond, th, el) proc(m)
          if depends(cond, x) then
            banish(guard(m, cond), x, h, th, levels-1) + el(guard(m, Not(cond)))
          else
            piecewise_if(cond, banish(m, x, h, th, levels-1), el(m))
          end if
        end proc end proc,
        proc(m) 0 end proc,
        g)(m)
    elif g :: t_case then
      subsop(2=map(proc(b :: Branch(anything, anything))
                     eval(subsop(2='banish'(op(2,b),xx,hh,gg,ll),b),
                          {xx=x, hh=h, gg=g, ll=l})
                   end proc,
                   op(2,integral)),
             integral);
    elif g :: 'integrate(freeof(x), Integrand(name, anything), list)' then
      y := gensym(op([2,1],g));
      subsop(2=Integrand(y, banish(m, x, h,
        subs(op([2,1],g)=y, op([2,2],g)), levels-1)), g)
    else
      integrate(m, Integrand(x, g), [])
    end if
  end proc;

  reduce_pw := proc(ee, $) # ee may or may not be piecewise
    local e;
    e := nub_piecewise(ee);
    if e :: t_pw then
      if nops(e) = 2 then
        return Indicator(op(1,e)) * op(2,e)
      elif nops(e) = 3 and Testzero(op(2,e)) then
        return Indicator(Not(op(1,e))) * op(3,e)
      elif nops(e) = 4 and Testzero(op(2,e)) then
        return Indicator(And(Not(op(1,e)),op(3,e))) * op(4,e)
      end if
    end if;
    return e
  end proc;

  nub_piecewise := proc(pw, $) # pw may or may not be piecewise
    foldr_piecewise(piecewise_if, 0, pw)
  end proc;

  piecewise_if := proc(cond, th, el, $)
    # piecewise_if should be equivalent to `if`, but it produces
    # 'piecewise' and optimizes for when the 3rd argument is 'piecewise'
    if cond = true then
      th
    elif cond = false or Testzero(th - el) then
      el
    elif el :: t_pw then
      if nops(el) >= 2 and Testzero(th - op(2,el)) then
        applyop(Or, 1, el, cond)
      else
        piecewise(cond, th, op(el))
      end if
    elif Testzero(el) then
      piecewise(cond, th)
    else
      piecewise(cond, th, el)
    end if
  end proc;

  # this code should not currently be used, it is just a snapshot in time
  Reparam := proc(e::Int(anything,name=range), h::name)
    local body, var, inds, xx, inv, new_e;

    # TODO improve the checks.
    if not has(body, {Int,int}) and hastype(e,'specfunc(applyintegrand)') then
      inds := indets(body, 'applyintegrand'('identical'(h), 'dependent'(var)));
      if nops(inds)=1 and op(2,inds[1]) :: algebraic and
         not hastype(body, t_pw) then
        xx := gensym('xx');
        inv := solve({op(2,inds[1])=xx}, {var});
        try
          new_e := IntegrationTools[Change](e, inv, xx);
          if not has(new_e,{'limit'}) then e := new_e end if;
        catch:
          # this will simply not change e
        end try;
      end if;
    end if;

    e;
  end proc;

  ReparamDetermined := proc(lo :: LO(name, anything))
    local h;
    h := op(1,lo);
    LO(h,
       evalindets(op(2,lo),
                  'And'('specfunc({Int,int})',
                        'anyfunc'(anything, 'name=anything')),
                  g -> `if`(determined(op(1,g),h), Reparam(g,h), g)))
  end proc;

  determined := proc(e, h :: name)
    local i;
    for i in indets(e, 'specfunc({Int,int})') do
      if hastype(IntegrationTools:-GetIntegrand(i),
           'applyintegrand'('identical'(h),
             'dependent'(IntegrationTools:-GetVariable(i)))) then
        return false
      end if
    end do;
    return true
  end proc;

  Reparam := proc(e :: Int(anything, name=anything), h :: name)
    'procname(_passed)' # TODO to be implemented
  end proc;

  ###
  # prototype disintegrator - main entry point
  disint := proc(lo :: LO(name,anything), t::name)
    local h, integ, occurs, oper_call, ret, var, plan;
    h := gensym(op(1,lo));
    integ := eval(op(2,lo), op(1,lo) = h);
    map2(LO, h, disint2(integ, h, t, []));
  end proc;

  find_vars := proc(l)
    local NONE; # used as a placeholder
    map(proc(x) 
          if type(x, specfunc(%int)) then op([1,1],x)
          elif type(x, specfunc(%weight)) then NONE
          else error "don't know about command (%1)", x
          end if end proc,
         l);
  end proc;

  # this generates a KB loaded up with the knowledge gathered along
  # the current path, as well as the (potentially renamed) current path
  # there should actually not be any renaming, but let's see if that
  # invariant actually holds.
  kb_from_path := proc(path)
    local res;
    # foldr(((b,kb) -> assert_deny(b, pol, kb)), kb, op(bb))
    res := foldr(proc(b,info)
          local x, lo, hi, p, kb;
          (kb, p) := op(info);
          if type(b, specfunc(%int)) then 
            (lo, hi) := op(op([1,2],b));
            x, kb := genLebesgue(op([1,1], b), lo, hi, kb);
            [kb, [ %int(x = lo..hi), p]];
          elif type(b, specfunc(%weight)) then 
            [kb, [ b, p ]];
          else error "don't know about command (%1)", x
          end if end proc,
         [empty, []], op(path));
    (res[1], ListTools:-Flatten(res[2]));
  end proc;

  # only care about bound variables, not globals
  get_var_pos := proc(v, l)
    local p;
    if member(v, l, 'p') then VarPos(v,p) else NULL end if;
  end proc;

  invert := proc(to_invert, main_var, integral, h, path, t)
    local sol, dxdt, vars, in_sol, r_in_sol, p_mv, would_capture, flip, 
      kb, npath;
    if type(to_invert, 'linear'(main_var)) then
      sol := solve([t = to_invert], {main_var})[1];

    else
      # TODO: split domain.
      # right now, assume that if solve returns a single answer, it's ok!
      sol := solve([t = to_invert], {main_var});
      if not (nops(sol) = 1) then
        error "non-linear inversion needed: %1 over %2", to_invert, main_var;
      else
        sol := sol[1];
      end if;
    end if;

    dxdt := diff(op(2, sol), t);
    (kb, npath) := kb_from_path(path);
    kb := assert(t::real, kb);
    flip := simplify_assuming(signum(dxdt), kb);
      # [t = -infinity .. infinity, op(kb_from_path(path))]);
    if not member(flip, {1,-1}) then
      error "derivative has symbolic sign (%1), what do we do?", flip
    end if;

    # we need to figure out what variables the solution depends on,
    # and what plan that entails
    vars := find_vars(npath);
    in_sol := indets(sol, 'name') minus {t, main_var};

    member(main_var, vars, 'p_mv');
    r_in_sol := map(get_var_pos, in_sol, vars);
    would_capture := map2(op, 1, r_in_sol);

    # May have to pull the integral for main_var up a few levels
    interpret(
      [ %WouldCapture(main_var, p_mv, [seq(i, i in would_capture)])
      , %Change(main_var, t = to_invert, sol, flip)
      , %ToTop(t)
      , %Drop(t)],
      npath, abs(dxdt) * 'applyintegrand'(h, eval(op([2,2],integral), sol)));
  end proc;

  # basic algorithm:
  # - follow the syntax
  # - collect the 'path' traversed (aka the "heap"); allows reconstruction
  # - when we hit a Ret, figure out the change of variables
  # - note that the callee is responsible for "finishing up"
  disint2 := proc(integral, h::name, t::name, path)
    local x, lo, hi, subintegral, w, m, w0, perform, script, vars,
      to_invert, sol, occurs, dxdt, update;
    if integral :: 'And'('specfunc({Int,int})',
                         'anyfunc'('anything','name'='range'('freeof'(h)))) then
      x := op([2,1],integral);
      (lo, hi) := op(op([2,2],integral));
      perform := %int(op(2,integral));
      # TODO: enrich kb with x (measure class lebesgue)
      disint2(op(1,integral), h, t, [perform, op(path)]);
    elif integral :: 'applyintegrand'('identical'(h), 'freeof'(h)) then
      if not type(op(2,integral), specfunc(Pair)) then
        # this should probably be type-checked at the top!
        error "must return a Pair to enable disintegration";
      end if;
      to_invert := op([2,1], integral);
      vars := convert(find_vars(path),'set');
      occurs := remove(type, indets(to_invert, 'name'), 'constant') intersect vars;
      if nops(occurs) = 0 then
        error "cannot invert constant (%1)", to_invert
      else
        map[2](invert, to_invert, occurs, integral, h, path, t);
      end if;
    elif integral = 0 then
      error "cannot disintegrate 0 measure"
    elif integral :: `+` then
      sol := map(disint2, convert(integral, 'list'), h, t, path);
      error "on a `+`, got", sol;
    elif integral :: `*` then
      (subintegral, w) := selectremove(depends, integral, h);
      if subintegral :: `*` then error "Nonlinear integral %1", integral end if;
      disint2(subintegral, h, t, [%weight(w), op(path)]);
    elif integral :: t_pw
         and `and`(seq(not (depends(op(i,integral), h)),
                       i=1..nops(integral)-1, 2)) then
      error "need to map into piecewise";
      kb_piecewise(integral, kb,
                   ((lhs, kb) -> lhs),
                   ((rhs, kb) -> unintegrate(h, rhs, kb)))
    elif integral :: 'integrate'('freeof'(h), 'anything', identical([])) then
      x := mk_sym('x', op(2,integral));
      # we would be here mostly if the measure being passed in is
      # not known.  So error is fine, and should likely be caught
      # elsewhere
      error "what to do with (%1)", integral;
      # If we had HType information for op(1,e),
      # then we could use it to tell kb about x.
      (w, m) := unweight(unintegrate(h, applyintegrand(op(2,integral), x), kb));
      (w, w0) := factorize(w, x);
      weight(w0, bind(op(1,integral), x, weight(w, m)))
    else
      # Failure
      # LO(h, integral)
      error "why are we here?";
    end if
  end proc;

  # single step of reconstruction
  reconstruct := proc(step, part)
    if type(step, specfunc(%int)) then
      Int(part, op(1, step));
    elif type(step, specfunc(%weight)) then
      op(1, step) * part
    else
      error "how to reconstruct (%1)", step
    end if;
  end proc;

  get_int_pos := proc(var, path)
    local finder;
    finder := proc(loc) 
      if type(op(loc,path),specfunc(%int)) and op([loc,1,1], path) = var then
        loc
      else
        NULL # cheating...
      end if
    end proc;
    seq(finder(i),i=1..nops(path)); 
  end proc;

  change_var := proc(act, chg, path, part)
    local bds, new_upper, new_lower, np, new_path, flip, var, finder, pos,
       DUMMY, kb, as;

    # first step: get ourselves a kb from this path
    (kb, np) := kb_from_path(path);
    as := kb_to_assumptions(kb);

    # second step, find where the relevant integral is
    var := op(1,act);
    pos := get_int_pos(var, np);
    new_path := eval(subsop(pos=DUMMY, np), op(3,act));

    bds := op([pos,1,2], path);
    new_upper := limit(op([2,2], act), op(1, act) = op(2,bds), left)
      assuming op(as);
    new_lower := limit(op([2,2], act), op(1, act) = op(1,bds), right)
      assuming op(as);
    flip := op(4,act);
    if flip=-1 then
      (new_lower, new_upper) := (new_upper, new_lower);
    end if;
    if new_upper = infinity and new_lower = -infinity then
      # we're done with this integral, put it back on path
      new_path := subsop(pos = %int(t = -infinity .. infinity), new_path);
      interpret(chg, new_path, part)
    else
      # right now, putting in new constraints "innermost", while
      # they really ought to be floated up as far as possible.
      # Probably leave that to improve?
      new_path := subsop(pos = %int(t = new_lower.. new_upper), new_path);
      interpret(chg, new_path,
        piecewise(And(new_lower < t, t < new_upper), part, 0));
    end if;
  end proc;

  # avoid_capture is essentially "inverse banish", where we pull integrals
  # up rather than pushing them down.  The list contains which variables
  # would be captured by the 'main' one.  %Top is a special variable that
  # just means that we should just push the one integral to the top, but
  # there's no need to rearrange anything else.
  avoid_capture := proc(task :: %WouldCapture(name, posint, list), chg, path, part)
    local x, p, here, there, vars, new_path, go_past, to_top, work, n, pos, 
      y, v, scope;

    go_past := convert(map2(op, 1, op(3,task)), 'set');
    to_top := member(%Top, go_past);
    if to_top and nops(go_past)>1 then
      error "cannot ask to promote to top and past some variables";
    end if;

    if nops(go_past)=0 then # nothing to do, next
      interpret(chg, path, part)
    else
      n := nops(path);
      x := op(1,task);
      p := op(2,task);

      if p = n and to_top then
        return interpret(chg, path, part)
      end if;

      # two-pass algorithm:
      # 1. push the integral on the main variable "up", past the others
      # 2. push all the weights "down" into scope

      # for efficiency, work with a table, not a list
      pos := p+1;
      work := evalb(pos <= n);
      new_path := table(path);
      here  := path[p];

      # first pass
      while work do
        y := new_path[pos];
        if type(y, specfunc(%weight)) then
          new_path[pos-1] := y;
          new_path[pos] := here;
          pos := pos + 1;
        elif type(y, specfunc(%int)) then
          v := op([1,1], y);
          go_past := go_past minus {v};
          # TODO: surely we're missing a test here for the bounds
          new_path[pos-1] := y;
          new_path[pos] := here;
          pos := pos + 1;
          work := evalb(go_past = {} and pos <= n);
        else
          error "How do I move past a %1 ?", eval(y);
        end if;
      end do;

      # second pass
      scope := NULL;
      for pos from n to 2 by -1 do
        y := new_path[pos];
        if type(y, specfunc(%int)) then
          scope := op([1,1], y), scope;
        elif type(y, specfunc(%weight)) then
          vars := indets(y, 'name');
          vars := `if`(member(x, vars), vars union go_past, vars);
          vars := vars intersect go_past;
          if vars <> {} then # if no problem vars, keep going
            there := new_path[pos-1];
            if type(there, specfunc(%int)) then
              # TODO: surely we're missing a test here for the bounds
              scope := op([1,1], there), scope;
              new_path[pos-1] := y;
              new_path[pos] := there;
            elif type(there, specfunc(%weight)) then
              new_path[pos-1] := %weight(op(1,y) * op(1, there));
              new_path[pos] := %weight(1); # don't mess up the length
            else
              error "how do I move a weight below a %1", there;
            end if;
          end if;
        else
          error "How do I move below a %1 ?", y;
        end if;
      end do;

      interpret(chg, [seq(new_path[i], i=1..nops(path))], part);
    end if;
  end proc;

  # interpret a plan
  # chg : plan of what needs to be done
  # path : context, allows one to reconstruct the incoming expression
  # part: partial answer
  interpret := proc(chg, path, part)
    local i, ans, pos, var;
    if path=[] then part
    elif chg=[] then # finished changes, just reconstruct
      ans := part;
      for i from 1 to nops(path) do
        ans := reconstruct(path[i], ans);
      end do;
      return ans;
    elif type(chg[1], specfunc(%Change)) then
      change_var(chg[1], chg[2..-1], path, part);
    elif type(chg[1], specfunc(%WouldCapture)) then
      avoid_capture(chg[1], chg[2..-1], path, part);
    elif type(chg[1], specfunc(%ToTop)) then
      var := op([1,1], chg);
      if type(path[-1], specfunc(%int)) and op([-1,1,1], path) = var then
        interpret(chg[2..-1], path, part)
      else

        pos := get_int_pos(var, path);
        interpret([%WouldCapture(var, pos, [%Top]), op(2..-1,chg)], path, part); 
      end if;
    elif type(chg[1], specfunc(%Drop)) then
      if type(path[-1], specfunc(%int)) and op([-1,1,1], path) = op([1,1], chg) then
        interpret(chg[2..-1], path[1..-2], part)
      else
        error "asked to drop t-integral (%1, %2), but it is not at top ",
          path, part
      end if;
    else
      error "unknown plan step: %1", chg[1]
    end if;
  end proc;

  density[Lebesgue] := proc($) proc(x,$) 1 end proc end proc;
  density[Uniform] := proc(a,b,$) proc(x,$)
    1/(b-a)
  end proc end proc;
  density[Gaussian] := proc(mu, sigma, $) proc(x,$)
    1/sigma/sqrt(2)/sqrt(Pi)*exp(-(x-mu)^2/2/sigma^2)
  end proc end proc;
  density[Cauchy] := proc(loc, scale, $) proc(x,$)
    1/Pi/scale/(1+((x-loc)/scale)^2)
  end proc end proc;
  density[StudentT] := proc(nu, loc, scale, $) proc(x,$)
    GAMMA((nu+1)/2) / GAMMA(nu/2) / sqrt(Pi*nu) / scale
    * (1 + ((x-loc)/scale)^2/nu)^(-(nu+1)/2)
  end proc end proc;
  density[BetaD] := proc(a, b, $) proc(x,$)
    x^(a-1)*(1-x)^(b-1)/Beta(a,b)
  end proc end proc;
  # Hakaru uses the alternate definition of gamma, so the args are backwards
  density[GammaD] := proc(shape, scale, $) proc(x,$)
    x^(shape-1)/scale^shape*exp(-x/scale)/GAMMA(shape);
  end proc end proc;
  density[Counting] := proc(lo, hi, $) proc(k,$)
    1
  end proc end proc;
  density[NegativeBinomial] := proc(r, p, $) proc(k,$)
    p^k * (1-p)^r * GAMMA(r+k) / GAMMA(k+1) / GAMMA(r)
  end proc end proc;
  density[PoissonD] := proc(lambda, $) proc(k,$)
    lambda^k/exp(lambda)/k!
  end proc end proc;

  bounds[Lebesgue] := proc($) -infinity .. infinity end proc;
  bounds[Uniform] := proc(a, b, $) a .. b end proc;
  bounds[Gaussian] := proc(mu, sigma, $) -infinity .. infinity end proc;
  bounds[Cauchy] := proc(loc, scale, $) -infinity .. infinity end proc;
  bounds[StudentT] := proc(nu, loc, scale, $) -infinity .. infinity end proc;
  bounds[BetaD] := proc(a, b, $) 0 .. 1 end proc;
  bounds[GammaD] := proc(shape, scale, $) 0 .. infinity end proc;
  bounds[Counting] := `..`;
  bounds[NegativeBinomial] := proc(r, p, $) 0 .. infinity end proc;
  bounds[PoissonD] := proc(lambda, $) 0 .. infinity end proc;

  mk_sym := proc(var :: name, h, $)
    local x;
    x := var;
    if h :: 'Integrand(name, anything)' then
      x := op(1,h);
    elif h :: 'procedure' then
      x := op(1, [op(1,h), x]);
    end if;
    gensym(x)
  end proc;

  mk_ary := proc(e, loops :: list(name = range), $)
    foldl((res, i) -> ary(op([2,2],i) - op([2,1],i) + 1,
                          op(1,i),
                          eval(res, op(1,i) = op(1,i) + op([2,1],i))),
          e, op(loops));
  end proc;

  mk_idx := proc(e, loops :: list(name = range), $)
    foldr((i, res) -> idx(res, op(1,i) - op([2,1],i)),
          e, op(loops));
  end proc;

  mk_HArray := proc(t::t_type, loops::list(name=range), $)
    local res, i;
    res := t;
    for i in loops do res := HArray(res) end do;
    res
  end proc;

  ModuleLoad := proc($)
    local prev;
    Hakaru; # Make sure the KB module is loaded, for the type t_type
    KB;     # Make sure the KB module is loaded, for the type t_kb
    prev := kernelopts(opaquemodules=false);
    try
      PiecewiseTools:-InertFunctions := PiecewiseTools:-InertFunctions
        union '{Integrand,LO,lam,Branch,Bind,ary,
                forall,Ints,Sums,ints,sums,`..`}';
    finally
      kernelopts(opaquemodules=prev);
    end try;
  end proc;

  ModuleLoad();

end module; # NewSLO
