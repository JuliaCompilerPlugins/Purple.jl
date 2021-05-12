module Functional

using Purple

function fn(x::Int)
    y = [ 0.0, 0.0, 0.0]
    return map(e -> x + e^2, y)
end

src = lift(fn,
           Tuple{Int};
           clean = true,
           jit = false,
           opt = false)
display(src)

src = lift(fn,
           Tuple{Int};
           jit = false,
           opt = false)
display(src)

end # module
