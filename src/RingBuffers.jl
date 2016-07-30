module RingBuffers

using Compat
import Compat.ASCIIString
import Compat: view, AsyncCondition

export RingBuffer, BLOCK, TRUNCATE, PAD, OVERWRITE
export LockFreeRingBuffer, nreadable, nwritable, wakewaiters

import Base: read, read!, write, wait

@enum OverUnderBehavior BLOCK TRUNCATE PAD OVERWRITE

include("lockfree.jl")

"""
This RingBuffer type is backed by a fixed-size buffer. Overflow and underflow
behavior is configurable separately with the `overflow` and `underflow` keyword
arguments in the constructor.

BLOCK will cause the task to block rather than lose data in overflow or
underflow.

TRUNCATE will perform a partial read/write in underflow/overflow conditions

PAD (underflow-only) will pad out the rest of the requested data with zeros if
there is not enough data in the ringbuffer.

OVERWRITE (overflow-only) will overwrite the oldest data if new data is written
and the buffer is already full.

The default behavior is BLOCK for both underflow and overflow.
"""
type RingBuffer{T}
    buf::Array{T, 2}
    readidx::UInt
    navailable::UInt
    readers::Vector{Condition}
    writers::Vector{Condition}
    overflow::OverUnderBehavior
    underflow::OverUnderBehavior
end

function RingBuffer(T, size, channels; overflow=BLOCK, underflow=BLOCK)
    buf = Array(T, nextpow2(size), channels)
    RingBuffer(buf, UInt(1), UInt(0), Condition[], Condition[], overflow, underflow)
end

Base.eltype{T}(rb::RingBuffer{T}) = T
read_space(rb::RingBuffer) = Int(rb.navailable)
write_space(rb::RingBuffer) = size(rb.buf, 1) - read_space(rb)
# this works because we know the buffer size is a power of two
wrapidx{T}(rb::RingBuffer{T}, val::Unsigned) = val & (size(rb.buf, 1) - 1)

"""Notify the first waiting writer that there may be space available"""
function notify_writers(rb::RingBuffer)
    if length(rb.writers) > 0
        notify(rb.writers[1])
    end
end

"""Notify the first waiting reader that there may be data available"""
function notify_readers(rb::RingBuffer)
    if length(rb.readers) > 0
        notify(rb.readers[1])
    end
end

"""Read at most `n` bytes from the ring buffer, returning the results as a new
Vector{T}. Underflow behavior is determiend by the ringbuffer settings"""
function read{T}(rb::RingBuffer{T}, n)
    if rb.underflow == TRUNCATE
        readsize = min(n, read_space(rb))
    else
        # we'll be padding or blocking till we fill the whole buffer
        readsize = n
    end
    v = Array(T, readsize, size(rb.buf, 2))
    read!(rb, v)

    v
end

"""Read the ringbuffer contents into the given vector `v`. Returns the number
of elements actually read"""
function read!(rb::RingBuffer, data::AbstractArray)
    if rb.underflow == BLOCK
        read_block!(rb, data)
    elseif rb.underflow == TRUNCATE
        read_trunc!(rb, data)
    else
        # rb.undefflow = PAD
        read_pad!(rb, data)
    end
end

