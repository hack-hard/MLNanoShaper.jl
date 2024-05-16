using Comonicon
Option{T} = Union{T, Nothing}
"""
    train

Train a model.
Parameters are specified in the `param/param.toml` file.
The folowing parameters can be overided.

# Options
- `-e, --nb-epoch=Uint`; the number of epoch to compute.
- `-m, --model=String`; the model name. Can be anakin.

"""
@main function train(; nb_epoch::Option{UInt} = nothing, model::Option{String} = nothing,
	nb_data_points::Option{UInt} = nothing,name::Option{String} = nothing,cutoff_radius::Option{Float32}=nothing)
    conf = TOML.parsefile(params_file)
    if !isnothing(nb_epoch)
        conf["Training_parameters"]["nb_epoch"] = nb_epoch
    end
    if !isnothing(cutoff_radius)
        conf["Training_parameters"]["cutoff_radius"] = cutoff_radius
    end
    if !isnothing(name)
		conf["Training_parameters"]["name"] = name
    end
    if !isnothing(model)
        conf["Training_parameters"]["model"] = model
    end
    if !isnothing(nb_data_points)
        conf["Training_parameters"]["data_ids"] = conf["Training_parameters"]["data_ids"][begin:(begin + nb_data_points)]
    end

    training_parameters = read_from_TOML(Training_parameters, conf)
    auxiliary_parameters = read_from_TOML(Auxiliary_parameters, conf)
    @info "Starting training"
    train(training_parameters, auxiliary_parameters)
    @info "Stop training"
end
