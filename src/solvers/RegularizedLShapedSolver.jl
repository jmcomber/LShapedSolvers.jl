@with_kw mutable struct RegularizedSolverData{T <: Real}
    Q̃::T = Inf
    Δ̅::T = 1.0
    σ::T = 1.0
    exact_steps::Int = 0
    approximate_steps::Int = 0
    null_steps::Int = 0
end

struct RegularizedLShapedSolver{T <: Real, A <: AbstractVector, M <: LQSolver, S <: LQSolver} <: AbstractLShapedSolver{T,A,M,S}
    structuredmodel::JuMPModel
    solverdata::RegularizedSolverData{T}

    # Master
    mastersolver::M
    c::A
    x::A

    committee::Vector{SparseHyperPlane{T}}
    inactive::Vector{SparseHyperPlane{T}}
    violating::PriorityQueue{SparseHyperPlane{T},T}

    # Subproblems
    nscenarios::Int
    subproblems::Vector{SubProblem{T,A,S}}
    subobjectives::A

    # Regularizer
    ξ::A
    Q̃_history::A
    Δ̅_history::A

    # Cuts
    θs::A
    cuts::Vector{SparseHyperPlane{T}}

    # Params
    σ::T
    γ::T
    τ::T

    function (::Type{RegularizedLShapedSolver})(model::JuMPModel,x₀::AbstractVector,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver)
        length(x₀) != model.numCols && error("Incorrect length of starting guess, has ",length(x₀)," should be ",model.numCols)
        !haskey(model.ext,:Stochastic) && error("The provided model is not structured")

        T = promote_type(eltype(x₀),Float32)
        c_ = convert(AbstractVector{T},JuMP.prepAffObjective(model))
        x₀_ = convert(AbstractVector{T},x₀)
        A = typeof(x₀_)

        msolver = LQSolver(model,mastersolver)
        M = typeof(msolver)
        S = LQSolver{typeof(LinearQuadraticModel(subsolver)),typeof(subsolver)}

        lshaped = new{T,A,M,S}(model,
                               RegularizedSolverData{T}(),
                               msolver,
                               c_,
                               convert(A,rand(length(x₀_))),
                               convert(Vector{SparseHyperPlane{T}},linearconstraints(model)),
                               Vector{SparseHyperPlane{T}}(),
                               PriorityQueue{SparseHyperPlane{T},T}(Reverse),
                               num_scenarios(model),
                               Vector{SubProblem{T,A,S}}(),
                               A(zeros(num_scenarios(model))),
                               x₀_,
                               A(),
                               A(),
                               A(fill(-Inf,num_scenarios(model))),
                               Vector{SparseHyperPlane{T}}(),
                               convert(T,1.0),
                               convert(T,0.9),
                               convert(T,1e-6)
                               )
        init!(lshaped,subsolver)

        return lshaped
    end
end
RegularizedLShapedSolver(model::JuMPModel,mastersolver::AbstractMathProgSolver,subsolver::AbstractMathProgSolver) = RegularizedLShapedSolver(model,rand(model.numCols),mastersolver,subsolver)

@implement_trait RegularizedLShapedSolver UsesLocalization IsRegularized

function Base.show(io::IO, lshaped::RegularizedLShapedSolver)
    print(io,"RegularizedLShapedSolver")
end

function prepareMaster!(lshaped::RegularizedLShapedSolver,n::Integer)
    # θs
    for i = 1:n
        addvar!(lshaped.mastersolver.lqmodel,-Inf,Inf,1.0)
    end
    update_objective!(lshaped)
end

function update_objective!(lshaped::RegularizedLShapedSolver)
    # Linear regularizer penalty
    c = copy(lshaped.c)
    c -= (1/lshaped.solverdata.σ)*lshaped.ξ
    append!(c,fill(1.0,lshaped.nscenarios))
    setobj!(lshaped.mastersolver.lqmodel,c)

    # Quadratic regularizer penalty
    qidx = collect(1:length(lshaped.ξ)+lshaped.nscenarios)
    qval = fill(1/lshaped.solverdata.σ,length(lshaped.ξ))
    append!(qval,zeros(lshaped.nscenarios))
    if applicable(setquadobj!,lshaped.mastersolver.lqmodel,qidx,qidx,qval)
        setquadobj!(lshaped.mastersolver.lqmodel,qidx,qidx,qval)
    else
        error("The regularized decomposition algorithm requires a solver that handles quadratic objectives")
    end
end

