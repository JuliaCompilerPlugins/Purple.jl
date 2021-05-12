module Purple

using Mixtape
import Mixtape: CompilationContext, transform, allow, optimize!
using Core.Compiler: compact!, 
                     getfield_elim_pass!, 
                     adce_pass!
using SymbolicUtils
using SymbolicUtils: Symbolic, Term, Sym
using CodeInfoTools
using CodeInfoTools: resolve

function _lift(f::Function, syms::S, args::K) where {S <: Tuple, K <: Tuple}
    return Term(f, Any[syms...])
end

struct LiftContext <: CompilationContext end
allow(ctx::LiftContext, mod::Module, fn::typeof(_lift), args...) = true

function transform(mix::LiftContext, src, sig)
    if !(sig[2] <: Function) || 
        sig[2] === Core.IntrinsicFunction
        return src
    end # If target is not a function, just return src.

    b = CodeInfoTools.Builder(src)
    forward = sig[2].instance
    argtypes = sig[4 : end]
    try
        forward = CodeInfoTools.code_info(forward, argtypes...)
    catch
        return src
    end
    forward === nothing && return src
    slotmap = Dict()
    symbolicmap = Dict()
    for (ind, a) in enumerate(forward.slotnames[2 : end])
        o = push!(b, Expr(:call, Base.getindex, slot(4), ind))
        setindex!(slotmap, o, get_slot(forward, a))
        v = push!(b, Expr(:call, Base.getindex, slot(3), ind))
        setindex!(symbolicmap, v, o)
    end
    for (v, st) in enumerate(forward.code)
        if st isa Expr &&
            st.head == :call
            args = walk(v -> resolve(get(slotmap, v, v)), st).args[2 : end]
            symbolicargs = map(v -> get(symbolicmap, v, v), args)
            ttup = push!(b, Expr(:call, tuple, symbolicargs...))
            atup = push!(b, Expr(:call, tuple, args...))
            ex = Expr(:call, _lift, st.args[1], ttup, atup)
        else
            ex = walk(v -> get(slotmap, v, v), st)
        end
        setindex!(slotmap, push!(b, ex), var(v))
    end
    return CodeInfoTools.finish(b)
end 

function optimize!(ctx::LiftContext, b)
    ir = get_ir(b)
    ir = compact!(ir)
    ir = getfield_elim_pass!(ir)
    ir = adce_pass!(ir)
    ir = compact!(ir)
    return ir
end

function lift(fn, tt::Type{T}; 
        jit = false, opt = false) where T
    symtypes = Tuple{map(tt.parameters) do p
                         Sym{p, Nothing}
                     end...}
    if !jit
        return Mixtape.emit(_lift, 
                            Tuple{typeof(fn), symtypes, T};
                            ctx = LiftContext(), opt = opt)
    else
        return Mixtape.jit(_lift, 
                           Tuple{typeof(fn), symtypes, T};
                           ctx = LiftContext())
    end
end

export lift

end # module
