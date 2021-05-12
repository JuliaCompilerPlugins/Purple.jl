module Simple

using Purple
using SymbolicUtils: Sym

b(x::Int) = 10 + x
function fn(x::Int, y::Int)
    z = x + y
    return b(z) + 10
end

src = lift(fn,
           Tuple{Int, Int};
           jit = false,
           opt = false)
display(src)

f = lift(fn,
         Tuple{Int, Int};
         jit = true,
         opt = false)
ret = f(Sym{Int}(:x), Sym{Int}(:y))
display(ret)

end # module

