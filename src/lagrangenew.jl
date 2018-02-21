"""
  lagrangesolve(graph)
  solve graph using lagrange decomposition
"""
function lagrangesolve(graph;max_iterations=10,update_method=:subgradient,ϵ=0.001,timelimit=3600,α=2,lagrangeheuristic=fixbinaries,initialmultipliers=:zero)
  lgprepare(graph)
  n = graph.attributes[:normalized]

  if initialmultipliers == :relaxation
    initialrelaxation(graph)
  end

  starttime = time()
  s = Solution(method=:dual_decomposition)
  λ = graph.attributes[:λ]
  x = graph.attributes[:x]
  res = graph.attributes[:res]
  nmult = graph.attributes[:numlinks]
  nodes = [node for node in values(getnodes(graph))]
  graph.attributes[:α] = α
  iterval = 0



  for iter in 1:max_iterations
    variant = iter == 1 ? :default : update_method # Use default version in the first iteration

    iterstart = time()
    # Solve subproblems
    Zk = 0
    for node in nodes
       (x,Zkn) = solvenode(node,λ,x,variant)
       Zk += Zkn
    end
    Zk *= n
    graph.attributes[:Zk] = Zk
    graph.attributes[:x] = x


    # Update residuals
    res = x[:,1] - x[:,2]
    graph.attributes[:res] = res

    itertime = time() - iterstart
    tstamp = time() - starttime
    saveiteration(s,tstamp,[iterval,Zk,itertime],n)

    # Check convergence
    if norm(res) < ϵ
      s.termination = "Optimal"
      return s
    end

    # Update multipliers
    (λ, iterval) = updatemultipliers(graph,λ,res,update_method,lagrangeheuristic)
    graph.attributes[:λ] = λ
    # Save summary
  end
  s.termination = "Max Iterations"
  return s
end

# Preprocess function
"""
  lgprepare(graph::PlasmoGraph)
  Prepares the graph to apply lagrange decomposition algorithm
"""
function lgprepare(graph::PlasmoGraph)
  if haskey(graph.attributes,:preprocessed)
    return true
  end
  n = normalizegraph(graph)
  links = getlinkconstraints(graph)
  nmult = length(links) # Number of multipliers
  graph.attributes[:numlinks] = nmult
  graph.attributes[:λ] = zeros(nmult) # Array{Float64}(nmult)
  graph.attributes[:x] = zeros(nmult,2) # Linking variables values
  graph.attributes[:res] = zeros(nmult) # Residuals
  graph.attributes[:mflat] = create_flat_graph_model(graph)
  graph.attributes[:mflat].solver = graph.solver
  graph.attributes[:cuts] = []

  # Create Lagrange Master
  ms = Model(solver=graph.solver)
  @variable(ms, η, upperbound=1e-6)
  @variable(ms, λ[1:nmult])
  @objective(ms, Max, η)

  graph.attributes[:lgmaster] = ms

  # Each node most save its initial objective
  for n in values(getnodes(graph))
    mn = getmodel(n)
    mn.ext[:preobj] = mn.obj
    mn.ext[:multmap] = Dict()
    mn.ext[:varmap] = Dict()
  end

  # Maps
  # Multiplier map to know which component of λ to take
  # Varmap knows what values to post where
  for (i,lc) in enumerate(links)
    for j in 1:length(lc.terms.vars)
      var = lc.terms.vars[j]
      var.m.ext[:multmap][i] = (lc.terms.coeffs[j],lc.terms.vars[j])
      var.m.ext[:varmap][var] = (i,j)
    end
  end

  graph.attributes[:preprocessed] = true
end

# Solve a single subproblem
function solvenode(node,λ,x,variant=:default)
  m = getmodel(node)
  m.obj = m.ext[:preobj]
  m.ext[:lgobj] = m.ext[:preobj]
  # Add dualized part to objective function
  for k in keys(m.ext[:multmap])
    coef = m.ext[:multmap][k][1]
    var = m.ext[:multmap][k][2]
    m.ext[:lgobj] += λ[k]*coef*var
    m.obj += λ[k]*coef*var
    if variant == :ADMM
      j = 3 - m.ext[:varmap][var][2]
      m.obj += 1/2*(coef*var - coef*x[k,j])^2
    end
  end

  # Optional: If my residuals are zero, do nothing

  solve(m)
  for v in keys(m.ext[:varmap])
    val = getvalue(v)
    x[m.ext[:varmap][v]...] = val
  end

  objval = getvalue(m.ext[:lgobj])
  node.attributes[:objective] = objval
  node.attributes[:solvetime] = getsolvetime(m)

  return x, objval
