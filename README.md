# RingBuffers

[![Build Status](https://travis-ci.org/JuliaAudio/RingBuffers.jl.svg?branch=master)](https://travis-ci.org/JuliaAudio/RingBuffers.jl)
[![codecov.io](https://codecov.io/github/JuliaAudio/RingBuffers.jl/coverage.svg?branch=master)](https://codecov.io/github/JuliaAudio/RingBuffers.jl?branch=master)

This package provides the `RingBuffer` type, which is a circular, fixed-size buffer. It is mostly intended to use to pass samples between separate Julia Tasks.

This package implements `read`, `read!`, and `write` methods on the `RingBuffer` type, and supports reading and writing any MxN `AbstractArray` subtypes, where N is the channel count and M is the length in frames.

See the tests for more details on usage.

## Overflow and Underflow

Overflow and underflow behavior is configurable separately with the `overflow` and `underflow` keyword arguments in the constructor.

`BLOCK` will cause the task to block rather than lose data in overflow or underflow.

`TRUNCATE` will perform a partial read/write in underflow/overflow conditions

`PAD` (underflow-only) will pad out the rest of the requested data with zeros if there is not enough data in the ringbuffer.

`OVERWRITE` (overflow-only) will overwrite the oldest data if new data is written and the buffer is already full.

The default behavior is `BLOCK` for both underflow and overflow.
