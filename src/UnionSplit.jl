module UnionSplit


export @unionsplit

# Resolve a type expression, evaluating only explicit interpolation.
function _resolve_type(ex, mod)
    if ex isa Expr && ex.head === :$
        return Base.unwrap_unionall(Base.eval(mod, ex.args[1]))
    else
        return ex
    end
end

# Expand concrete unions and literal `Union{...}` syntax into branch type lists.
function _expand_union_like(T)
    if T isa Union
        return Base.uniontypes(T)
    elseif T isa Expr && T.head === :curly && T.args[1] === :Union
        return T.args[2:end]
    else
        return [T]
    end
end

# Generate a switch expression using `if` / `elseif` / `else`.
function _generate_switch_stmt(cond_exprs, branch_exprs, default_expr)
    length(cond_exprs) == length(branch_exprs) ||
        error("Condition and branch counts must match")

    expr = default_expr
    for i in length(cond_exprs):-1:1
        head = i == 1 ? :if : :elseif
        expr = Expr(head, cond_exprs[i], branch_exprs[i], expr)
    end
    return expr
end

# Recursively build the nested if/elseif dispatch body from already-resolved type lists.
function _build_switch_body(f, xvars, type_lists)
    nargs = length(type_lists)

    function build_tree(argidx)
        if argidx > nargs
            return Expr(:call, f, xvars...)
        end

        cond_exprs = [ :($(xvars[argidx]) isa $(T)) for T in type_lists[argidx] ]
        nested_expr = build_tree(argidx + 1)
        branch_exprs = fill(nested_expr, length(type_lists[argidx]))
        default_expr = Expr(:call, f, xvars...)
        return _generate_switch_stmt(cond_exprs, branch_exprs, default_expr)
    end

    return build_tree(1)
end

"""
    @unionsplit f(x::T₁, y::T₂, ...)
    @unionsplit f(x::T₁, y::T₂, ...)::R

Generate an inline nested switch statement for use inside a function body.
Each argument must be written as `var::Type` where `var` is already bound in the enclosing
scope and `Type` is expanded into its union components.

Optionally you can provide the return type `R` to enforce that the generated code returns a value of that type. 
This is useful to prevent type inference from widening the return type when there are many branches.

Note that when you interpolate the type with `\$`, the macro will resolve the (module-specific) type at macro expansion time.
Otherwise it will assume the type is a Base or local Module type, which means it might fail at runtime if the type/symbol is not available.

# Example

```julia
f(::Real, ::Real) = 0.0
f(::Real, ::String) = 1.0
f(::String, ::Real) = -1.0
f(::String, ::String) = 2.0

const U = Union{Real, String}
f_typesplit(x, y) = @unionsplit f(x::\$U, y::\$U)

f_typesplit(5, "b") == f(5, "b")
```
"""
macro unionsplit(expr)
    call_expr = expr
    return_type = nothing

    # Optional outer return annotation: @unionsplit f(x::T, y::T)::R
    if expr isa Expr && expr.head === :(::) && length(expr.args) == 2
        call_expr = expr.args[1]
        return_type = _resolve_type(expr.args[2], __module__)
    end

    call_expr isa Expr && call_expr.head === :call ||
        error("Usage: @unionsplit f(x::T1, y::T2, ...)")

    f = call_expr.args[1]
    arg_exprs = call_expr.args[2:end]

    xvars_exprs = Any[]  # The expressions from call site (e.g., x, y, ...)
    xvars = Symbol[]     # Local variable names inside our switch (x1 = x, x2 = y, ...)
    type_specs = []      # The type of each variable `x::T` to resolve
    for (i, ex) in enumerate(arg_exprs)
        ex isa Expr && ex.head === :(::) && length(ex.args) == 2 ||
            error("Each argument must be of the form `var::Type`, got: $ex")
        ex.args[1] === nothing &&
            error("Argument annotation must include an expression before `::`, got: $ex")
        ex.args[2] === nothing &&
            error("Argument annotation must include a type after `::`, got: $ex")
        push!(xvars_exprs, ex.args[1])
        push!(xvars, Symbol("x", i))
        push!(type_specs, ex.args[2])
    end

    specs = map(ts -> _resolve_type(ts, __module__), type_specs)
    type_lists = map(_expand_union_like, specs)
    dispatch_body = _build_switch_body(f, xvars, type_lists)

    # Optionally enforce result type once at the top level.
    if return_type !== nothing
        result_var = gensym(:result)
        dispatch_body = quote
            local $result_var = $dispatch_body
            $result_var::$return_type
        end
    end

    # Build let block: let x1 = expr1, x2 = expr2, ...; dispatch_body; end
    let_block = Expr(:block, [Expr(:(=), xvars[i], xvars_exprs[i]) for i in eachindex(xvars)]...)
    let_expr = Expr(:let, let_block, dispatch_body)

    return esc(let_expr)
end

end # module UnionSplit