end

# Multiplier Initialization
function initialrelaxation(graph)
  if !haskey(graph.attributes,:mflat)
    graph.attributes[:mflat] = create_flat_graph_model(graph)
    graph.attributes[:mflat].solver = graph.solver
  end
  n = graph.attributes[:normalized]
  nmult = graph.attributes[:numlinks]
  mf = graph.attributes[:mflat]
  solve(mf,relaxation=true)
  graph.attributes[:λ] = n*mf.linconstrDuals[end-nmult+1:end]
  return getobjectivevalue(mf)
end

function updatemultipliers(graph,λ,res,method,lagrangeheuristic=nothing)
  if method == :subgradient
    subgradient(graph,λ,res,lagrangeheuristic)
  elseif method == :optimalstep
    optimalstep(graph,λ,res,lagrangeheuristic)
  elseif method == :ADMM
    ADMM(graph,λ,res,lagrangeheuristic)
  elseif method == :cuttingplanes
    cuttingplanes(graph,λ,res)
  elseif method == :bundle
    bundle(graph,λ,res,lagrangeheuristic)
  end
end

# Update functions
function subgradient(graph,λ,res,lagrangeheuristic)
  α = graph.attributes[:α]
  bound = lagrangeheuristic(graph)
  Zk = graph.attributes[:Zk]
  step = α*abs(Zk-bound)/(norm(res)^2)
  λ += step*res
  return λ,bound
end

function αeval(αv,graph,bound)
  xv = deepcopy(graph.attributes[:x])
  res = graph.attributes[:res]
  Zk = graph.attributes[:Zk]
  n = graph.attributes[:normalized]
  λ = graph.attributes[:λ]
  nodes = [node for node in values(getnodes(graph))]
  step = abs(Zk-bound)/(norm(res)^2)
  zk = 0
  for node in nodes
     (xv,Zkn) = solvenode(node,λ+αv*step*res,xv,:default)
     zk += Zkn
  end
  zk *= n
  return zk
end

function optimalstep(graph,λ,res,lagrangeheuristic,α=graph.attributes[:α])
  res = graph.attributes[:res]
  Zk = graph.attributes[:Zk]
  bound = lagrangeheuristic(graph)
  step = abs(Zk-bound)/(norm(res)^2)
  # First curve
  αa0 = 0
  za0 = graph.attributes[:Zk]
  αa1 = 0.01
  za1 = αeval(αa1,graph,bound)
  ma = (za1 - za0)/(αa1 - αa0)
  # Second curve
  αb0 = α
  zb0 = αeval(αb0,graph,bound)
  αb1 = αb0 - 0.01
  zb1 = αeval(αb1,graph,bound)
  mb = (zb1 - zb0)/(αb1 - αb0)
  println("ma = $ma")
  println("mb = $mb")
  # Check different Sign
  if sign(ma)<0 && sign(mb)<0
    optimalstep(graph,λ,res,lagrangeheuristic,2α)
  end
  # Find intersection
  αinter = (za0 - zb0 + αb0*mb)/(mb - ma)
  λ += αinter*step*res
  return λ,bound
end

function ADMM(graph,λ,res,lagrangeheuristic)
  bound = lagrangeheuristic(graph)
  λ += res/norm(res)
  return λ,bound
end

function cuttingplanes(graph,λ,res)
  ms = graph.attributes[:lgmaster]
  Zk = graph.attributes[:Zk]
  nmult = graph.attributes[:numlinks]

  λvar = getindex(ms, :λ)
  η = getindex(ms,:η)

  cut = @constraint(ms, η <= Zk + sum(λvar[j]*res[j] for j in 1:nmult))
  push!(graph.attributes[:cuts], cut)

  solve(ms)
  return getvalue(λvar), getobjectivevalue(ms)
end

function bundle(graph,λ,res,lagrangeheuristic)
  α = graph.attributes[:α]
  bound = lagrangeheuristic(graph)
  Zk = graph.attributes[:Zk]
  ms = graph.attributes[:lgmaster]
  λvar = getindex(ms, :λ)
  step = α*abs(Zk-bound)/(norm(res)^2)
  setlowerbound.(λvar,λ-step*abs.(res))
  setupperbound.(λvar,λ+step*abs.(res))

  cuttingplanes(graph,λ,res)