"""Write the given vector `v` to the buffer `rb`. If there is not enough space
in the buffer to hold the contents, old data is overwritten by new"""
function write{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    if rb.overflow == BLOCK
        write_block(rb, data)
    elseif rb.overflow == TRUNCATE
        write_trunc(rb, data)
    else
        # rb.overflow == OVERWRITE
        write_overwrite(rb, data)
    end
end

"""
Internal write function that will block until it can complete the entire write.
"""
function write_block{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    cond = Condition()
    push!(rb.writers, cond)
    nwritten = 0
    try
        if length(rb.writers) > 1
            wait(cond)
        end

        total = size(data, 1)
        nwritten = _write(rb, data)
        while nwritten < total
            wait(cond)
            nwritten += _write(rb, view(data, (nwritten+1):total, :))
        end
    finally
        # we know we're the first condition because we're awake
        shift!(rb.writers)
    end
    notify_writers(rb)

    nwritten
end

"""
Internal write function that will perform partial writes in the case there's
not enough data, and returns the number of frames actually read.
"""
function write_trunc{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    _write(rb, data)
end

"""
Internal write function that will overwrite old data in case of overflow.
"""
function write_overwrite{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    datalen = size(data, 1)
    buflen = size(rb.buf, 1)

    if datalen >= buflen
        # we'll actually overwrite the whole buffer, so just reset it and
        # write the whole thing
        rb.readidx = 1
        rb.navailable = 0
        _write(rb, view(data, datalen-buflen+1:datalen, :))
    else
        overflow = max(0, datalen - write_space(rb))
        # free up the necessary space before writing
        rb.readidx = wrapidx(rb, rb.readidx + overflow)
        rb.navailable -= overflow
        _write(rb, data)
    end

    datalen
end

"""
Lowest-level Internal write function that will perform partial writes in the
case there's not enough space, and returns the number of frames actually written.
"""
function _write{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    buflen = size(rb.buf, 1)
    total = min(size(data, 1), write_space(rb))

    writeidx = wrapidx(rb, rb.readidx + read_space(rb))

    if writeidx + total - 1 <= buflen
        bufend = total+writeidx-1
        rb.buf[writeidx:bufend, :] = view(data, 1:total, :)
    else
        partial = buflen - writeidx + 1
        rb.buf[writeidx:buflen, :] = view(data, 1:partial, :)
        bufend = total-partial
        datastart = partial+1
        rb.buf[1:bufend, :] = view(data, datastart:total, :)
    end

    rb.navailable += total

    # notify any readers that might be waiting for this data
    total > 0 && notify_readers(rb)

    total
end

"""
Internal read function that will perform partial reads in the case there's
not enough data, and returns the number of frames actually read.
"""
function read_trunc!{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    _read!(rb, data)
end

"""
Internal read function that reads into the given array, and pads out with zeros
if there isn't enough data in the ring buffer.
"""
function read_pad!{T}(rb::RingBuffer{T}, data::AbstractArray{T})
    nread = _read!(rb, data)
    for ch in 1:size(data, 2)
        for i in (nread+1):size(data, 1)
            data[i, ch] = zero(T)
        end
    end

    size(data, 1)
end

"""
Internal read function that reads into the given array, blocking until it can
complete the read.
"""
function read_block!(rb::RingBuffer, data::AbstractArray)
    cond = Condition()
    push!(rb.readers, cond)
    nread = 0
    try
        if length(rb.readers) > 1
            wait(cond)
        end

        total = size(data, 1)
        nread = _read!(rb, data)
        while nread < total
            wait(cond)
            nread += _read!(rb, view(data, (nread+1):total, :))
        end
    finally
        # we know we're the first condition because we're awake
        shift!(rb.readers)
    end
    # notify anybody waiting in line
    notify_readers(rb)

    nread
end

"""
Lowest-level internal read function, which just reads available data into the
given array, returning the number of frames read.
"""
function _read!(rb::RingBuffer, data::AbstractArray)
    buflen = size(rb.buf, 1)
    total = min(size(data, 1), read_space(rb))
    if rb.readidx + total - 1 <= buflen
        bufstart = rb.readidx
        bufend = rb.readidx+total-1
        data[1:total, :] = view(rb.buf, bufstart:bufend, :)
    else
        partial = buflen - rb.readidx + 1
        bufstart = rb.readidx
        data[1:partial, :] = view(rb.buf, bufstart:buflen, :)
        datastart = partial+1
        bufend = total-partial
        data[datastart:total, :] = view(rb.buf, 1:bufend, :)
    end

    rb.readidx = wrapidx(rb, rb.readidx + total)
    rb.navailable -= total

    # notify any writers that might be waiting for this space
    total > 0 && notify_writers(rb)

    total
end

end # module
