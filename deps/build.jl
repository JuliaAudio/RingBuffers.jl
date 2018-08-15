using BinaryProvider
using Compat

depsdir(args...) = joinpath(@__DIR__, args...)

product = LibraryProduct(depsdir("usr", "lib"), "pa_ringbuffer", :libpa_ringbuffer)
if satisfied(product; verbose=true)
    write_deps_file(depsdir("deps.jl"), [product])
else
    throw(ErrorException("Failed to satisfy pa_ringbuffer library dependency"))
end
