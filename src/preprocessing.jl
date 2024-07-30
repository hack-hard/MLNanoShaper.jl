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
    atoms::AnnotedKDTree{Sphere{T}, :center, Point3{T}}
    skin::RegionMesh
end
function TreeTrainingData((; atoms, skin)::TrainingData)
    TreeTrainingData(AnnotedKDTree(atoms, static(:center)), RegionMesh(skin))
end
function point_grid(mins::AbstractVector, maxes, scale::Number)
    Iterators.product(range.(mins,
        maxes
        ; step = scale)...) .|> Point3
end
function approximates_points(predicate, rng::AbstractRNG, atoms_tree::KDTree,
        skin_tree::KDTree{Point3f},
        (; scale,
            cutoff_radius)::TrainingParameters)
    (; mins, maxes) = atoms_tree.hyper_rec
    points = first(
        shuffle(
            rng, point_grid(mins, maxes, scale)),
        2000)
    Iterators.filter(points) do point
        distance(point, atoms_tree) < cutoff_radius &&
            predicate(point)
    end
end

function exact_points(
        rng::AbstractRNG, atoms_tree::KDTree, skin_tree::KDTree, (;
            cutoff_radius)::TrainingParameters)
    points = first(shuffle(rng, skin_tree.data), 200)
    Iterators.filter(points) do pt
        distance(pt, atoms_tree) < cutoff_radius
    end
end
function aggregate(vec::AbstractVector{T})::T where T <: GlobalPreprocessed
	(;inputs,d_reals) = vec |> StructVector
	inputs = MLNanoShaperRunner.stack_ConcatenatedBatch(inputs)
	d_reals = reduce(vcat,d_reals)
	(;inputs,d_reals)
end
"""
    generate_data_points(
        preprocessing::Lux.AbstractExplicitLayer, points::AbstractVector{<:Point3},
        (; atoms, skin)::TreeTrainingData{Float32}, (; ref_distance)::TrainingParameters)

generate the data_points for a set of positions `points` on one protein.
"""
function generate_data_points(
        preprocessing::Lux.AbstractExplicitLayer, points::AbstractVector{<:Point3},
        (; atoms, skin)::TreeTrainingData{Float32}, (; ref_distance)::TrainingParameters)::GlobalPreprocessed
    (;
        inputs = preprocessing((Batch(points), atoms)),
        d_reals = signed_distance.(points, Ref(skin)) ./ ref_distance
    )
end
function pre_compute_data_set(points_generator::Function,
        preprocessing,
        dataset::AbstractVector{<:TreeTrainingData}, training_parameters::TrainingParameters)::GlobalPreprocessed
    map(dataset) do protein_data::TreeTrainingData
		points::AbstractVector{<:Point3} = points_generator(protein_data)
        generate_data_points(
            preprocessing, points, protein_data, training_parameters)
    end |> aggregate
end
"""
	load_data_pdb(T, name::String)

Load a `TrainingData{T}` from current directory.
You should have a pdb and an off file with name `name` in current directory.
"""
function load_data_pdb(T::Type{<:Number}, name::String)
    TrainingData{T}(extract_balls(T, read("$name.pdb", PDBFormat)), load("$name.off"))
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
