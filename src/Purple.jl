module Purple

using Mixtape
import Mixtape: CompilationContext, transform, allow, optimize!
using Core.Compiler: compact!, getfield_elim_pass!, adce_pass!
using SymbolicUtils
using SymbolicUtils: Symbolic, term, Sym, similarterm, promote_symtype
using CodeInfoTools
using CodeInfoTools: resolve

blank(t::Type{Int}) = 0
blank(t::Type{Float64}) = 0.0

function _lift(f::Function, syms::S, args::K) where {S <: Tuple, K <: Tuple}
    t = term(f, syms...)
    return t
end

struct LiftContext <: CompilationContext
    opt::Bool
end
allow(ctx::LiftContext, mod::Module, fn::typeof(_lift), inner, args...) = true
allow(ctx::LiftContext, mod::Module, fn::typeof(_lift), inner::typeof(SymbolicUtils.add_t), args...) = false
allow(ctx::LiftContext, mod::Module, fn::typeof(_lift), inner::typeof(SymbolicUtils.makeadd), args...) = false

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
    if ctx.opt
        ir = julia_passes!(b)
    else
        ir = get_ir(b)
        ir = compact!(ir)
        ir = getfield_elim_pass!(ir)
        ir = adce_pass!(ir)
        ir = compact!(ir)
    end
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
                            ctx = LiftContext(opt),
                            opt = opt)
    else
        entry = Mixtape.jit(_lift, 
                            Tuple{typeof(fn), symtypes, T};
                            ctx = LiftContext(opt))
        blanks = Tuple(map(blank, tt.parameters))
        return function (symargs...)
            entry(fn, symargs, blanks)
        end
    end
end

export lift

end # module
