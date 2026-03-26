using UnionSplit, Test, JET

# Main union type
const MyUnion = Union{Float64, Int64, String}

# union definitions may come from other modules, and we want to make sure we can handle them as well
module MyModule
    const MyUnion2 = Union{Float64, Int64, String}
end
import .MyModule: MyUnion2

macro evalerror(ex)
    quote
        try
            @eval $(esc(ex))
            ""
        catch e
            sprint(showerror, e)
        end
    end
end

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
function do_something(sw1::SplitWrapper, sw2::SplitWrapper)
    @unionsplit do_something(sw1.x::$MyUnion, sw2.x::$MyUnion)::Float64
end
# use a const imported from another module
# also testing mixed type annotation
struct SplitWrapper2; x::MyUnion2; end
function do_something(sw1::SplitWrapper2, sw2::SplitWrapper2)
    @unionsplit do_something(sw1.x, sw2.x::$MyUnion2)
end

# mixing 3 arguments to test the mixing limits
do_something_triple(x, y, z) = do_something(x,y)
function do_something(sw1::SplitWrapper, sw2::SplitWrapper2)
    @unionsplit do_something_triple(sw1.x, sw2.x, 1.0::Real)
end

struct PairWrap
    x::MyUnion
    y::MyUnion2
end
# no type annotation is needed at all for field access
function do_something(p::PairWrap)
    @unionsplit do_something(p.x, p.y)
end
function do_something_unsplit(p::PairWrap)
    do_something(p.x, p.y)
end

@testset "UnionSplit" begin
    vec1 = MyUnion[1.0, 1, "1"]
    vec2 = MyUnion[1.0, 1, "1"]

    # regular call should work as expected
    out = @unionsplit do_something(vec1[1]::$MyUnion, vec2[2]::$MyUnion)::Float64
    @test out == do_something(vec1[1], vec2[2])

    sw = SplitWrapper(1)
    out = @unionsplit do_something(sw.x, 1.0::Real)
    @test out == do_something(sw.x, 1.0)

    # test matrix creation with unionsplit
    vec1_u = map(SplitWrapper, vec1)
    vec2_u = map(SplitWrapper, vec2)
    @test create_matrix(vec1_u, vec2_u) == create_matrix(vec1, vec2)

    # check that this cannot be unionsplit anymore (might change in future Julia version, but I want to make sure we test an actual problem here)
    r1 = @report_opt create_matrix(vec1, vec2)
    @test length(JET.get_reports(r1)) > 0
    # test that we have no JET issues with our unionsplit version
    r2 = @report_opt create_matrix(vec1_u, vec2_u)
    @test length(JET.get_reports(r2)) == 0

    vec1_u2 = map(SplitWrapper2, vec1)
    vec2_u2 = map(SplitWrapper2, vec2)
    @test create_matrix(vec1_u2, vec2_u2) == create_matrix(vec1, vec2)
    r3 = @report_opt create_matrix(vec1_u2, vec2_u2)
    @test length(JET.get_reports(r3)) == 0

    # triple mix test
    @test create_matrix(vec1_u, vec2_u2) == create_matrix(vec1, vec2)
    r = @report_opt create_matrix(vec1_u, vec2_u2)

    pair_matrix = [PairWrap(v1, v2) for v1 in vec1, v2 in vec2]
    @test map(do_something, pair_matrix) == map(do_something_unsplit, pair_matrix)
    r = @report_opt map(do_something_unsplit, pair_matrix)
    @test length(JET.get_reports(r)) > 0
    r = @report_opt map(do_something, pair_matrix)
    @test length(JET.get_reports(r)) == 0
end

@testset "UnionSplit errors" begin
    err = @evalerror function _bad_unionsplit_usage(a)
        @unionsplit a
    end
    @test occursin("Usage: @unionsplit f(x::T1, y::T2, ...)", err)

    err = @evalerror function _bad_unionsplit_arg(t1::SplitWrapper, t2::SplitWrapper)
        @unionsplit do_something(t1.x, t2)
    end
    @test occursin("Each argument must be `var::Type` or a field access `obj.field`", err)
end