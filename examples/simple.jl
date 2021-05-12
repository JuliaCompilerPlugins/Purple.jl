module Simple

using Purple
using Mixtape
using SymbolicUtils: Sym 
using SymbolicUtils.Code

b(x) = x + 10
function fn(x, y)
    ifelse(x > 5, b(getfield((x + y, ), 1)), 10)
end

src = lift(fn,
           Tuple{Int, Int};
           jit = false,
           opt = false)
display(src)

src = lift(fn,
           Tuple{Int, Int};
           jit = false,
           opt = true)
display(src)

f = lift(fn,
         Tuple{Int, Int};
         jit = true,
         opt = true)
ret = f(fn, (Sym{Int}(:x), Sym{Int}(:y)), (0, 0))
display(ret)

end # module
