export
    OperatorConv,
    OperatorKernel

struct OperatorConv{P, N, T, S}
    weight::T
    in_channel::S
    out_channel::S
    modes::NTuple{N, S}
end

function OperatorConv{P}(
    weight::T,
    in_channel::S,
    out_channel::S,
    modes::NTuple{N, S},
) where {P, N, T, S}
    return OperatorConv{P, N, T, S}(weight, in_channel, out_channel, modes)
end

"""
    OperatorConv(
        ch, modes;
        init=c_glorot_uniform, permuted=false, T=ComplexF32
    )

## Arguments

* `ch`: Input and output channel size, e.g. `64=>64`.
* `modes`: The Fourier modes to be preserved.
* `permuted`: Whether the dim is permuted. If `permuted=true`, layer accepts
    data in the order of `(ch, ..., batch)`, otherwise the order is `(..., ch, batch)`.

## Example

```jldoctest
julia> OperatorConv(2=>5, (16, ))
OperatorConv(2 => 5, (16,), permuted=false)

julia> OperatorConv(2=>5, (16, ), permuted=true)
OperatorConv(2 => 5, (16,), permuted=true)
```
"""
function OperatorConv(
    ch::Pair{S, S},
    modes::NTuple{N, S};
    init=c_glorot_uniform,
    permuted=false,
    T::DataType=ComplexF32
) where {S<:Integer, N}
    in_chs, out_chs = ch
    scale = one(T) / (in_chs * out_chs)
    weights = scale * init(prod(modes), in_chs, out_chs)

    return OperatorConv{permuted}(weights, in_chs, out_chs, modes)
end

Flux.@functor OperatorConv{true}
Flux.@functor OperatorConv{false}

Base.ndims(::OperatorConv{P, N}) where {P, N} = N

ispermuted(::OperatorConv{P}) where {P} = P

function Base.show(io::IO, l::OperatorConv{P}) where {P}
    print(io, "OperatorConv($(l.in_channel) => $(l.out_channel), $(l.modes), permuted=$P)")
end

function spectral_conv(m::OperatorConv, 𝐱::AbstractArray)
    n_dims = ndims(𝐱)

    𝐱_fft = fft(Zygote.hook(real, 𝐱), 1:ndims(m)) # [x, in_chs, batch]
    𝐱_flattened = reshape(view(𝐱_fft, map(d->1:d, m.modes)..., :, :), :, size(𝐱_fft, n_dims-1), size(𝐱_fft, n_dims))
    𝐱_weighted = apply_spectral_pattern(𝐱_flattened, m.weight) # [prod(m.modes), out_chs, batch], only 3-dims
    𝐱_shaped = reshape(𝐱_weighted, m.modes..., size(𝐱_weighted, 2), size(𝐱_weighted, 3))
    𝐱_padded = spectral_pad(𝐱_shaped, (size(𝐱_fft)[1:end-2]..., size(𝐱_weighted, 2), size(𝐱_weighted, 3))) # [x, out_chs, batch] <- [modes, out_chs, batch]
    𝐱_ifft = real(ifft(𝐱_padded, 1:ndims(m))) # [x, out_chs, batch]

    return 𝐱_ifft
end

function (m::OperatorConv{false})(𝐱)
    𝐱ᵀ = permutedims(𝐱, (ntuple(i->i+1, ndims(m))..., 1, ndims(m)+2)) # [x, in_chs, batch] <- [in_chs, x, batch]
    𝐱_out = spectral_conv(m, 𝐱ᵀ) # [x, out_chs, batch]
    𝐱_outᵀ = permutedims(𝐱_out, (ndims(m)+1, 1:ndims(m)..., ndims(m)+2)) # [out_chs, x, batch] <- [x, out_chs, batch]

    return 𝐱_outᵀ
end

function (m::OperatorConv{true})(𝐱)
    return spectral_conv(m, 𝐱) # [x, out_chs, batch]
end

############
# operator #
############

struct OperatorKernel{L, C, F}
    linear::L
    conv::C
    σ::F
end

"""
    OperatorKernel(ch, modes, σ=identity; permuted=false)

## Arguments

* `ch`: Input and output channel size for spectral convolution, e.g. `64=>64`.
* `modes`: The Fourier modes to be preserved for spectral convolution.
* `σ`: Activation function.
* `permuted`: Whether the dim is permuted. If `permuted=true`, layer accepts
    data in the order of `(ch, ..., batch)`, otherwise the order is `(..., ch, batch)`.

## Example

```jldoctest
julia> OperatorKernel(2=>5, (16, ))
OperatorKernel(2 => 5, (16,), σ=identity, permuted=false)

julia> using Flux

julia> OperatorKernel(2=>5, (16, ), relu)
OperatorKernel(2 => 5, (16,), σ=relu, permuted=false)

julia> OperatorKernel(2=>5, (16, ), relu, permuted=true)
OperatorKernel(2 => 5, (16,), σ=relu, permuted=true)
```
"""
function OperatorKernel(
    ch::Pair{S, S},
    modes::NTuple{N, S},
    σ=identity;
    permuted=false
) where {S<:Integer, N}
    linear = permuted ? Conv(Tuple(ones(Int, length(modes))), ch) : Dense(ch.first, ch.second)
    conv = OperatorConv(ch, modes; permuted=permuted)

    return OperatorKernel(linear, conv, σ)
end

Flux.@functor OperatorKernel

function Base.show(io::IO, l::OperatorKernel)
    print(
        io,
        "OperatorKernel(" *
            "$(l.conv.in_channel) => $(l.conv.out_channel), " *
            "$(l.conv.modes), " *
            "σ=$(string(l.σ)), " *
            "permuted=$(ispermuted(l.conv))" *
        ")"
    )
end

function (m::OperatorKernel)(𝐱)
    return m.σ.(m.linear(𝐱) + m.conv(𝐱))
end

const SpectralConv = OperatorConv


#########
# utils #
#########

c_glorot_uniform(dims...) = Flux.glorot_uniform(dims...) + Flux.glorot_uniform(dims...)*im

# [prod(modes), out_chs, batch] <- [prod(modes), in_chs, batch] * [out_chs, in_chs, prod(modes)]
apply_spectral_pattern(𝐱₁, 𝐱₂) = @tullio 𝐲[m, o, b] := 𝐱₁[m, i, b] * 𝐱₂[m, i, o]

spectral_pad(𝐱::AbstractArray, dims::NTuple) = spectral_pad!(similar(𝐱, dims), 𝐱)

function spectral_pad!(𝐱_padded::AbstractArray, 𝐱::AbstractArray)
    fill!(𝐱_padded, eltype(𝐱)(0)) # zeros(eltype(𝐱), dims)
    𝐱_padded[map(d->1:d, size(𝐱))...] .= 𝐱

    return 𝐱_padded
end

function ChainRulesCore.rrule(::typeof(spectral_pad), 𝐱::AbstractArray, dims::NTuple)
    function spectral_pad_pullback(𝐲̄)
        return NoTangent(), view(𝐲̄, map(d->1:d, size(𝐱))...), NoTangent()
    end

    return spectral_pad(𝐱, dims), spectral_pad_pullback
end
