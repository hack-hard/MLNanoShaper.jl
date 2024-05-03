module Import
using StructArrays
using GLMakie
using GeometryBasics
using TOML
using BioStructures
using ProjectRoot
export extract_balls
struct XYZR{T} end

function read_line(io::IO, ::Type{XYZR{T}}) where {T}
    line = readline(io)
    x, y, z, r = parse.(T, split(line))
    Sphere(Point3(x, y, z), r)
end
function Base.read(io::IO, ::Type{XYZR{T}}) where {T}
    out = Sphere{T}[]
    while !eof(io)
        push!(out, read_line(io, XYZR{T}))
    end
    out
end

function viz(x::AbstractArray{Sphere{T}}) where {T}
    fig = Figure()
    ax = Axis3(fig[1, 1])
    mesh!.(Ref(ax), x)
    fig
end

reduce(fun, arg) = mapreduce(fun, vcat, arg)
reduce(fun) = arg -> reduce(fun, arg)
function reduce(fun, arg, n::Integer)
    if n <= 1
        reduce(fun, arg)
    else
        reduce(reduce(fun), arg, n - 1)
    end
end

function export_file(io::IO, prot::AbstractArray{Sphere{T}}) where {T}
    for sph in prot
        println(io, sph.center[1], " ", sph.center[2], " ", sph.center[3], " ", sph.r)
    end
end

params = "$( dirname(dirname(@__FILE__)))/param/param.toml"

function extract_balls(T::Type{<:Number}, prot::ProteinStructure)
    radii = TOML.parsefile(params)["atoms"]["radius"] |> Dict{String, T}
    reduce(prot, 4) do atom
        if typeof(atom) == Atom
			Sphere{T}[Sphere(Point3(atom.coords) .|>T,
                if atom.element in keys(radii)
                    radii[atom.element]
                else
                    1.0
                end )]
        else
			Sphere{T}[]
        end
    end |> StructVector
end
end
