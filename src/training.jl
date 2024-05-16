using Lux
using Distributed: preduce
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
using Distributed
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

struct TreeTrainingData{T <: Number}
    atoms::StructVector{Sphere{T}}
    atoms_tree::KDTree
    skin::RegionMesh
end
function TreeTrainingData((; atoms, skin)::TrainingData)
    TreeTrainingData(atoms, KDTree(atoms.center; reorder = false), RegionMesh(skin))
end

function point_grid(atoms::KDTree,
        skin::KDTree{Vector{Point3f}};
        scale::Float32,
        cutoff_radius::Float32)::Vector{Point3f}
    (; mins, maxes) = atoms.hyper_rec
    filter(Iterators.product(range.(mins,
        maxes
        ; step = scale)...) .|> Point3) do point
        distance(point, atoms) < cutoff_radius && distance(point, skin) < cutoff_radius
    end
end

"""
    loss_fn(model, ps, st, (; point, atoms, d_real))

The loss function used by in training.
compare the predicted (square) distance with \$\\frac{1 + \tanh(d)}{2}\$
Return the error with the espected distance as a metric.
"""
function loss_fn(model, ps, st, (; point, atoms, d_real))
    trace("loss", point)
    ret = Lux.apply(model, Batch(ModelInput.(point, atoms)), ps, st)
    d_pred, st = ret

    d_pred |> trace("model output")
    ((d_pred .- (1 .+ tanh.(d_real)) ./ 2) .^ 2 |> mean,
        st,
        (;
            distance = abs.(d_real .- atanh.(max.(0, (2d_pred .- 1)) * (1 .- 1.0f-4))) |>
                       mean))
end

function generate_data_points((; atoms, atoms_tree, skin)::TreeTrainingData{Float32},
        (; scale, cutoff_radius)::Training_parameters)
    exact_points = shuffle(MersenneTwister(42), skin.tree.data)
    points = point_grid(atoms_tree, skin.tree; scale, cutoff_radius)

    mapobs(vcat(
        first(shuffle(MersenneTwister(42), points), 40), first(exact_points, 40))) do point::Point3f
        trace("point", point)
        atoms_neighboord = atoms[inrange(atoms_tree, point, cutoff_radius)]
        trace("pre input size", length(atoms_neighboord))
        (; point, atoms = atoms_neighboord, d_real = signed_distance(point, skin))
    end
end

function generate_data_points(x::TrainingData, args...)
    generate_data_points(TreeTrainingData(x), args...)
end

function pre_compute_data_set(data, tr::Training_parameters)::Vector{Vector{<:NamedTuple{(:point, :atoms, :d_real)}}}
    res = pmap(data) do d
		collect(generate_data_points(d, tr))::Vector{<:NamedTuple{(:point, :atoms, :d_real)}}
    end
    reduce(vcat, res)
end

function implicict_surface(atoms_tree::KDTree, atoms::StructVector{Atom},
        training_states::Lux.Experimental.TrainState, (;
            cutoff_radius)::Training_parameters)
    (; mins, maxes) = atoms_tree.hyper_rec
    isosurface(
        MarchingCubes(), SVector{3, Float32}; origin = mins, widths = maxes - mins) do x
        atoms_neighboord = atoms[inrange(atoms_tree, x, cutoff_radius)] |> StructVector
        if length(atoms_neighboord) > 0
            training_states.model(ModelInput(Point3f(x), atoms_neighboord),
                training_states.parameters, training_states.states) |> first
        else
            0.0f0
        end - 0.5f0
    end
end

function hausdorff_metric((; atoms, atoms_tree, skin)::TreeTrainingData,
        training_states::Lux.Experimental.TrainState, training_parameters::Training_parameters)
    surface = implicict_surface(atoms_tree, atoms, training_states, training_parameters)
    distance(first(surface), KDTree(skin))
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

function test(data::AbstractVector{<:NamedTuple{(:point, :atoms, :d_real)}},
        training_states::Lux.Experimental.TrainState)
    for (; point, atoms, d_real) in BatchView(data; batchsize = 400)
        loss, _, stats = loss_fn(training_states.model, training_states.parameters,
            training_states.states,
            (; point, atoms, d_real))
        loss, stats = (loss, stats) .|> cpu_device()
        @info "test" mean(loss) mean(stats)
    end
end
function train(data::AbstractVector{<:NamedTuple{(:point, :atoms, :d_real)}},
        training_states::Lux.Experimental.TrainState)
    for d in BatchView(data; batchsize = 400)
        grads, loss, stats, training_states = Lux.Experimental.compute_gradients(
            AutoZygote(),
            loss_fn,
            d |> trace("train data"),
            training_states)
        training_states = Lux.Experimental.apply_gradients(training_states, grads)
        loss, stats, parameters = (loss, stats, training_states.parameters) .|> cpu_device()
        @info "train" mean(loss) mean(stats) parameters
    end
    training_states
end

function train(data::AbstractVector{<:AbstractVector},
        training_states::Lux.Experimental.TrainState,
        training_parameters::Training_parameters)
    for d in data
        training_states = train(d, training_states)
        training_states
    end
    training_states
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
    (; nb_epoch, save_periode, model_dir) = auxiliary_parameters

    @info "start pre computing"
    train_data = pre_compute_data_set(train_data, training_parameters)
    test_tree = pmap(TreeTrainingData, test_data)
    test_data = pre_compute_data_set(test_tree, training_parameters)
    @info "end pre computing"

    for epoch in 1:nb_epoch
        @info "epoch" epoch
        training_states = train(
            train_data, training_states, training_parameters)
        test.(test_data, Ref(training_states))
        hausdorff_distance = pmap(test_tree) do d
            hausdorff_metric(d, training_states, training_parameters)
        end |> mean
        @info "test" hausdorff_distance

        if epoch % save_periode == 0
            serialize(
                "$(homedir())/$(model_dir)/$(generate_training_name(training_parameters,epoch))",
                training_states)
        end
    end
end

"""
    train(training_parameters::Training_parameters, directories::Auxiliary_parameters)

train the model given `Training_parameters` and `Auxiliary_parameters`.
"""
function train(training_parameters::Training_parameters, directories::Auxiliary_parameters)
    (; data_ids, train_test_split, model) = training_parameters
    (; data_dir, log_dir) = directories
    train_data, test_data = splitobs(
        mapobs(shuffle(MersenneTwister(42),
            data_ids)) do id
            load_data_pqr(Float32, "$(homedir())/$data_dir/$id")
        end; at = train_test_split)
    optim = OptimiserChain(SignDecay(), WeightDecay(), Adam())
    with_logger(get_logger("$(homedir())/$log_dir/$(generate_training_name(training_parameters))")) do
        train((train_data, test_data),
            Lux.Experimental.TrainState(MersenneTwister(42), model, optim) |> gpu_device(),
            training_parameters, directories)
    end
end
