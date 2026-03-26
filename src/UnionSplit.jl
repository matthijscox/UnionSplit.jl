module UnionSplit


export @unionsplit

@generated function unionsplit_fields(f, ::Val{FIELDS}, objs...) where {FIELDS}
    nargs = length(objs)
    length(FIELDS) == nargs || error("Field tuple length must match argument count")

    xvars = [Symbol("x", i) for i in 1:nargs]
    type_lists = map(1:nargs) do i
        obj_T = Base.unwrap_unionall(objs[i])
        field = FIELDS[i]
        field isa Symbol || error("Expected Symbol field name, got: $field")
        field_T = Base.unwrap_unionall(fieldtype(obj_T, field))
        if field_T isa Union
            Base.uniontypes(field_T)
        else
            [field_T]
        end
    end

    dispatch_body = _build_switch_body(:f, xvars, type_lists)
    assignments = [:(local $(xvars[i]) = getfield(objs[$i], $(QuoteNode(FIELDS[i])))) for i in 1:nargs]
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

    xvars_exprs = Any[]  # The expressions from call site (e.g., obj for field access, or var for annotated)
    xvars = Symbol[]     # Local variable names inside our switch (x1 = x, x2 = y, ...)
    type_specs = Any[]   # Type specs for each arg: explicit types or :inferred sentinel
    field_symbols = Any[]  # Field symbols for inferred args, or nothing for annotated
    has_inferred = false

    for (i, ex) in enumerate(arg_exprs)
        if ex isa Expr && ex.head === :(::) && length(ex.args) == 2
            # Annotated: var::Type or obj.field::Type
            ex.args[1] === nothing &&
                error("Argument annotation must include an expression before `::`, got: $ex")
            ex.args[2] === nothing &&
                error("Argument annotation must include a type after `::`, got: $ex")
            
            expr_before = ex.args[1]
            type_spec = ex.args[2]
            
            # Check if it's a field access (dot expression)
            split = _split_field_access(expr_before)
            if split !== nothing
                # Annotated field access: expr.field::Type
                push!(xvars_exprs, split[1])  # obj
                push!(xvars, Symbol("x", i))
                push!(type_specs, type_spec)
                push!(field_symbols, split[2])  # field symbol
                has_inferred = true
            else
                # Regular annotated: var::Type
                push!(xvars_exprs, expr_before)
                push!(xvars, Symbol("x", i))
                push!(type_specs, type_spec)
                push!(field_symbols, nothing)
            end
            continue
        end

        # Inferred: must be obj.field without type annotation
        split = _split_field_access(ex)
        split === nothing &&
            error("Each argument must be `var::Type` or a field access `obj.field`, got: $ex")
        
        push!(xvars_exprs, split[1])  # obj
        push!(xvars, Symbol("x", i))
        push!(type_specs, nothing)
        push!(field_symbols, split[2])  # field symbol
    end

    # Check if all arguments are inferred
    all_inferred = !any(isnothing(f) for f in field_symbols)

    dispatch_body = if all_inferred
        # All inferred - use generated helper for efficiency
        field_exprs = [QuoteNode(f) for f in field_symbols]
        fields_val = Expr(:call, :Val, Expr(:tuple, field_exprs...))
        infer_call_ref = GlobalRef(@__MODULE__, :unionsplit_fields)
        Expr(:call, infer_call_ref, f, fields_val, xvars...)
    else
        # Annotated or mixed - inline dispatch (compute fieldtype at runtime for inferred)
        resolved_specs = []
        for i in 1:length(type_specs)
            if field_symbols[i] !== nothing
                # Inferred arg: compute fieldtype at runtime
                obj = xvars_exprs[i]
                field = field_symbols[i]
                spec = :(Base.unwrap_unionall(fieldtype(_argtype($obj), $(QuoteNode(field)))))
            else
                # Annotated arg: use provided type
                spec = _resolve_type(type_specs[i], __module__)
            end
            push!(resolved_specs, spec)
        end
        
        specs = resolved_specs
        type_lists = map(_expand_union_like, specs)
        _build_switch_body(f, xvars, type_lists)
    end

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
