mutable struct LShapedSolver <: AbstractLShapedSolver
    structuredModel::JuMPModel

    masterModel::JuMPModel
    masterProblem::LPProblem
    masterSolver::LPSolver

    subProblems::Vector{SubProblem}

    # Cuts
    θs
    ready
    numOptimalityCuts::Integer
    numFeasibilityCuts::Integer

    status::Symbol
    τ::Float64

    function LShapedSolver(m::JuMPModel)
        lshaped = new(m)

        init(lshaped)

        return lshaped
    end
end

function (lshaped::LShapedSolver)()
    println("Starting L-Shaped procedure\n")
    println("======================")
    # Initial solve of master problem
    println("Initial solve of master")
    lshaped.masterSolver()
    updateSolution(lshaped.masterSolver,lshaped.masterModel)
    lshaped.status = status(lshaped.masterSolver)
    if lshaped.status == :Infeasible
        println("Master is infeasible, aborting procedure.")
        println("======================")
        return
    end
    updateMasterSolution!(lshaped)

    # Initial update of sub problems
    map(updateSubProblem!,lshaped.subProblems)

    addedCut = false

    println("Main loop")
    println("======================")

    while true
        # Solve sub problems
        for subprob in lshaped.subProblems
            println("Solving subproblem: ",subprob.id)
            subprob.solver()
            updateSolution(subprob.solver,subprob.model)
            lshaped.status = status(subprob.solver)
            if lshaped.status == :Unbounded
                println("Subproblem ",subprob.id," is unbounded, aborting procedure.")
                println("======================")
                return
            end
            addedCut |= addCut!(lshaped,subprob)
        end

        if !addedCut
            # Optimal
            lshaped.status = :Optimal
            println("Optimal!")
            println("======================")
            break
        else
            addRows!(lshaped.masterProblem,lshaped.masterModel)
        end

        # Resolve master
        println("Solving master problem")
        lshaped.masterSolver()
        updateSolution(lshaped.masterSolver,lshaped.masterModel)
        lshaped.status = status(lshaped.masterSolver)
        if lshaped.status == :Infeasible
            println("Master is infeasible, aborting procedure.")
            println("======================")
            return
        end

        # Update master solution
        updateMasterSolution!(lshaped)

        # Update subproblems
        map(updateSubProblem!,lshaped.subProblems)

        # Reset
        addedCut = false
    end
end
