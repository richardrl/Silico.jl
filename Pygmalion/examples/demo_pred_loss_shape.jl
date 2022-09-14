include(joinpath(module_dir(), "Pygmalion/Pygmalion.jl"))
include("prediction.jl")

################################################################################
# visualize
################################################################################
vis = Visualizer()
render(vis)
# open(vis)
set_background!(vis)
set_light!(vis, direction="Negative")
set_floor!(vis, color=RGBA(0.4,0.4,0.4,0.4))
iterate_color = RGBA(1,1,0,0.6);


################################################################################
# polytope parameters
################################################################################
A0 = [
	+1.0 +0.0;
	+0.0 +1.0;
	-1.0 +0.0;
	+0.0 -1.0;
	]
normalize_A!(A0)
b0 = 0.5*[
	+1,
	+1,
	+1,
	+1,
	]
o0 = [0.0, +0.0]
Af = [0.0  +1.0]
bf = [-6.0]
of = [0.0]
build_2d_polytope!(vis[:polytope], A0, b0 + A0 * o0,
	name=:poly0, color=RGBA(1,1,1,1.0))


################################################################################
# inertial parameters
################################################################################
timestep = 0.05;
gravity = -9.81;
mass = 1.0;
inertia = 0.2 * ones(1,1);
μ0 = [0.1]
ctol = 1e-3
ctol_grad = 1e-3

mech = get_polytope_drop(;
    timestep=timestep,
    gravity=gravity,
    mass=mass,
    inertia=inertia,
    friction_coefficient=μ0[1],
	method_type=:symbolic,
	A=A0,
	b=b0,
    options=Mehrotra.Options(
        verbose=false,
		residual_tolerance=ctol/10,
        complementarity_tolerance=ctol,
		compressed_search_direction=true,
        max_iterations=30,
        sparse_solver=false,
        differentiate=false,
        warm_start=false,
        complementarity_correction=0.5,
        )
    );
Mehrotra.solve!(mech.solver)

################################################################################
# test simulation
################################################################################
xp2 =  [+0.00, +1.50, -0.00]
vp15 = [-2.00, +0.00, -3.00]
z0 = [xp2; vp15]
z0 = [xp2; vp15]

H0 = 35
storage = simulate!(mech, z0, H0+1)
vis, anim = visualize!(vis, mech, storage)


################################################################################
# dimensions and parameter selection
################################################################################
# contact parameters =
# 	friction_coefficient = 1     13 .+ (1:1)
# 	Ap = 8     13 .+ (2:9)
# 	bp = 4     13 .+ (10:13)
# 	Ac = 2     13 .+ (14:15)
# 	bc = 1     13 .+ (16:16)

# idx_parameters = 13 .+ [1, 10]
# idx_parameters = 13 .+ [10]
idx_parameters = 13 .+ [10, 11, 12, 13]
num_state = mech.dimensions.body_state
num_parameters = mech.solver.dimensions.parameters
num_learnable_parameters = length(idx_parameters)
nz = num_state
nw = num_learnable_parameters
N = H0 * (nz + nw)

################################################################################
# ground truth
################################################################################
z0 = deepcopy(storage.z[1])
ẑ = [deepcopy(storage.z[i+1]) for i=1:H0]
zs = [deepcopy(storage.z[i+1]) for i=1:H0]
ws = [deepcopy(μ0) for i=1:H0]
# xtruth = vcat([[deepcopy(storage.z[i+1]); deepcopy(μ0)] for i=1:H0]...)
xtruth = vcat([[deepcopy(storage.z[i+1]); deepcopy(μ0); 0.5] for i=1:H0]...)

trajectory_loss(ẑ, zs, z0, ws, idx_parameters, mech)
trajectory_gradient(ẑ, zs, z0, ws, idx_parameters, mech)
trajectory_hessian(ẑ, zs, z0, ws, idx_parameters, mech)


################################################################################
# optimization
################################################################################
# NonconvexPercival
function local_loss(x)
	z = [x[(i-1)*(nz+nw) .+ (1:nz)] for i=1:H0]
	w = [x[(i-1)*(nz+nw) + nz .+ (1:nw)] for i=1:H0]
	trajectory_loss(ẑ, z, z0, w, idx_parameters, mech; complementarity_tolerance=ctol)
end
function local_grad(x)
	z = [x[(i-1)*(nz+nw) .+ (1:nz)] for i=1:H0]
	w = [x[(i-1)*(nz+nw) + nz .+ (1:nw)] for i=1:H0]
	trajectory_gradient(ẑ, z, z0, w, idx_parameters, mech; complementarity_tolerance=ctol_grad)
end
function local_hess(x)
	z = [x[(i-1)*(nz+nw) .+ (1:nz)] for i=1:H0]
	w = [x[(i-1)*(nz+nw) + nz .+ (1:nw)] for i=1:H0]
	trajectory_hessian(ẑ, z, z0, w, idx_parameters, mech; complementarity_tolerance=ctol_grad)
end

function eq_fct(x)
	eq = zeros((H0-1) * nw)
	idx1 = vcat([(i-1)*(nz+nw) + nz .+ (1:nw) for i=1:H0-1]...)
	idx2 = vcat([i*(nz+nw) + nz .+ (1:nw) for i=1:H0-1]...)
	eq = x[idx1] .- x[idx2]
	return 1e-3*eq
end

model = Nonconvex.Model()
xinit = vcat([[0*ones(nz); 1.0*ones(nw)] for i = 1:H0]...)
lb = vcat([[-10*ones(nz); 0.0*ones(nw)] for i = 1:H0]...)
ub = vcat([[+10*ones(nz); 1.0*ones(nw)] for i = 1:H0]...)
addvar!(model, lb, ub, init=xinit, integer=falses(N))
add_eq_constraint!(model, eq_fct)
obj_fct = CustomHessianFunction(local_loss, local_grad, local_hess)
set_objective!(model, obj_fct)

verbose = true
alg = IpoptAlg()
max_cpu_time = 90.0
print_level = verbose ? 5 : 0
options = IpoptOptions(print_level=print_level, max_cpu_time=max_cpu_time)

# alg = AugLag()
# options = AugLagOptions(
# 	# first_order = false,
# 	rtol = 1e-4
# 	)

result = Nonconvex.optimize(model, alg, xinit, options=options)
xmin = result.minimizer

local_loss(xinit)
local_loss(xtruth)
local_loss(xmin)
xmin[7:7:end]
xmin[7:8:end]
xmin[8:8:end]
xmin[7:10:end]
xmin[8:10:end]
xmin[9:10:end]
xmin[10:10:end]

# xtruth = vcat([[deepcopy(storage.z[i+1]); deepcopy(μ0); +0.5] for i=1:H0]...)
xtruth = vcat([[deepcopy(storage.z[i+1]); +0.5*ones(nw)] for i=1:H0]...)
# xtruth = vcat([[deepcopy(storage.z[i+1]); +0.5] for i=1:H0]...)
local_loss(xtruth)
