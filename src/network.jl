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
using Logging
using LoggingExtras

"""
	train((train_data,test_data),training_states; nb_epoch)
train the model on the data with nb_epoch
"""
function train((train_data,
            test_data)::Tuple{MLUtils.AbstractDataContainer, MLUtils.AbstractDataContainer},
        training_states::Lux.Experimental.TrainState; nb_epoch, save_periode, params...)
    # serialize("$(homedir())/$(conf["paths"]["model_dir"])/model_0", training_states)
    for epoch in 1:nb_epoch
        @info "epoch" epoch
        training_states = train(train_data, training_states; params...)
        test.(test_data, Ref(training_states); params...)
        # @info "weights" weights=training_states.parameters
        # if epoch % save_periode == 0
        #     serialize("$(homedir())/$(conf["paths"]["model_dir"])/model_$epoch",
        #         training_states)
        # end
    end
end
function train(data,
        training_states::Lux.Experimental.TrainState;
        params...)
    for d in data
        training_states = train(d, training_states; params...)
        training_states
    end
    training_states
end

function point_grid(atoms::KDTree; scale::Float32, r::Float32)::Vector{Point3{Float32}}
    (; mins, maxes) = atoms.hyper_rec
    filter(Iterators.product(range.(mins,
        maxes
        ; step = scale)...) .|> Point3) do point
			distance(point,atoms) < r

    end
end

"""
    loss_fn(model, ps, st, (; point, atoms, skin))

The loss function used by in training.
compare the predicted (square) distance with \$\\frac{1 + \tanh(d)}{2}\$
Return the error with the espected distance as a metric.
"""
function loss_fn(model, ps, st, (; point, atoms, d_real))
    ret = Lux.apply(model, ModelInput(point, atoms), ps, st)
    d_pred, st = ret

    d_pred = only(d_pred) |> trace("model output")
    ((d_pred - (1 + tanh(d_real)) / 2)^2,
        st,
        (; distance = abs(d_real - atanh(max(0, (2d_pred - 1)) * (1 - 1.0f-4)))))
end
function train((; atoms, skin)::TrainingData{Float32},
        training_states::Lux.Experimental.TrainState; scale::Float32,
        r::Float32)
    skin = KDTree(coordinates(skin))
    atoms_tree = KDTree(atoms.center; reorder = false)
    points = point_grid(atoms_tree; scale, r)

    for point in first(shuffle(MersenneTwister(42), points), 20)
        atoms_neighboord = atoms[inrange(atoms_tree, point, r)] |> StructVector
        trace("pre input size", length(atoms_neighboord))
        grads, loss, stats, training_states = Lux.Experimental.compute_gradients(AutoZygote(),
            loss_fn,
			(; point, atoms = atoms_neighboord, d_real=distance(point,skin)),
            training_states)
        # _, back = Zygote.pullback(loss_fn,
        #     training_states.model,
        #     training_states.parameters,
        #     training_states.states,
        #     (; point, atoms = atoms_neighboord, skin))
        # @info "train" loss stats back((1f0, nothing, nothing))
        training_states = Lux.Experimental.apply_gradients(training_states, grads)
        @info "train" loss stats training_states.model
    end
    training_states
end

function test((; atoms, skin)::TrainingData{Float32},
        training_states::Lux.Experimental.TrainState; scale::Float32,
        r::Float32)
		skin = KDTree(coordinates(skin))
    atoms_tree = KDTree(atoms.center,reorder = false)
    points = point_grid(atoms_tree; scale, r)

    for point in first(shuffle(MersenneTwister(42), points), 20)
        atoms_neighboord = atoms[inrange(atoms_tree, point, r)] |> StructVector
        loss, _, stats = loss_fn(training_states.model, training_states.parameters,
            training_states.states,
			(; point, atoms = atoms_neighboord, d_real=distance(point,skin)))
        @info "test" loss stats
    end
end

"""
	load_data(T, name::String)

Load a `TrainingData{T}` from current directory.
You should have a pdb and an off file with name `name` in current directory.
"""
function load_data(T::Type{<:Number}, name::String)
    TrainingData{T}(extract_balls(T, read("$name.pdb", PDB)), load("$name.off"))
end

"""
	accumulator(processing,logger)
A processing logger that transform logger on multiple batches
Ca be used to liss numerical data, for logging to TensorBoardLogger.
"""
mutable struct AccumulatorLogger <: AbstractLogger
    processing::Function
    logger::AbstractLogger
    data::Dict
end

function Logging.handle_message(logger::AccumulatorLogger, message...; kargs...)
    logger.processing(logger.logger, Ref(logger.data), message, kargs)
end
Logging.shouldlog(logger::AccumulatorLogger, args...) = shouldlog(logger.logger, args...)
Logging.min_enabled_level(logger) = Logging.min_enabled_level(logger.logger)
empty_accumulator(::Union{Type{<:AbstractDict}, Type{<:NamedTuple}}) = Dict()
empty_accumulator(::Type{T}) where {T <: Number} = T[]
function accumulate(d::Dict, kargs::AbstractDict)
    for k in keys(kargs)
        if k ∉ keys(d)
            d[k] = empty_accumulator(typeof(kargs[k]))
        end
        accumulate(d[k], kargs[k])
    end
end
function accumulate(d::Vector, arg::Number)
    push!(d, arg)
end
function accumulate(d::Dict, kargs::NamedTuple)
    accumulate(d, pairs(kargs))
end
extract(d::Dict) = Dict(keys(d) .=> extract.(values(d)))
function extract(d::Vector)
    mean(d)
end
function train()
    train_data, test_data = splitobs(mapobs(shuffle(MersenneTwister(42),
            conf["protein"]["list"])[1:10]) do name
            load_data(Float32, "$datadir/$name")
        end; at = 0.8)
    logger = TBLogger("$(homedir())/$(conf["paths"]["log_dir"])")
    logger = AccumulatorLogger(global_logger(),
        Dict()) do logger, d, args, kargs
        level, message = args
        if message == "epoch"
            kargs = extract(d[])
            for (k, v) in pairs(kargs)
                Logging.handle_message(logger, level, k, args[3:end]...; v...)
            end
            d[] = Dict()
        else
            accumulate(d[], Dict([message => kargs]))
        end
    end
    logger = TeeLogger(ActiveFilteredLogger(logger) do (; message)
            message in ("test", "train", "epoch")
        end,
        ActiveFilteredLogger(global_logger()) do (; message)
            message ∉ ("test", "train")
        end)

    a = 5
    b = 5
    adaptator = ToSimpleChainsAdaptor((static(a * b + 2),))
    chain = Chain(Dense(a * b + 2 => 10,
            elu),
        Dense(10 => 1, elu;
            init_weight = (args...) -> glorot_uniform(args...; gain = 1 / 25_0000)))
    model = Lux.Chain(preprocessing,
        DeepSet(Chain(Encoding(a, b, 1.5f0), chain)), tanh_fast)
    optim = OptimiserChain(AccumGrad(16), SignDecay(), WeightDecay(), Adam(0.01))
    with_logger(logger) do
        train((train_data, test_data),
            Lux.Experimental.TrainState(MersenneTwister(42), model, optim);
            nb_epoch = 10,
            save_periode = 1,
            r = 3.0f0,
            scale = 1.0f0)
    end
end