end

# Lagrangean Heuristics
function fixbinaries(graph::PlasmoGraph,cat=[:Bin])
  if !haskey(graph.attributes,:mflat)
    graph.attributes[:mflat] = create_flat_graph_model(graph)
  end
  n = graph.attributes[:normalized]
  mflat = graph.attributes[:mflat]
  mflat.solver = graph.solver
  mflat.colVal = vcat([getmodel(n).colVal for n in values(getnodes(g))]...)
  for j in 1:mflat.numCols
    if mflat.colCat[j] in cat
      mflat.colUpper[j] = mflat.colVal[j]
      mflat.colLower[j] = mflat.colVal[j]
    end
  end
  status = solve(mflat)
  if status == :Optimal
    return n*getobjectivevalue(mflat)
  else
    error("Heuristic model not infeasible or unbounded")
  end
end

function fixintegers(graph::PlasmoGraph)
  fixbinaries(graph,[:Bin,:Int])
end

# Main Function
function  lagrangesolveold(graph::PlasmoGraph;
  update_method=:subgradient,
  max_iterations=100,
  ϵ=0.001,
  α=2,
  UB=5e5,
  LB=-1e5,
  δ=0.8,
  ξ1=0.1,
  ξ2=0,
  λinit=:relaxation,
  solveheuristic=fixbinaries,
  timelimit=360000)

  ########## 0. Initialize ########
  # Start clock
  tic()
  starttime = time()

  # Results outputs
  df = DataFrame(Iter=[],Time=[],α=[],step=[],UB=[],LB=[],Hk=[],Zk=[],Gap=[])
  res = Dict()

  # Get Linkings
  links = getlinkconstraints(graph)
  nmult = length(links)

  # Generate subproblem array
  SP = [getmodel(graph.nodes[i]) for i in 1:length(graph.nodes)]
  for sp in SP
    JuMP.setsolver(sp,graph.solver)
  end
  # Capture objectives
  SPObjectives = [getmodel(graph.nodes[i]).obj for i in 1:length(graph.nodes)]
  sense = SP[1].objSense

  # Generate model for heuristic
  mflat = create_flat_graph_model(graph)
  mflat.solver = graph.solver
  # Restore mflat sense
  if sense == :Max
    mflat.objSense = :Max
    mflat.obj = -mflat.obj
  end
  # Solve realaxation
  solve(mflat,relaxation=true)
  bestbound = getobjectivevalue(mflat)
  if sense == :Max
    UB = bestbound
  else
    LB = bestbound
  end
  debug("Solved LP relaxation with value $bestbound")
  # Set starting λ to the duals of the LP relaxation
  # TODO handle NLP relaxation
  λk = λinit == :relaxation ? mflat.linconstrDuals[end-nmult+1:end] : λk = [0.0 for j in 1:nmult]
  λprev = λk

  # Variables
  θ = 0
  Kprev = [0 for j in 1:nmult]
  i = 0
  direction = nothing
  Zprev = sense == :Max ? UB : LB

  # Master Model (generate only for  planes or bundle methods)
  if update_method in [:cuttingplanes,:bundle]
    ms = Model(solver=graph.solver)
    @variable(ms, η)
    @variable(ms, λ[1:nmult])
    mssense = :Min
    if sense == :Min
      mssense = :Max
    end
    @objective(ms, mssense, η)
  end

  ## <-- Begin Iterations --> ##

  ########## 1. Solve Subproblems ########
  for iter in 1:max_iterations
    debug("*********************")
    debug("*** ITERATION $iter  ***")
    debug("*********************")

    Zk = 0
    improved = false


    # Restore initial objective
    for (j,sp) in enumerate(SP)
      sp.obj = SPObjectives[j]
    end
    # add dualized part
    for l in 1:nmult
      for j in 1:length(links[l].terms.vars)
        var = links[l].terms.vars[j]
        coeff = links[l].terms.coeffs[j]
        var.m.obj += λk[l]*coeff*var
      end
    end

    # Solve
    SP_result = pmap(psolve,SP)
    # Put values back in the graph
    nodedict = getnodes(graph)
    for spd in SP_result
      Zk += spd[:objective]
      getmodel(nodedict[spd[:nodeindex]]).colVal = spd[:values]
    end
    debug("Zk = $Zk")


    ########## 2. Solve Lagrangean Heuristic ########
    mflat.colVal = vcat([getmodel(n).colVal for n in values(nodedict)]...)
    Hk = solveheuristic(mflat)
    debug("Hk = $Hk")


    ########## 3. Check for Bounds Convergence ########
    # Update Bounds
    UBprev = UB
    LBprev = LB
    bestbound_prev = bestbound
    UB = sense == :Max ? min(Zk,UB) : min(Hk,UB)
    LB = sense == :Max ? max(Hk,LB) : max(Zk,LB)

    # Update objective value and calculate gap
    objective = sense == :Max ? LB : UB
    bestbound = sense == :Max ? UB : LB
    graph.objVal = objective
    gap = (UB - LB)/objective

    # Check
    if gap < ϵ
      debug("Converged on bounds to $objective")
      break
    end

    # Increase or restore bestbound improvement counter
    i += bestbound == bestbound_prev ? 1 : -i
    debug("i = $i")

    ########## 3. Check for improvement and update λ ########
    ξ = min(0.1, ξ1 + ξ2*gap)
    improved = sense == :Max ? Zk < Zprev*(1+ξ) : Zk > Zprev*(1+ ξ)
    debug("Compared Zkprev + $(round(ξ*100,1))% = $(Zprev*(1+ξ)) with Zk = $Zk and improved is $improved")
    # Force first step
    if iter == 1
      improved = true
      Zprev = Zk
    end

    # Line search
    # If improvement take step, else reduce α
    if improved
      Zk < Zprev && debug("IMPROVED bound")
      Zprev = Zk
      direction = [getvalue(links[j].terms) for j in 1:nmult]
      λprev = λk
      debug("STEP taken")
    else
      α *= 0.5
    end

    # Restore α
