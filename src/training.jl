using Lux
using StaticArrays: reorder
using LoggingExtras: shouldlog
using LinearAlgebra: NumberArray
using ConcreteStructs
using TOML
using GeometryBasics
using ADTypes
using Random
using LinearAlgebra
using FileIO
using Zygote
using MLUtils
using Logging
using StaticArrays
using Optimisers
using Statistics
using TensorBoardLogger
using Serialization
using Meshing
using NearestNeighbors
using StructArrays
using MLNanoShaperRunner

"""
Training information used in model training.
# Fields
- `atoms`: the set of atoms used as model input
- `skin` : the Surface generated by Nanoshaper
"""
struct TrainingData{T <: Number}
    atoms::StructVector{Sphere{T}}
    skin::GeometryBasics.Mesh
end

"""
	train((train_data,test_data),training_states; nb_epoch)
train the model on the data with nb_epoch
"""
function train(
        (train_data,
            test_data)::Tuple{MLUtils.AbstractDataContainer, MLUtils.AbstractDataContainer},
        training_states::Lux.Experimental.TrainState, training_parameters::Training_parameters,
        auxiliary_parameters::Auxiliary_parameters)
    (; nb_epoch, save_periode, models_dirs) = auxiliary_parameters
    for epoch in 1:nb_epoch
        @info "epoch" epoch
        training_states = train(
            train_data, training_states, training_parameters)
        test.(test_data, Ref(training_states), training_parameters)
        if epoch % save_periode == 0
            serialize(
                "$(homedir())/$(models_dirs)/$(generate_training_name(training_parameters,epoch))",
                training_states)
        end
    end
end
function train(data,
        training_states::Lux.Experimental.TrainState;
		Training_parameters::Training_parameters)
    for d in data
        training_states = train(d, training_states,Training_parameters)
        training_states
    end
    training_states
end

function point_grid(atoms::KDTree,
        skin::KDTree;
        scale::Float32,
        r::Float32)::Vector{Point3{Float32}}
    (; mins, maxes) = atoms.hyper_rec
    filter(Iterators.product(range.(mins,
        maxes
        ; step = scale)...) .|> Point3) do point
        distance(point, atoms) < r && distance(point, skin) < r
    end
end

"""
    loss_fn(model, ps, st, (; point, atoms, skin))

The loss function used by in training.
compare the predicted (square) distance with \$\\frac{1 + \tanh(d)}{2}\$
Return the error with the espected distance as a metric.
"""
function loss_fn(model, ps, st, (; point, atoms, d_real))
    trace("loss", point)
    ret = Lux.apply(model, ModelInput(point, atoms), ps, st)
    d_pred, st = ret

    d_pred = only(d_pred) |> trace("model output")
    ((d_pred - (1 + tanh(d_real)) / 2)^2,
        st,
        (; distance = abs(d_real - atanh(max(0, (2d_pred - 1)) * (1 - 1.0f-4)))))
end
function train((; atoms, skin)::TrainingData{Float32},
        training_states::Lux.Experimental.TrainState, (; scale::Float32,
            cutoff_radius::Float32))
    exact_points = shuffle(MersenneTwister(42), coordinates(skin))
    skin = RegionMesh(skin)
    atoms_tree = KDTree(atoms.center; reorder = false)
    points = point_grid(atoms_tree, skin.tree; scale, cutoff_radius)

    for point in vcat(
        first(shuffle(MersenneTwister(42), points), 20), first(exact_points, 20))
        atoms_neighboord = atoms[inrange(atoms_tree, point, cutoff_radius)] |> StructVector
        trace("pre input size", length(atoms_neighboord))
        grads, loss, stats, training_states = Lux.Experimental.compute_gradients(
            AutoZygote(),
            loss_fn,
            (; point, atoms = atoms_neighboord, d_real = signed_distance(point, skin)),
            training_states)
        training_states = Lux.Experimental.apply_gradients(training_states, grads)
        @info "train" loss stats training_states.parameters
    end
    training_states
end

function test((; atoms, skin)::TrainingData{Float32},
        training_states::Lux.Experimental.TrainState,(; scale,cutoff_radius)::Training_parameters)
    exact_points = shuffle(MersenneTwister(42), coordinates(skin))
    skin = RegionMesh(skin)
    atoms_tree = KDTree(atoms.center, reorder = false)
    points = point_grid(atoms_tree, skin.tree; scale, cutoff_radius)

    for point in vcat(
        first(shuffle(MersenneTwister(42), points), 20), first(exact_points, 20))
        atoms_neighboord = atoms[inrange(atoms_tree, point, cutoff_radius)] |> StructVector
        loss, _, stats = loss_fn(training_states.model, training_states.parameters,
            training_states.states,
            (; point, atoms = atoms_neighboord, d_real = signed_distance(point, skin)))
        @info "test" loss stats
    end

    (; mins, maxes) = atoms_tree.hyper_rec
    surface = isosurface(MarchingCubes(), SVector{3, Float32};
        origin = mins, widths = maxes - mins) do x
        atoms_neighboord = atoms[inrange(atoms_tree, x, cutoff_radius)] |> StructVector
        if length(atoms_neighboord) > 0
            res = training_states.model(ModelInput(Point3f(x), atoms_neighboord),
                training_states.parameters, training_states.states) |> first
            if isnan(res)
                @error "isnan" res x atoms_neighboord
            end
            res
        else
            0.0f0
        end - 0.5f0
    end
    @info "test" hausdorff_distance=distance(first(surface), skin.tree)
end

"""
	load_data_pdb(T, name::String)

Load a `TrainingData{T}` from current directory.
You should have a pdb and an off file with name `name` in current directory.
"""
function load_data_pdb(T::Type{<:Number}, name::String)
    TrainingData{T}(extract_balls(T, read("$name.pdb", PDB)), load("$name.off"))
end
"""
	load_data_pqr(T, name::String)

Load a `TrainingData{T}` from current directory.
You should have a pdb and an off file with name `name` in current directory.
"""
function load_data_pqr(T::Type{<:Number}, dir::String)
    TrainingData{T}(getproperty.(read("$dir/structure.pqr", PQR{T}), :pos) |> StructVector,
        load("$dir/triangulatedSurf.off"))
end

"""
    train(training_parameters::Training_parameters, directories::Auxiliary_parameters)

train the model given `Training_parameters` and `Auxiliary_parameters`.
"""
function train(training_parameters::Training_parameters, directories::Auxiliary_parameters)
    (; data_ids, train_test_split) = training_parameters
    (; datadir, logdir) = directories
    train_data, test_data = splitobs(
        mapobs(shuffle(MersenneTwister(42),
            data_ids)) do id
            load_data_pqr(Float32, "$datadir/$id")
        end; at = train_test_split)
    optim = OptimiserChain(AccumGrad(16), SignDecay(), WeightDecay(), Adam())
    with_logger(get_logger(logdir)) do
        train((train_data, test_data),
            Lux.Experimental.TrainState(MersenneTwister(42), model, optim),
            training_parameters)
    end
end
