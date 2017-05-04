module RingBuffers

export RingBuffer
import Base: read, read!, write, wait, unsafe_convert, notify, isopen, close
using Base: AsyncCondition

include("pa_ringbuffer.jl")

"""
    RingBuffer{T}(nchannels, nframes)

A lock-free ringbuffer wrapping PortAudio's implementation. The underlying
representation stores multi-channel data as interleaved. The buffer will hold
`nframes` frames.
"""
struct RingBuffer{T}
    pabuf::PaUtilRingBuffer
    nchannels::Int
    readers::Vector{Condition}
    writers::Vector{Condition}
    datanotify::AsyncCondition

    function RingBuffer{T}(nchannels, frames) where {T}
        frames = nextpow2(frames)
        buf = PaUtilRingBuffer(sizeof(T) * nchannels, frames)
        new(buf, nchannels, Condition[], Condition[], AsyncCondition())
    end
end

function frameswritable(rbuf::RingBuffer{T}) where {T}
    PaUtil_GetRingBufferWriteAvailable(rbuf)
end

"""
    write(rbuf::RingBuffer{T}, data::AbstractArray{T}[, nframes])

Write `nframes` frames to `rbuf` from `data`. Assumes the data is interleaved.
If the buffer is full the call will block until space is available or the ring
buffer is closed.

Returns the number of frames written, which should be equal to the requested
number unless the buffer was closed prematurely.
"""
function write(rbuf::RingBuffer{T}, data::AbstractArray{T}, nframes) where {T}
    if length(data) < nframes * rbuf.nchannels
        dframes = (div(length(data), rbuf.nchannels))
        throw(ErrorException("data array is too short ($dframes frames) for requested write ($nframes frames)"))
    end

    cond = Condition()
    push!(rbuf.writers, cond)
    if length(rbuf.writers) > 1
        # we're behind someone in the queue
        wait(cond)
        isopen(rbuf) || return 0
    end
    # now we're in the front of the queue
    nwritten = 0
    n = PaUtil_WriteRingBuffer(rbuf.pabuf,
                               pointer(data),
                               nframes)
    nwritten += n
    while nwritten < nframes
        wait(rbuf.datanotify)
        isopen(rbuf) || return nwritten
        n = PaUtil_WriteRingBuffer(rbuf.pabuf,
                                   pointer(data)+(nwritten*rbuf.nchannels*sizeof(T)),
                                   nframes-nwritten)
        nwritten += n
    end

    # notify any waiting readers that there's data available
    notify(rbuf.datanotify.cond)
    # we're done, remove our condition and notify the next writer if necessary
    shift!(rbuf.writers)
    if length(rbuf.writers) > 0
       notify(rbuf.writers[1])
    end

    nwritten
end

function write(rbuf::RingBuffer{T}, data::AbstractMatrix{T}) where {T}
    if size(data, 1) != rbuf.nchannels
        throw(ErrorException(
            "Tried to write a $(size(data, 1))-channel array to a $(rbuf.nchannels)-channel ring buffer"))
    end
    write(rbuf, data, size(data, 2))
end

function write(rbuf::RingBuffer{T}, data::AbstractVector{T}) where {T}
    write(rbuf, data, div(length(data), rbuf.nchannels))
end

function framesreadable(rbuf::RingBuffer{T}) where {T}
    PaUtil_GetRingBufferReadAvailable(rbuf)
end

"""
    read!(rbuf::RingBuffer, data::AbstractArray[, nframes])

Read `nframes` frames from `rbuf` into `data`. Data will be interleaved.
If the buffer is empty the call will block until data is available or the ring
buffer is closed. If `data` is a `Vector`, it's treated as a block of memory
in which to write the interleaved data. If it's a `Matrix`, it is treated as
nchannels × nframes.

Returns the number of frames read, which should be equal to the requested
number unless the buffer was closed prematurely.
"""
function read!(rbuf::RingBuffer{T}, data::AbstractArray{T}, nframes) where {T}
    if length(data) < nframes * rbuf.nchannels
        dframes = (div(length(data), rbuf.nchannels))
        throw(ErrorException("data array is too short ($dframes frames) for requested read ($nframes frames)"))
    end

    cond = Condition()
    push!(rbuf.readers, cond)
    if length(rbuf.readers) > 1
        # we're behind someone in the queue
        wait(cond)
        isopen(rbuf) || return 0
    end
    # now we're in the front of the queue
    nread = 0
    n = PaUtil_ReadRingBuffer(rbuf.pabuf,
                              pointer(data),
                              nframes)
    nread += n
    while nread < nframes
        wait(rbuf.datanotify)
        isopen(rbuf) || return nread
        n = PaUtil_ReadRingBuffer(rbuf.pabuf,
                                  pointer(data)+(nread*rbuf.nchannels*sizeof(T)),
                                  nframes-nread)
        nread += n
    end

    # notify any waiting writers that there's space available
    notify(rbuf.datanotify.cond)
    # we're done, remove our condition and notify the next reader if necessary
    shift!(rbuf.readers)
    if length(rbuf.readers) > 0
       notify(rbuf.readers[1])
    end

    nread
end

function read!(rbuf::RingBuffer{T}, data::AbstractMatrix{T}) where {T}
    if size(data, 1) != rbuf.nchannels
        throw(ErrorException(
            "Tried to write a $(size(data, 1))-channel array to a $(rbuf.nchannels)-channel ring buffer"))
    end
    read!(rbuf, data, size(data, 2))
end

function read!(rbuf::RingBuffer{T}, data::AbstractVector{T}) where {T}
    read!(rbuf, data, div(length(data), rbuf.nchannels))
end


"""
    read(rbuf::RingBuffer, nframes)

Read `nframes` frames from `rbuf` and return an (nchannels × nframes) `Array`
holding the interleaved data. If the buffer is empty the call will block until
data is available or the ring buffer is closed.
"""
function read(rbuf::RingBuffer{T}, nframes) where {T}
    data = Array{T}(rbuf.nchannels, nframes)
    nread = read!(rbuf, data, nframes)

    if nread < nframes
        data[:, 1:nread]
    else
        data
    end
end

function close(rbuf::RingBuffer)
    close(rbuf.pabuf)
    # wake up any waiting readers or writers
    notify(rbuf.datanotify.cond)
    for condlist in (rbuf.readers, rbuf.writers)
        while length(condlist) > 0
            cond = pop!(condlist)
            notify(cond)
        end
    end
end

isopen(rbuf::RingBuffer) = isopen(rbuf.pabuf)

"""
    notify(rbuf::RingBuffer)

Notify the ringbuffer that new data might be available, which will wake up
any waiting readers or writers. This is safe to call from a separate thread
context.
"""
notify(rbuf::RingBuffer) = ccall(:uv_async_send, rbuf.datacond.handle)

# set it up so we can pass this directly to `ccall` expecting a PA ringbuffer
unsafe_convert(::Type{Ptr{PaUtilRingBuffer}}, buf::RingBuffer) = unsafe_convert(Ptr{PaUtilRingBuffer}, buf.pabuf)

end # module