#    if iter % 100 == 0
#       α = 2
#    end
    # Shrink α if stuck
    if iter > 10 && i > 4
      α *= δ
      i = 0
      debug("STUCK, shrink α")
    end

    # Check convergence on α and direction
    if α < 1e-12
      debug("Converged on α = $α")
      break
    end

    normdirection = norm(direction)
    if norm(direction) == 0
      debug("Converged to feasible point")
      break
    end

    # Subgradient update
    difference = sense == :Max ? Zk - LB : UB - Zk

    # Direction correction method method
    μ = direction + θ*Kprev
    if update_method == :subgradient_correction
      if  dot(direction,Kprev) < 0
          θ = normdirection/norm(Kprev)
      else
        θ = 0
      end
    end
    # If the update method is without direction correction Θ = 0 and μ defaults to direction
    step = α*difference/dot(direction,μ)
    λk = λprev - step*μ

    # Check step convergence
    if step < 1e-20
      debug("Converged on step = $step")
      break
    end


    # Update multiplier bounds (Bundle method)
    if update_method == :bundle
      for j in 1:nmult
        setupperbound(λ[j], λprev[j] + step*abs(direction[j]))
        setlowerbound(λ[j], λprev[j] - step*abs(direction[j]))
      end
    end
    # Cutting planes or Bundle
    if update_method in (:cuttingplanes,:bundle)
      if sense == :Max
        @constraint(ms, η >= Zk + sum(λ[j]*direction[j] for j in 1:nmult))
      else
        @constraint(ms, η <= Zk + sum(λ[j]*direction[j] for j in 1:nmult))
      end
      debug("Last cut = $(ms.linconstr[end])")
      if iter > 10
        solve(ms)
        λk = getvalue(λ)
      end
    end

    # Report
    debug("Step = $step")
    debug("α = $α")
    debug("UB = $UB")
    debug("LB = $LB")
    debug("gap = $gap")
    elapsed = round(time()-starttime)
    push!(df,[iter,elapsed,α,step,UB,LB,Hk,Zk,gap])

    res[:Iterations] = iter
    res[:Gap] = gap

    if elapsed > timelimit
       debug("Time Limit exceeded, $elapsed seconds")
       break
    end

  end # Iterations

  # Report
  res[:Objective] = sense == :Min ? UB : LB
  res[:BestBound] = sense == :Min ? LB : UB
  res[:Time] = toc()
  return res, df

end # function

# Parallel model solve function, returns an array of objective values with dimension equal to of elements in the collection for which pmap was applied
function psolve(m::JuMP.Model)
  solve(m)
  d = Dict()
  d[:objective] = getobjectivevalue(m)
  d[:values] = m.colVal
  node = getnode(m)
  for v in values(node.index)
    d[:nodeindex] = v
  end
  #println("Solved node $(d[:nodeindex]) on $(gethostname())")
  return d
end