function (lshaped::RegularizedLShapedSolver)()
    println("Starting L-Shaped procedure with regularized decomposition")
    println("======================")
    lshaped.solverdata.Q̃ = calculateObjective(lshaped,lshaped.ξ)
    println("Main loop")
    println("======================")

    while true
        if isempty(lshaped.violating)
            # Resolve all subproblems at the current optimal solution
            resolve_subproblems!(lshaped)
            # Update the optimization vector
            take_step!(lshaped)
        else
            # Add at most L violating constraints
            L = 0
            while !isempty(lshaped.violating) && L < lshaped.nscenarios
                constraint = dequeue!(lshaped.violating)
                if satisfied(lshaped,constraint)
                    push!(lshaped.inactive,constraint)
                    continue
                end
                println("Adding violated constraint to committee")
                push!(lshaped.committee,constraint)
                addconstr!(lshaped.mastersolver.lqmodel,lowlevel(constraint)...)
                L += 1
            end
        end

        # Resolve master
        println("Solving master problem")
        lshaped.mastersolver(lshaped.x)
        if status(lshaped.mastersolver) == :Infeasible
            println("Master is infeasible, aborting procedure.")
            println("======================")
            return
        end
        # Update master solution
        update_solution!(lshaped)
        remove_inactive!(lshaped)
        if length(lshaped.violating) <= lshaped.nscenarios
            queueViolated!(lshaped)
        end

        if check_optimality(lshaped)
            if lshaped.solverdata.Δ̅ > lshaped.τ && norm(lshaped.x-lshaped.ξ,Inf) - lshaped.solverdata.Δ̅ <= lshaped.τ
                lshaped.solverdata.σ *= 1/(norm(lshaped.x-lshaped.ξ,Inf))
            else
                # Optimal
                println("Optimal!")
                println("Objective value: ", calculate_objective_value(lshaped))
                println("======================")
                break
            end
        end
    end
end


## Trait functions
# ------------------------------------------------------------
@implement_traitfn IsRegularized function initSolverData!(lshaped::AbstractLShapedSolver)
    lshaped.solverdata.Q̃ = Inf
    lshaped.solverdata.Δ̅ = max(1.0,0.2*norm(lshaped.ξ,Inf))
    push!(lshaped.Δ̅_history,lshaped.solverdata.Δ̅)
    lshaped.solverdata.σ = lshaped.σ
    lshaped.solverdata.exact_steps = 0
    lshaped.solverdata.approximate_steps = 0
    lshaped.solverdata.null_steps = 0
end

@implement_traitfn IsRegularized function take_step!(lshaped::AbstractLShapedSolver)
    obj = calculate_objective_value(lshaped)
    θ = calculate_estimate(lshaped)
    if abs(θ-obj) <= lshaped.τ*(1+abs(obj))
        println("Exact serious step")
        lshaped.solverdata.Δ̅ = norm(lshaped.x-lshaped.ξ,Inf)
        push!(lshaped.Δ̅_history,lshaped.solverdata.Δ̅)
        lshaped.ξ[:] = lshaped.x[:]
        lshaped.solverdata.Q̃ = obj
        push!(lshaped.Q̃_history,lshaped.solverdata.Q̃)
        lshaped.solverdata.exact_steps += 1
        lshaped.solverdata.σ *= 4
        update_objective!(lshaped)
    elseif obj + lshaped.τ*(1+abs(obj)) <= lshaped.γ*lshaped.solverdata.Q̃ + (1-lshaped.γ)*θ
        println("Approximate serious step")
        lshaped.solverdata.Δ̅ = norm(lshaped.x-lshaped.ξ,Inf)
        push!(lshaped.Δ̅_history,lshaped.solverdata.Δ̅)
        lshaped.ξ[:] = lshaped.x[:]
        lshaped.solverdata.Q̃ = obj
        push!(lshaped.Q̃_history,lshaped.solverdata.Q̃)
        lshaped.solverdata.approximate_steps += 1
    else
        println("Null step")
        lshaped.solverdata.null_steps += 1
        lshaped.solverdata.σ *= 0.9
        update_objective!(lshaped)
    end
end

@implement_traitfn IsRegularized function remove_inactive!(lshaped::AbstractLShapedSolver)
    inactive = find(c->!active(lshaped,c),lshaped.committee)
    diff = length(lshaped.committee) - length(lshaped.structuredmodel.linconstr) - lshaped.nscenarios
    if isempty(inactive) || diff <= 0
        return false
    end
    if diff <= length(inactive)
        inactive = inactive[1:diff]
    end
    append!(lshaped.inactive,lshaped.committee[inactive])
    deleteat!(lshaped.committee,inactive)
    delconstrs!(lshaped.mastersolver.lqmodel,inactive)
    return true
end
