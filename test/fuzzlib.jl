using SymbolicUtils
using Test

using SymbolicUtils: showraw, Symbolic

function rand_input(T)
    if T == Bool
        return rand(Bool)
    elseif T <: Integer
        x = rand(-100:100)
        while iszero(x)
            x = rand(-100:100)
        end
        return x
    elseif T == Rational
        return Rational(rand_input(Int), rand(1:50)) # no 0 denominator tests yet!
    elseif T == Real
        return rand_input(rand([Int, Float64, Rational]))
    elseif T == Complex
        return rand_input(Real) + rand_input(Real) * im
    elseif T == Number
        # more real than complex
        return rand_input(rand([Real, Real, Real, Complex{Float64}]))
    elseif !isabstracttype(T)
        return rand(T)
    else
        error("Don't know how to generate input of type $T")
    end
end

rand_input(i::Symbolic{T}) where {T} = rand_input(T)

const num_spec = let
    @syms a b::Real c::Integer d::Float64 e::Rational f

    leaf_funcs = [()->rand_input(Real),
                  ()->rand_input(Complex),
                  ()->rand([a b c d e f]),
                  ()->rand([a b c d e f])]

    binops = SymbolicUtils.diadic
    nopow  = filter(x->x!==(^), binops)
    twoargfns = vcat(nopow, (x,y)->x isa Union{Int, Rational, Complex{<:Rational}} ? x * y : x^y)
    fns = vcat(1 .=> vcat(SymbolicUtils.monadic, [one, zero]),
               2 .=> vcat(twoargfns, fill(+, 5), [-,-], fill(*, 5)),
    3 .=> [+, *])


    (leaves=leaf_funcs, funcs=fns, input=rand_input)
end

const bool_spec = let
    @syms b::Bool x::Real y::Real z::Complex

    bool_leaf_funcs = [()->rand(Bool),
                       ()->rand([b, (x, b) => ((x > 0) | b), (x,)=>(x < 0), (y,z) => y==z, (y, z) => y!=z])]

    fns = vcat(1 .=> [(!), (~)],
               2 .=> [(|), (&), xor],
               3 .=> [cond]) # cond will still stay in bool by condtruction

    (leaves=bool_leaf_funcs,
     funcs=fns,
     input=rand_input
    )
end

function gen_rand_expr(inputs;
                       spec=num_spec,
                       leaf_prob=0.92,
                       depth=0,
                       min_depth=1,
                       max_depth=5)

    if depth > max_depth  || (min_depth <= depth && rand() < leaf_prob)
        leaf = rand(spec.leaves)()
        if leaf isa SymbolicUtils.Sym
            push!(inputs, leaf)
        elseif leaf isa Pair
            foreach(i->push!(inputs, i), leaf[1])
            return leaf[2]
        end
        return leaf
    end
    arity, f = rand(spec.funcs)
    args = [gen_rand_expr(inputs,
                          spec=spec,
                          leaf_prob=leaf_prob,
                          depth=depth+1,
                          min_depth=min_depth,
                          max_depth=max_depth) for i in 1:arity]
    try
        return f(args...)
    catch err
        if err isa DomainError || err isa DivideError || err isa MethodError ||
            err isa SymbolicUtils.SpecialFunctions.AmosException
            return gen_rand_expr(inputs,
                                 spec=spec,
                                 leaf_prob=leaf_prob,
                                 depth=depth,
                                 min_depth=min_depth,
                                 max_depth=max_depth)
        else
            rethrow(err)
        end
    end
end

struct Errored
    err
end

function fuzz_test(ntrials, spec, simplify=simplify;kwargs...)
    inputs = Set()
    expr = gen_rand_expr(inputs; spec=spec, kwargs...)
    inputs = collect(inputs)
    unsimplifiedstr = """
    function $(tuple(inputs...))
        $(sprint(io->showraw(io, expr)))
    end
    """

    simplifiedstr = """
    function $(tuple(inputs...))
        $(sprint(io->showraw(io, simplify(expr))))
    end
    """
    f = include_string(Main, unsimplifiedstr)
    g = include_string(Main, simplifiedstr)

    for i=1:ntrials
        args = [spec.input(i) for i in inputs]
        unsimplified = try
            Base.invokelatest(f, args...)
        catch err
            Errored(err)
        end

        simplified  = try
            Base.invokelatest(g, args...)
        catch err
            Errored(err)
        end
        if unsimplified isa Errored
            if !(simplified isa Errored)
                @test_skip false
                @goto print_err
            end
            @test true
        elseif simplified isa Errored
            if !(unsimplified isa Errored)
                @test_skip false
                @goto print_err
            end
            @test true
        elseif isnan(unsimplified)
            if !isnan(simplified)
                @test_skip false
                @goto print_err
            end
            @test true
        elseif isnan(simplified)
            if !isnan(unsimplified)
                @test_skip false
                @goto print_err
            end
            @test true
        else
            if !(unsimplified ≈ simplified)
                @test_skip false
                @goto print_err
            end
            @test true
        end
        continue

        @label print_err
        println("""Test failed for expression
                    $(sprint(io->showraw(io, expr))) = $unsimplified
                Simplified:
                    $(sprint(io->showraw(io, simplify(expr)))) = $simplified
                Inputs:
                    $inputs = $args
                """)
    end
end
