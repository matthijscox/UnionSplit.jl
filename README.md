# UnionSplit.jl
Yet another union splitting macro package. Manual union splitting helps to avoid dynamic dispatch.

Unlike ManualDispatch.jl this works with any number of arguments. Unlike WrappedUnions.jl this doesn't require wrapped types, yet we can still infer the field types in the macro. 

## Wrapping the union

Here's our starting code:

```julia

# we have some desired function we want to extend later
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

```

Currently this is type unstable, causing JET errors and --trim incompatible.

```julia
julia> using JET

# this is type unstable; dispatching on Vector{Any}
julia> vec1 = [1.0, 1, "1"];
julia> vec2 = [1.0, 1, "1"];
julia> @report_opt create_matrix(vec1, vec2)
[ Info: tracking Base
═════ 2 possible errors found ═════
┌ create_matrix(vec1::Vector{Any}, vec2::Vector{Any}) @ Main ./REPL[20]:5
│┌ setindex!(::Matrix{Float64}, ::Any, ::Int64, ::Int64) @ Base ./array.jl:996
││ runtime dispatch detected: convert(::Float64, x::Any)::Any
│└────────────────────
┌ create_matrix(vec1::Vector{Any}, vec2::Vector{Any}) @ Main ./REPL[20]:5
│ runtime dispatch detected: do_something(%127::Any, %176::Any)::Any
└────────────────────

# Though can fix this with a small Union, here's with 3 x 2 types (6 total):
julia> vec1 = Union{Float64, Int64, String}[1.0, 1, "1"]
julia> vec2 = Union{Float64, Int64}[1.0, 1]
julia> @report_opt create_matrix(vec1, vec2)
No errors detected

# Yere we become type unstable again (9 types):
julia> vec1 = Union{Float64, Int64, String}[1.0, 1, "1"]
julia> vec2 = Union{Float64, Int64, String}[1.0, 1, "1"]
julia> @report_opt create_matrix(vec1, vec2)
═════ 2 possible errors found ═════
┌ create_matrix(vec1::Vector{Union{Float64, Int64, String}}, vec2::Vector{Union{Float64, Int64, String}}) @ Main ./REPL[20]:5
│┌ setindex!(::Matrix{Float64}, ::Any, ::Int64, ::Int64) @ Base ./array.jl:996
││ runtime dispatch detected: convert(::Float64, x::Any)::Any
│└────────────────────
┌ create_matrix(vec1::Vector{Union{Float64, Int64, String}}, vec2::Vector{Union{Float64, Int64, String}}) @ Main ./REPL[20]:5
│ runtime dispatch detected: do_something(%127::Union{Float64, Int64, String}, %176::Union{Float64, Int64, String})::Any
└────────────────────
```

To fix this for any number of types in the Union, just wrap your union in a struct and then dispatch on that (now it's a single dispatch):

```julia
# we use this wrapper type to dispatch in the original function inside `create_matrix`, and then call the static version
struct SplitWrapper
    x::Union{Float64, Int64, String}
end
function do_something(sw1::SplitWrapper, sw2::SplitWrapper)
    @unionsplit do_something(sw1.x, sw2.x)
end
```

This fixes our dynamic dispatch:

```julia
julia> vec1_u = map(SplitWrapper, vec1);

julia> vec2_u = map(SplitWrapper, vec2);

julia> create_matrix(vec1_u, vec2_u) == create_matrix(vec1, vec2)
true

julia> r = @report_opt create_matrix(vec1_u, vec2_u)
No errors detected

```

## Inside a matrix generation

You can also just drop this macro inside the function as well.

```julia
function create_matrix_split(vec1::AbstractArray, vec2::AbstractArray)
    M = zeros(Float64, length(vec1), length(vec2))
    for (i, x1) = enumerate(vec1)
        for (j, x2) = enumerate(vec2)
            M[i,j] = @unionsplit do_something(x1::$U, x2::$U)::Float64
        end
    end
    return M
end
```

## Related packages
* https://github.com/ztangent/ValSplit.jl
* https://github.com/jlapeyre/ManualDispatch.jl
* https://github.com/melonedo/SingleDispatchArrays.jl
* https://github.com/JuliaAPlavin/UnionCollections.jl
* https://github.com/JuliaFolds/UnionArrays.jl
* https://github.com/ameligrana/WrappedUnions.jl

See also:
* https://discourse.julialang.org/t/union-splitting-vs-c/
* https://discourse.julialang.org/t/macro-to-write-function-with-many-conditionals/51616/8
