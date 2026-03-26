module UnionSplit


export @unionsplit

@generated function unionsplit_fields(f, ::Val{FIELDS}, args...) where {FIELDS}
    nargs = length(args)
    length(FIELDS) == nargs || error("Field tuple length must match argument count")

    xvars = [Symbol("x", i) for i in 1:nargs]
    type_lists = map(1:nargs) do i
        field = FIELDS[i]
        if field isa Symbol
            # Field access arg: derive union type from the struct field declaration.
            obj_T = Base.unwrap_unionall(args[i])
            field_T = Base.unwrap_unionall(fieldtype(obj_T, field))
            field_T isa Union ? Base.uniontypes(field_T) : [field_T]
        else
            # Plain value arg (FIELDS[i] === nothing): split on the static arg type.
            T = Base.unwrap_unionall(args[i])
            T isa Union ? Base.uniontypes(T) : [T]
        end
    end

    assignments = map(1:nargs) do i
        field = FIELDS[i]
        if field isa Symbol
            :(local $(xvars[i]) = getfield(args[$i], $(QuoteNode(field))))
        else
            :(local $(xvars[i]) = args[$i])
        end
    end
    dispatch_body = _build_switch_body(:f, xvars, type_lists)
    return Expr(:block, assignments..., dispatch_body)
end

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

# Parse a field access expression like `obj.field` into `(obj, field_symbol)`.
function _split_field_access(ex)
    ex isa Expr && ex.head === :. && length(ex.args) == 2 || return nothing

    field = ex.args[2]
    field isa QuoteNode && field.value isa Symbol || return nothing
    return (ex.args[1], field.value)
end

"""
    @unionsplit f(x::T₁, y::T₂, ...)
    @unionsplit f(x::T₁, y::T₂, ...)::R
    @unionsplit f(obj1.field1, obj2.field2, ...)

Generate an inline nested switch statement for use inside a function body.
Each argument must be written as `var::Type` where `var` is already bound in the enclosing
scope and `Type` is expanded into its union components.

As a convenience, you can also pass field accesses like `obj.field` without `::Type`.
In that form, the macro infers split branches from the static type of each expression.

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

    # Build the FIELDS tuple and args list for unionsplit_fields.
    # FIELDS[i] = Symbol  → field access: pass owner object, extract field, split on fieldtype
    # FIELDS[i] = nothing → plain value: pass value directly, split on its static type
    fields_for_gen = Any[]
    args_for_gen = Any[]

    for ex in arg_exprs
        if ex isa Expr && ex.head === :(::) && length(ex.args) == 2
            expr_before = ex.args[1]
            # Check if annotation target is a field access — if so, pass the owner
            split = _split_field_access(expr_before)
            if split !== nothing
                push!(args_for_gen, split[1])       # owner object
                push!(fields_for_gen, QuoteNode(split[2]))  # field symbol
            else
                push!(args_for_gen, expr_before)    # plain value
                push!(fields_for_gen, nothing)      # passthrough
            end
            continue
        end

        # Bare expression: must be a field access
        split = _split_field_access(ex)
        split === nothing &&
            error("Each argument must be `var::Type` or a field access `obj.field`, got: $ex")
        push!(args_for_gen, split[1])               # owner object
        push!(fields_for_gen, QuoteNode(split[2]))  # field symbol
    end

    unionsplit_ref = GlobalRef(@__MODULE__, :unionsplit_fields)
    fields_val = Expr(:call, :Val, Expr(:tuple, fields_for_gen...))
    dispatch_body = Expr(:call, unionsplit_ref, f, fields_val, args_for_gen...)

    # Optionally enforce result type once at the top level.
    if return_type !== nothing
        result_var = gensym(:result)
        dispatch_body = quote
            local $result_var = $dispatch_body
            $result_var::$return_type
        end
    end

    return esc(dispatch_body)
end

end # module UnionSplit
