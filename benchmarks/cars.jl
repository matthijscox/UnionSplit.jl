import UnionSplit
import WrappedUnions

N = 50  # Number of Car types to generate

abstract type AbstractCar end
# Generate Car types and weight methods
for i in 1:N
    eval(quote
        struct $(Symbol("Car$i")) <: AbstractCar end
        weight(::$(Symbol("Car$i"))) = $i * 100
    end)
end

# Create a Union of all Car types
car_types = [Symbol("Car$i") for i in 1:N]
CarUnion = eval(Expr(:curly, :Union, car_types...))

## functionality

# default behavior
safe_collision(c1::AbstractCar, c2::AbstractCar) = weight(c1) + weight(c2) < 1000
# some exceptions
safe_collision(c1::T, c2::T) where T<:AbstractCar = weight(c1) + weight(c2) < 1500
safe_collision(c1::Car1, c2::Car4) = true

function safety_matrix(vec1::AbstractVector{<:AbstractCar}, vec2::AbstractVector{<:AbstractCar}) 
    return Bool[safe_collision(c1, c2) for c1 in vec1, c2 in vec2]
end

## solution using WrappedUnions.jl
WrappedUnions.@wrapped struct WrappedCar <: AbstractCar
    union::CarUnion
end
weight(wc::WrappedCar) = WrappedUnions.@unionsplit weight(wc)
function safe_collision(wc1::WrappedCar, wc2::WrappedCar) 
    WrappedUnions.@unionsplit safe_collision(wc1, wc2)
end

## solution using UnionSplit.jl
struct WrappedCar2 <: AbstractCar
    union::CarUnion
end
weight(wc::WrappedCar2) = UnionSplit.@unionsplit weight(wc.union)
function safe_collision(wc1::WrappedCar2, wc2::WrappedCar2)
    UnionSplit.@unionsplit safe_collision(wc1.union, wc2.union)
end

## single dispatch type solution
struct Car <: AbstractCar
    model::Int
    weight::Int
end
weight(c::Car) = c.weight
function safe_collision(c1::Car, c2::Car)
    if c1.model == 1 && c2.model == 4
        return true
    elseif c1.model == c2.model
        return weight(c1) + weight(c2) < 1500
    else
        return weight(c1) + weight(c2) < 1000
    end
end

## benchmarking
car_vector = CarUnion[eval(Symbol("Car$i"))() for i in 1:N]
wrapped_car_vector = map(WrappedCar, car_vector)
wrapped_car2_vector = map(WrappedCar2, car_vector)
car_vector_ref = [Car(i, weight(c)) for (i, c) in enumerate(car_vector)]

using BenchmarkTools
println("Benchmarking safety_matrix with default union:")
@btime safety_matrix(car_vector, car_vector);
println("Benchmarking safety_matrix with WrappedUnions:")
@btime safety_matrix(wrapped_car_vector, wrapped_car_vector);
println("Benchmarking safety_matrix with UnionSplit:")
@btime safety_matrix(wrapped_car2_vector, wrapped_car2_vector);
println("Benchmarking safety_matrix with single dispatch Car type:")
@btime safety_matrix(car_vector_ref, car_vector_ref);