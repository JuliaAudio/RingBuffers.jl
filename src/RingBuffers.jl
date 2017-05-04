module RingBuffers

export RingBuffer
import Base: read, read!, write, wait, unsafe_convert, notify
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
    end
    # now we're in the front of the queue
    nwritten = 0
    n = PaUtil_WriteRingBuffer(rbuf.pabuf,
                               pointer(data),
                               nframes)
    nwritten += n
    while nwritten < nframes
        wait(rbuf.datanotify)
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
    end
    # now we're in the front of the queue
    nread = 0
    n = PaUtil_ReadRingBuffer(rbuf.pabuf,
                              pointer(data),
                              nframes)
    nread += n
    while nread < nframes
        wait(rbuf.datanotify)
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

"""
    notify(rbuf::RingBuffer)

Notify the ringbuffer that new data might be available, which will wake up
any waiting readers or writers. This is safe to call from a separate thread
context.
"""
notify(rbuf::RingBuffer) = ccall(:uv_async_send, rbuf.datacond.handle)

# set it up so we can pass this directly to `ccall` expecting a PA ringbuffer
unsafe_convert(::Type{Ptr{PaUtilRingBuffer}}, buf::RingBuffer) = unsafe_convert(Ptr{PaUtilRingBuffer}, buf.pabuf)

