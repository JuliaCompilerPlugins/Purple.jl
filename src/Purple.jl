module Purple

using Mixtape
import Mixtape: CompilationContext, transform, allow, optimize!
using Core.Compiler: compact!, getfield_elim_pass!, adce_pass!
using CodeInfoTools
using CodeInfoTools: resolve
using SymbolicUtils
using SymbolicUtils: Symbolic, term, Sym, similarterm, promote_symtype

#####
##### Exports
#####

export lift, deactivate, activate

#####
##### Purple
#####

# Utility functions for lifting / de-lifting to and from Sym types.
unwrap(s::Type{Sym{T, K}}) where {T, K} = T
unwrap(s::Type) = s
wrap(t::Type{T}) where T = Sym{T, Nothing}

# `activate` is a "semantic stub" function which gets filled in by
# the src of Tuple{typeof(f), syms...}.
# In short, `activate` activates the transform at that call site.
function activate(f::Function, syms::S) where S <: Tuple
    return f(syms...)
end

# `deactivate` is a fallback stub which just constructs a new Term.
function deactivate(f::Function, syms::S) where S <: Tuple
    return term(f, syms...)
end

# Compilation context to control the Mixtape pipeline.
struct LiftContext <: CompilationContext
    opt::Bool
end

# Turn on the transform for `activate`.
allow(ctx::LiftContext, mod::Module, fn::typeof(activate), inner, args...) = true

# Wrap each call with `deactivate`.
# Otherwise, if the Expr has .head == :(=), try and wrap the RHS.
function swap!(b, v, st::Expr, slotmap)
    if st.head == :call
        args = walk(l -> resolve(get(slotmap, l, l)), st).args[2 : end]
        atup = push!(b, Expr(:call, tuple, args...))
        return Expr(:call, deactivate, st.args[1], atup)
    elseif st.head == :(=) && 
        st.args[2] isa Expr &&
        st.args[2].head == :call
        callexpr = st.args[2]
        args = walk(l -> resolve(get(slotmap, l, l)), callexpr).args[2 : end]
        atup = push!(b, Expr(:call, tuple, args...))
        return Expr(:(=), st.args[1], 
                    Expr(:call, deactivate, callexpr.args[1], atup))
    else
        return st
    end
end

swap!(b, v, st, slotmap) = walk(l -> get(slotmap, l, l), st)
swap!(b, v, st::Core.NewvarNode, slotmap) = st

function transform(mix::LiftContext, src, sig)

    if !(sig[2] <: Function) || 
        sig[2] === Core.IntrinsicFunction
        return src
    end # If target is not a function, just return src.

    # Create Builder and try to get the src from the inner
    # call using the unwrapped Sym arg types.
    b = CodeInfoTools.Builder(src)
    inner = sig[2].instance
    symtypes = sig[3]
    argtypes = Tuple{map(unwrap, sig[3].parameters)...}
    largtypes = length(argtypes.parameters)
    try
        inner = CodeInfoTools.code_info(inner, argtypes)
    catch
        return src
    end

    # If we can't get the inner src, just return the original src.
    # Because we are inside of `activate` -- 
    # this is just applying the function to the splatted syms arg.
    inner === nothing && return src

    # Slots as args.
    slotmap = Dict()
    for (ind, a) in enumerate(inner.slotnames[2 : 1 + largtypes])
        o = push!(b, Expr(:call, Base.getindex, slot(3), ind))
        setindex!(slotmap, o, get_slot(inner, a))
    end

    # Extra slots.
    for (ind, a) in enumerate(inner.slotnames[2 + largtypes : end])
        s = slot!(b, a)
    end

    # Now "inline" the src code from inner into the builder.
    # Make the right corrections to slots, etc.
    for (v, st) in enumerate(inner.code)
        ex = swap!(b, v, st, slotmap)
        setindex!(slotmap, push!(b, ex), var(v))
    end
    return CodeInfoTools.finish(b)
end 

# If `opt` is turned on (= true) inside the `ctx`,
# run `ssa_inlining_pass!` with the rest of the passes.
function optimize!(ctx::LiftContext, b)
    if ctx.opt
        ir = julia_passes!(b)
    else
        ir = get_ir(b)
        ir = compact!(ir)
        ir = getfield_elim_pass!(ir)
        ir = adce_pass!(ir)
        ir = compact!(ir)
    end
    if any(==(Union{}), ir.stmts.type)
        @debug "Inference failed to infer -- found Union{}" ir
    end
    return ir
end

# Interface to emit transformed CodeInfo or a callable.
function lift(fn, tt::Type{T}; 
        clean = false, jit = false, opt = false) where T
    clean && return Mixtape.emit(fn, tt; opt = opt)
    symtypes = Tuple{map(tt.parameters) do p
                         Sym{p, Nothing}
                     end...}
    if !jit
        return Mixtape.emit(activate, 
                            Tuple{typeof(fn), symtypes};
                            ctx = LiftContext(opt),
                            opt = opt)
    else
        entry = Mixtape.jit(activate, 
                            Tuple{typeof(fn), symtypes};
                            ctx = LiftContext(opt))
        return function (symargs...)
            entry(fn, symargs)
        end
    end
end

end # module
