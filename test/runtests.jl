using RingBuffers
using TestSetExtensions
using Base.Test

@testset DottedTestSet "RingBuffer Tests" begin
    include("pa_ringbuffer.jl")
    @testset "Can read/write 2D arrays" begin
        writedata = collect(reshape(1:10, 2, 5))
        readdata = collect(reshape(11:20, 2, 5))
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        read!(rb, readdata)
        @test readdata == writedata
    end

    @testset "Can read/write 1D arrays" begin
        writedata = collect(1:10)
        readdata = collect(11:20)
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        read!(rb, readdata)
        @test readdata == writedata
    end

    @testset "throws error writing 2D array of wrong channel count" begin
        writedata = collect(reshape(1:15, 3, 5))
        rb = RingBuffer{Int}(2, 8)
        @test_throws ErrorException write(rb, writedata)
    end

    @testset "throws error reading 2D array of wrong channel count" begin
        writedata = collect(reshape(1:10, 2, 5))
        readdata = collect(reshape(11:25, 3, 5))
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        @test_throws ErrorException read!(rb, readdata)
    end

    @testset "multiple sequential writes work" begin
        writedata = collect(reshape(1:8, 2, 4))
        rb = RingBuffer{Int}(2, 10)
        write(rb, writedata)
        write(rb, writedata)
        readdata = read(rb, 8)
        @test readdata == hcat(writedata, writedata)
    end

    @testset "multiple sequential reads work" begin
        writedata = collect(reshape(1:16, 2, 8))
        rb = RingBuffer{Int}(2, 10)
        write(rb, writedata)
        readdata1 = read(rb, 4)
        readdata2 = read(rb, 4)
        @test hcat(readdata1, readdata2) == writedata
    end

    @testset "overflow blocks writer" begin
        writedata = collect(reshape(1:10, 2, 5))
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        t = @async write(rb, writedata)
        sleep(0.1)
        @test t.state == :runnable
        readdata = read(rb, 8)
        @test wait(t) == 5
        @test t.state == :done
        @test readdata == hcat(writedata, writedata[:, 1:3])
    end

    @testset "underflow blocks reader" begin
        writedata = collect(reshape(1:6, 2, 3))
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        t = @async read(rb, 6)
        sleep(0.1)
        @test t.state == :runnable
        write(rb, writedata)
        @test wait(t) == hcat(writedata, writedata)
        @test t.state == :done
    end

    @testset "closing ringbuf cancels in-progress writes" begin
        writedata = collect(reshape(1:20, 2, 10))
        rb = RingBuffer{Int}(2, 8)
        t1 = @async write(rb, writedata)
        t2 = @async write(rb, writedata)
        sleep(0.1)
        close(rb)
        @test wait(t1) == 8
        @test wait(t2) == 0
    end

    @testset "closing ringbuf cancels in-progress reads" begin
        writedata = collect(reshape(1:6, 2, 3))
        rb = RingBuffer{Int}(2, 8)
        write(rb, writedata)
        t1 = @async read(rb, 5)
        t2 = @async read(rb, 5)
        sleep(0.1)
        close(rb)
        @test wait(t1) == writedata[:, 1:3]
        @test wait(t2) == Array{Int}(2, 0)
    end
end
