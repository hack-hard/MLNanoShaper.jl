using RegionTrees
using GeometryBasics


"""
	DensityRefinery(nb_points::Int,pos)
A refinery for RegionTrees. Given a Cell whose data is a vector, split the cell until each leaves has at most `nb_points` elements.

pos is a function which extract the pos from the cell element.
"""
struct DensityRefinery <: AbstractRefinery
    nb_points::Int
    pos::Function
end

function RegionTrees.refine_data(r::DensityRefinery, cell, indices)
    boundary = child_boundary(cell, indices)
    filter(cell.data) do point
        boundary.origin <= r.pos(point) <= boundary.origin + boundary.widths
    end
end
function RegionTrees.needs_refinement(refinery::DensityRefinery, cell)
    length(cell.data) > refinery.nb_points
end

"""
	distance2(x::Point3,y::Union{Point3,Mesh)
Compute the squared euclidian distance between x and y.

If y is a mesh, the distance is the minimum distance between x and vertices of y.
"""
distance2(x::Point3{T}, y::Point3{T}) where {T <: Number} = sum((x .- y) .^ 2)
distance2(x::Point3{Float32}, y::GeometryBasics.Mesh) = distance2(x, coordinates(y))

function distance2(x::Point3{T},
        y::Cell{<:AbstractVector{Point3{T}}, 3, T, <:Any}) where {T}
    distance2(x, findleaf(y, x).data)
end

function distance2(x::Point3{T}, y::AbstractArray{Point3{T}}) where {T}
    minimum(y) do y
        distance2(x, y)
    end
end

function filter_cells(test::Function, cell::Cell)
    res = Cell[]
    queue = [cell]
    while !isempty(queue)
        current = pop!(queue)
        if !test(current)
            continue
        end
        push!(res, current)
        if !isleaf(current)
            append!(queue, children(current))
        end
    end
    res
end

"""
	select_radius(cut_radius,point, atoms)
Given an octtree, return a vector of all the points that are in `cut_distance` of `point`.
"""
function select_radius(cut_radius::T,
        point::Point3{T},
        atoms::Cell{<:AbstractVector{Sphere{T}}, 3}) where {T}

    atoms = filter_cells(atoms) do node::Cell
        center = node.boundary.origin + node.boundary.widths / 2
        center = Point3(center...)
        widths = node.boundary.widths
        distance2(point, center) <= (cut_radius + sum(widths) / 2)^2
    end

	atoms = mapreduce(vcat, atoms;init=Sphere{T}[]) do node::Cell
        if isleaf(node)
            filter(node.data) do (; center)::Sphere
                distance2(point, center) <= (2 * cut_radius)^2
            end
        else
            Sphere{T}[]
        end
    end
    atoms
end
