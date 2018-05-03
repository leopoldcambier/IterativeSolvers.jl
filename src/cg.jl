import Base: start, next, done

export cg, cg!, CGIterable, PCGIterable, cg_iterator!

mutable struct CGIterable{matT, solT, vecT, numT <: Real}
    A::matT
    x::solT
    r::vecT
    c::vecT
    u::vecT
    reltol::numT
    residual::numT
    prev_residual::numT
    maxiter::Int
    mv_products::Int
end

mutable struct PCGIterable{precT, matT, solT, vecT, numT <: Real, paramT <: Number}
    Pl::precT
    A::matT
    x::solT
    r::vecT
    c::vecT
    u::vecT
    reltol::numT
    residual::numT
    ρ::paramT
    maxiter::Int
    mv_products::Int
end

@inline converged(it::Union{CGIterable, PCGIterable}) = it.residual ≤ it.reltol

@inline start(it::Union{CGIterable, PCGIterable}) = 0

@inline done(it::Union{CGIterable, PCGIterable}, iteration::Int) = iteration ≥ it.maxiter || converged(it)


###############
# Ordinary CG #
###############

function next(it::CGIterable, iteration::Int)
    # u := r + βu (almost an axpy)
    β = it.residual^2 / it.prev_residual^2
    it.u .= it.r .+ β .* it.u

    # c = A * u
    A_mul_B!(it.c, it.A, it.u)
    α = it.residual^2 / dot(it.u, it.c)

    # Improve solution and residual
    it.x .+= α .* it.u
    it.r .-= α .* it.c

    it.prev_residual = it.residual
    it.residual = norm(it.r)

    # Return the residual at item and iteration number as state
    it.residual, iteration + 1
end

#####################
# Preconditioned CG #
#####################

function next(it::PCGIterable, iteration::Int)
    A_ldiv_B!(it.c, it.Pl, it.r)

    ρ_prev = it.ρ
    it.ρ = dot(it.c, it.r)
    
    # u := c + βu (almost an axpy)
    β = it.ρ / ρ_prev
    it.u .= it.c .+ β .* it.u

    # c = A * u
    A_mul_B!(it.c, it.A, it.u)
    α = it.ρ / dot(it.u, it.c)

    # Improve solution and residual
    it.x .+= α .* it.u
    it.r .-= α .* it.c

    it.residual = norm(it.r)

    # Return the residual at item and iteration number as state
    it.residual, iteration + 1
end

# Utility functions

function cg_iterator!(x, A, b, Pl = Identity();
    tol = sqrt(eps(real(eltype(b)))),
    maxiter::Int = size(A, 2),
    initially_zero::Bool = false
)
    u = zeros(x)
    r = similar(x)
    copy!(r, b)

    # Compute r with an MV-product or not.
    if initially_zero
        mv_products = 0
        c = similar(x)
        residual = norm(b)
        reltol = residual * tol # Save one dot product
    else
        mv_products = 1
        c = A * x
        r .-= c
        residual = norm(r)
        reltol = norm(b) * tol
    end

    # Return the iterable
    if isa(Pl, Identity)
        return CGIterable(A, x, r, c, u,
            reltol, residual, one(residual),
            maxiter, mv_products
        )
    else
        return PCGIterable(Pl, A, x, r, c, u,
            reltol, residual, one(eltype(x)),
            maxiter, mv_products
        )
    end
end

"""
    cg(A, b; kwargs...) -> x, [history]

Same as [`cg!`](@ref), but allocates a solution vector `x` initialized with zeros.
"""
cg(A, b; kwargs...) = cg!(zerox(A, b), A, b; initially_zero = true, kwargs...)

"""
    cg!(x, A, b; kwargs...) -> x, [history]

# Arguments

- `x`: Initial guess, will be updated in-place;
- `A`: linear operator;
- `b`: right-hand side.

## Keywords

- `initially_zero::Bool`: If `true` assumes that `iszero(x)` so that one 
  matrix-vector product can be saved when computing the initial 
  residual vector;
- `Pl = Identity()`: left preconditioner of the method. Should be symmetric, 
  positive-definite like `A`.
- `tol::Real = sqrt(eps(real(eltype(b))))`: tolerance for stopping condition `|r_k| / |r_0| ≤ tol`;
- `maxiter::Int = size(A,2)`: maximum number of iterations;
- `verbose::Bool = false`: print method information;
- `log::Bool = false`: keep track of the residual norm in each iteration;

# Output

**if `log` is `false`**

- `x`: approximated solution.

**if `log` is `true`**

- `x`: approximated solution.
- `ch`: convergence history.

**ConvergenceHistory keys**

- `:tol` => `::Real`: stopping tolerance.
- `:resnom` => `::Vector`: residual norm at each iteration.
"""
function cg!(x, A, b;
    tol = sqrt(eps(real(eltype(b)))),
    maxiter::Int = size(A, 2),
    log::Bool = false,
    verbose::Bool = false,
    Pl = Identity(),
    kwargs...
)
    history = ConvergenceHistory(partial = !log)
    history[:tol] = tol
    log && reserve!(history, :resnorm, maxiter + 1)
    log && reserve!(history, :x,       maxiter + 1, length(x))

    # Actually perform CG
    iterable = cg_iterator!(x, A, b, Pl; tol = tol, maxiter = maxiter, kwargs...)
    if log
        history.mvps = iterable.mv_products
    end
    for (iteration, item) = enumerate(iterable)
        if log
            nextiter!(history, mvps = 1)
            push!(history, :resnorm, iterable.residual)
            push!(history, :x,       copy(iterable.x))
        end
        verbose && @printf("%3d\t%1.2e\n", iteration, iterable.residual)
    end

    verbose && println()
    log && setconv(history, converged(iterable))
    log && shrink!(history)

    log ? (iterable.x, history) : iterable.x
end
