################################################################################
# Indices
################################################################################
struct MechanismIndices
    solution_state::Vector{Int}
    parameter_state::Vector{Int}
    input::Vector{Int}
end

function MechanismIndices(bodies::Vector, contacts::Vector)
    solution_state = zeros(Int,0)
    parameter_state = zeros(Int,0)
    input = zeros(Int,0)

    for body in bodies
        solution_state = vcat(solution_state, body.index.primals) # next state
        parameter_state = vcat(parameter_state, body.index.parameters[parameter_state_indices(body)]) # current state
        input = vcat(input, body.index.parameters[parameter_input_indices(body)]) # input
    end

    return MechanismIndices(
        solution_state,
        parameter_state,
        input,
        )
end

################################################################################
# dimensions
################################################################################
struct MechanismDimensions
    body_configuration::Int
    body_velocity::Int
    body_state::Int
    body_input::Int
    state::Int
    input::Int
    bodies::Int
    contacts::Int
    variables::Int
    parameters::Int
    # primals::Int
    # duals::Int
    # slacks::Int
    # cone::Int
    # equality::Int
end

function MechanismDimensions(bodies::Vector, contacts::Vector)
    # dimensions
    body_configuration = 3 # in 2D
    body_velocity = 3 # in 2D
    body_state = 6 # in 2D
    body_input = 3 # in 2D

    num_bodies = length(bodies)
    num_contacts = length(contacts)


    state = sum(state_dimension.(bodies))
    input = num_bodies * body_input

    nodes = [bodies; contacts]
    num_variables = sum(variable_dimension.(nodes))
    num_parameters = sum(parameter_dimension.(nodes))
    # num_primals = sum(primal_dimension.(nodes))
    # num_cone = sum(cone_dimension.(nodes))
    # num_duals = num_cone
    # num_slacks = num_cone
    # num_equality = sum(equality_dimension.(nodes))

    return MechanismDimensions(
        body_configuration,
        body_velocity,
        body_state,
        body_input,
        state,
        input,
        num_bodies,
        num_contacts,
        num_variables,
        num_parameters,
        # num_primals,
        # num_duals,
        # num_slacks,
        # num_cone,
        # num_equality
        )
end

################################################################################
# mechanism
################################################################################
struct Mechanism{T,D,NB,NC,B,C}
    variables::Vector{T}
    parameters::Vector{T}
    solver::Mehrotra.Solver{T}
    bodies::Vector{B}
    contacts::Vector{C}
    dimensions::MechanismDimensions
    indices::MechanismIndices
    # equalities::Vector{Equality{T}}
    # inequalities::Vector{Inequality{T}}
end

function Mechanism(residual, bodies::Vector, contacts::Vector;
        options::Mehrotra.Options{T}=Mehrotra.Options(),
        D::Int=2,
        method_type::Symbol=:finite_difference) where {T}

    # # Dimensions
    nodes = [bodies; contacts]
    dim = MechanismDimensions(bodies, contacts)
    idx = MechanismIndices(bodies, contacts)
    num_primals = sum(primal_dimension.(nodes))
    num_cone = sum(cone_dimension.(nodes))

    # indexing
    indexing!(nodes)

    # solver
    parameters = vcat(get_parameters.(bodies)..., get_parameters.(contacts)...)

    # methods = mechanism_methods(bodies, contacts, dim)
    solver = Mehrotra.Solver(
            residual,
            num_primals,
            num_cone,
            parameters=parameters,
            nonnegative_indices=collect(1:num_cone),
            second_order_indices=[collect(1:0)],
            method_type=method_type,
            options=options
            )

    # vectors
    variables = solver.solution.all
    parameters = solver.parameters

    nb = length(bodies)
    nc = length(contacts)
    mechanism = Mechanism{T,D,nb,nc,eltype(bodies),eltype(contacts)}(
        variables,
        parameters,
        solver,
        bodies,
        contacts,
        dim,
        idx,
        )
    return mechanism
end

function mechanism_residual(primals::Vector, duals::Vector,
        slacks::Vector, parameters::Vector,
        bodies::Vector, contacts::Vector)

    num_duals = length(duals)
    num_primals = length(primals)
    num_equality = num_primals + num_duals

    x = [primals; duals; slacks]
    e = zeros(eltype(x), num_equality)
    θ = parameters

    # body
    for body in bodies
        residual!(e, x, θ, body)
    end

    # contact
    for contact in contacts
        residual!(e, x, θ, contact, bodies)
    end
    return e
end

function mechanism_residual(primals::Vector, duals::Vector,
        slacks::Vector, mechanism::Mechanism)
    mechanism_residual(primals, duals, slacks,
        mechanism.parameters,
        mechanism.bodies,
        mechanism.contacts)
end
