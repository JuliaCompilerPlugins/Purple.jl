module Purple

using Mixtape
import Mixtape: CompilationContext, transform, allow, optimize!
using Core.Compiler: compact!, getfield_elim_pass!, adce_pass!
using SymbolicUtils
using SymbolicUtils: Symbolic, term, Sym, similarterm, promote_symtype
using CodeInfoTools
using CodeInfoTools: resolve

unwrap(s::Type{Sym{T, K}}) where {T, K} = T
unwrap(s::Type) = s
wrap(t::Type{T}) where T = Sym{T, Nothing}

function _lift(f::Function, syms::S) where S <: Tuple
    return term(f, syms...)
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
    symtypes = sig[3]
    argtypes = Tuple{map(unwrap, sig[3].parameters)...}
    largtypes = length(argtypes.parameters)
    try
        forward = CodeInfoTools.code_info(forward, argtypes)
    catch
        return src
    end
    forward === nothing && return src
    slotmap = Dict()

    # Slots as args.
    for (ind, a) in enumerate(forward.slotnames[2 : 1 + largtypes])
        o = push!(b, Expr(:call, Base.getindex, slot(3), ind))
        setindex!(slotmap, o, get_slot(forward, a))
    end

    # Extra slots.
    for (ind, a) in enumerate(forward.slotnames[2 + largtypes : end])
        s = slot!(b, a)
    end

    for (v, st) in enumerate(forward.code)
        if st isa Expr
            if st.head == :call
                args = walk(v -> resolve(get(slotmap, v, v)), st).args[2 : end]
                atup = push!(b, Expr(:call, tuple, args...))
                ex = Expr(:call, _lift, st.args[1], atup)
            elseif st.head == :(=)
                callexpr = st.args[2]
                args = walk(v -> resolve(get(slotmap, v, v)), callexpr).args[2 : end]
                atup = push!(b, Expr(:call, tuple, args...))
                ex = Expr(:(=), st.args[1], 
                          Expr(:call, _lift, callexpr.args[1], atup))
            end
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
                            Tuple{typeof(fn), symtypes};
                            ctx = LiftContext(opt),
                            opt = opt)
    else
        entry = Mixtape.jit(_lift, 
                            Tuple{typeof(fn), symtypes};
                            ctx = LiftContext(opt))
        return function (symargs...)
            entry(fn, symargs)
        end
    end
end

export lift

end # module
