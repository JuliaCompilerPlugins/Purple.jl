module Simple

using Purple
using SymbolicUtils: Sym

# Works with method representations of control flow.
b(x) = x + 10
function fn(x, y)
    ifelse(x > 5, b(x + y), 10)
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

# Because we use a version of "sneaky invoke" but can't modify the signature
# we have to pass in a set of "blank" args of the original type (here, (0, 0))
# because our semantic stub function _lift has signature _lift(fn, syms::Tuple, args::Tuple) to piggyback off type inference for signature Tuple{typeof(fn), map(typeof, args)...}.
# To understand this a bit better, see `lift`.
ret = f(Sym{Int}(:x), Sym{Int}(:y))
display(typeof(ret))
display(ret)

end # module
