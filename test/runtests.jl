using UnionSplit, Test, JET

# Main union type
const MyUnion = Union{Float64, Int64, String}

# union definitions may come from other modules, and we want to make sure we can handle them as well
module MyModule
    const MyUnion2 = Union{Float64, Int64, String}
end
import .MyModule: MyUnion2

do_something(::Real, ::Real) = 0.0
do_something(::T, ::T) where T<:Real = 0.5
do_something(::Real, ::String) = 1.0
do_something(::String, ::Real) = -1.0
do_something(::String, ::String) = 2.0

# an iterating function that will become dynamic for too many element types in Vector{T}
function create_matrix(vec1::AbstractArray, vec2::AbstractArray)
    M = zeros(Float64, length(vec1), length(vec2))
    for (i, x1) = enumerate(vec1)
        for (j, x2) = enumerate(vec2)
            M[i,j] = do_something(x1, x2)
        end
    end
    return M
end

# we use this wrapper type to dispatch in the original function inside `create_matrix`, and then call the static version
struct SplitWrapper; x::MyUnion; end
function do_something(t1::SplitWrapper, t2::SplitWrapper)
    @unionsplit do_something(t1.x::$MyUnion, t2.x::$MyUnion)::Float64
end
# use a const imported from another module
# also testing that the output type is optional
struct SplitWrapper2; x::MyUnion2; end
function do_something(t1::SplitWrapper2, t2::SplitWrapper2)
    @unionsplit do_something(t1.x::$MyUnion2, t2.x::$MyUnion2)
end

@testset "UnionSplit" begin
    vec1 = MyUnion[1.0, 1, "1"]
    vec2 = MyUnion[1.0, 1, "1"]
    vec1_u = map(SplitWrapper, vec1)
    vec2_u = map(SplitWrapper, vec2)
    @test create_matrix(vec1_u, vec2_u) == create_matrix(vec1, vec2)

    r1 = @report_opt create_matrix(vec1, vec2)
    # check that this cannot be unionsplit anymore (might change in future Julia version, but I want to make sure we test an actual problem here)
    @test length(JET.get_reports(r1)) > 0
    r2 = @report_opt create_matrix(vec1_u, vec2_u)
    # test that we have no JET issues with our unionsplit version
    @test length(JET.get_reports(r2)) == 0

    vec1_u2 = map(SplitWrapper2, vec1)
    vec2_u2 = map(SplitWrapper2, vec2)
    @test create_matrix(vec1_u2, vec2_u2) == create_matrix(vec1, vec2)
    r3 = @report_opt create_matrix(vec1_u2, vec2_u2)
    @test length(JET.get_reports(r3)) == 0
end