# """
# This RingBuffer type is backed by a fixed-size buffer. Overflow and underflow
# behavior is configurable separately with the `overflow` and `underflow` keyword
# arguments in the constructor.
#
# BLOCK will cause the task to block rather than lose data in overflow or
# underflow.
#
# TRUNCATE will perform a partial read/write in underflow/overflow conditions
#
# PAD (underflow-only) will pad out the rest of the requested data with zeros if
# there is not enough data in the ringbuffer.
#
# OVERWRITE (overflow-only) will overwrite the oldest data if new data is written
# and the buffer is already full.
#
# The default behavior is BLOCK for both underflow and overflow.
# """
# type RingBuffer{T}
#     buf::Array{T, 2}
#     readidx::UInt
#     navailable::UInt
#     readers::Vector{Condition}
#     writers::Vector{Condition}
#     overflow::OverUnderBehavior
#     underflow::OverUnderBehavior
# end
#
# function RingBuffer(T, size, channels; overflow=BLOCK, underflow=BLOCK)
#     buf = Array(T, nextpow2(size), channels)
#     RingBuffer(buf, UInt(1), UInt(0), Condition[], Condition[], overflow, underflow)
# end
#
# Base.eltype{T}(rb::RingBuffer{T}) = T
# read_space(rb::RingBuffer) = Int(rb.navailable)
# write_space(rb::RingBuffer) = size(rb.buf, 1) - read_space(rb)
# # this works because we know the buffer size is a power of two
# wrapidx{T}(rb::RingBuffer{T}, val::Unsigned) = val & (size(rb.buf, 1) - 1)
#
# """Notify the first waiting writer that there may be space available"""
# function notify_writers(rb::RingBuffer)
#     if length(rb.writers) > 0
#         notify(rb.writers[1])
#     end
# end
#
# """Notify the first waiting reader that there may be data available"""
# function notify_readers(rb::RingBuffer)
#     if length(rb.readers) > 0
#         notify(rb.readers[1])
#     end
# end
#
# """Read at most `n` bytes from the ring buffer, returning the results as a new
# Vector{T}. Underflow behavior is determiend by the ringbuffer settings"""
# function read{T}(rb::RingBuffer{T}, n)
#     if rb.underflow == TRUNCATE
#         readsize = min(n, read_space(rb))
#     else
#         # we'll be padding or blocking till we fill the whole buffer
#         readsize = n
#     end
#     v = Array(T, readsize, size(rb.buf, 2))
#     read!(rb, v)
#
#     v
# end
#
# """Read the ringbuffer contents into the given vector `v`. Returns the number
# of elements actually read"""
# function read!(rb::RingBuffer, data::AbstractArray)
#     if rb.underflow == BLOCK
#         read_block!(rb, data)
#     elseif rb.underflow == TRUNCATE
#         read_trunc!(rb, data)
#     else
#         # rb.undefflow = PAD
#         read_pad!(rb, data)
#     end
# end
#
# """Write the given vector `v` to the buffer `rb`. If there is not enough space
# in the buffer to hold the contents, old data is overwritten by new"""
# function write{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     if rb.overflow == BLOCK
#         write_block(rb, data)
#     elseif rb.overflow == TRUNCATE
#         write_trunc(rb, data)
#     else
#         # rb.overflow == OVERWRITE
#         write_overwrite(rb, data)
#     end
# end
#
# """
# Internal write function that will block until it can complete the entire write.
# """
# function write_block{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     cond = Condition()
#     push!(rb.writers, cond)
#     nwritten = 0
#     try
#         if length(rb.writers) > 1
#             wait(cond)
#         end
#
#         total = size(data, 1)
#         nwritten = _write(rb, data)
#         while nwritten < total
#             wait(cond)
#             nwritten += _write(rb, view(data, (nwritten+1):total, :))
#         end
#     finally
#         # we know we're the first condition because we're awake
#         shift!(rb.writers)
#     end
#     notify_writers(rb)
#
#     nwritten
# end
#
# """
# Internal write function that will perform partial writes in the case there's
# not enough data, and returns the number of frames actually read.
# """
# function write_trunc{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     _write(rb, data)
# end
#
# """
# Internal write function that will overwrite old data in case of overflow.
# """
# function write_overwrite{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     datalen = size(data, 1)
#     buflen = size(rb.buf, 1)
#
#     if datalen >= buflen
#         # we'll actually overwrite the whole buffer, so just reset it and
#         # write the whole thing
#         rb.readidx = 1
#         rb.navailable = 0
#         _write(rb, view(data, datalen-buflen+1:datalen, :))
#     else
#         overflow = max(0, datalen - write_space(rb))
#         # free up the necessary space before writing
#         rb.readidx = wrapidx(rb, rb.readidx + overflow)
#         rb.navailable -= overflow
#         _write(rb, data)
#     end
#
#     datalen
# end
#
# """
# Lowest-level Internal write function that will perform partial writes in the
# case there's not enough space, and returns the number of frames actually written.
# """
# function _write{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     buflen = size(rb.buf, 1)
#     total = min(size(data, 1), write_space(rb))
#
#     writeidx = wrapidx(rb, rb.readidx + read_space(rb))
#
#     if writeidx + total - 1 <= buflen
#         bufend = total+writeidx-1
#         rb.buf[writeidx:bufend, :] = view(data, 1:total, :)
#     else
#         partial = buflen - writeidx + 1
#         rb.buf[writeidx:buflen, :] = view(data, 1:partial, :)
#         bufend = total-partial
#         datastart = partial+1
#         rb.buf[1:bufend, :] = view(data, datastart:total, :)
#     end
#
#     rb.navailable += total
#
#     # notify any readers that might be waiting for this data
#     total > 0 && notify_readers(rb)
#
#     total
# end
#
# """
# Internal read function that will perform partial reads in the case there's
# not enough data, and returns the number of frames actually read.
# """
# function read_trunc!{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     _read!(rb, data)
# end
#
# """
# Internal read function that reads into the given array, and pads out with zeros
# if there isn't enough data in the ring buffer.
# """
# function read_pad!{T}(rb::RingBuffer{T}, data::AbstractArray{T})
#     nread = _read!(rb, data)
#     for ch in 1:size(data, 2)
#         for i in (nread+1):size(data, 1)
#             data[i, ch] = zero(T)
#         end
#     end
#
#     size(data, 1)
# end
#
# """
# Internal read function that reads into the given array, blocking until it can
# complete the read.
# """
# function read_block!(rb::RingBuffer, data::AbstractArray)
#     cond = Condition()
#     push!(rb.readers, cond)
#     nread = 0
#     try
#         if length(rb.readers) > 1
#             wait(cond)
#         end
#
#         total = size(data, 1)
#         nread = _read!(rb, data)
#         while nread < total
#             wait(cond)
#             nread += _read!(rb, view(data, (nread+1):total, :))
#         end
#     finally
#         # we know we're the first condition because we're awake
#         shift!(rb.readers)
#     end
#     # notify anybody waiting in line
#     notify_readers(rb)
#
#     nread
# end
#
# """
# Lowest-level internal read function, which just reads available data into the
# given array, returning the number of frames read.
# """
# function _read!(rb::RingBuffer, data::AbstractArray)
#     buflen = size(rb.buf, 1)
#     total = min(size(data, 1), read_space(rb))
#     if rb.readidx + total - 1 <= buflen
#         bufstart = rb.readidx
#         bufend = rb.readidx+total-1
#         data[1:total, :] = view(rb.buf, bufstart:bufend, :)
#     else
#         partial = buflen - rb.readidx + 1
#         bufstart = rb.readidx
#         data[1:partial, :] = view(rb.buf, bufstart:buflen, :)
#         datastart = partial+1
#         bufend = total-partial
#         data[datastart:total, :] = view(rb.buf, 1:bufend, :)
#     end
#
#     rb.readidx = wrapidx(rb, rb.readidx + total)
#     rb.navailable -= total
#
#     # notify any writers that might be waiting for this space
#     total > 0 && notify_writers(rb)
#
#     total
# end

end # module
