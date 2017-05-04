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

    # @testset "Overwriting overflow" begin
    #     r = RingBuffer(Int, 8, 2; overflow=OVERWRITE)
    #     data = reshape(1:12, 6, 2)
    #     @test write(r, data[1:4, :]) == 4
    #     @test write(r, data) == 6
    #     @test read(r, 4) == [3 9; 4 10; 1 7; 2 8]
    # end
    # @testset "Single-write overwrite overflow" begin
    #     r = RingBuffer(Int, 8, 2; overflow=OVERWRITE)
    #     data = reshape(1:20, 10, 2)
    #     @test write(r, data) == 10
    #     @test read(r, 4) == [3 13; 4 14; 5 15; 6 16]
    # end
    # @testset "truncating overflow" begin
    #     r = RingBuffer(Int, 8, 2; overflow=TRUNCATE)
    #     data = reshape(1:12, 6, 2)
    #     @test write(r, data[1:4, :]) == 4
    #     @test write(r, data) == 4
    #     @test write(r, data) == 0
    #     @test read(r, 5) == [1 7; 2 8; 3 9; 4 10; 1 7]
    # end
    # @testset "truncating underflow" begin
    #     r = RingBuffer(Int, 8, 2; underflow=TRUNCATE)
    #     data = reshape(1:6, 3, 2)
    #     @test write(r, data) == 3
    #     @test read(r, 5) == [1 4; 2 5; 3 6]
    # end
    #
    # @testset "padded underflow" begin
    #     r = RingBuffer(Int, 8, 2; underflow=PAD)
    #     data = reshape(1:6, 3, 2)
    #     @test write(r, data) == 3
    #     @test read(r, 5) == [1 4; 2 5; 3 6; 0 0; 0 0]
    # end
    #
    # @testset "queuing blocking writes" begin
    #     r = RingBuffer(Int, 4, 2)
    #     data = reshape(1:12, 6, 2)
    #     res1 = @async write(r, data)
    #     res2 = @async write(r, data)
    #     res3 = @async write(r, data)
    #     yield()
    #     @test read(r, 5) == [1 7; 2 8; 3 9; 4 10; 5 11]
    #     @test read(r, 13) == [6 12; 1 7; 2 8; 3 9; 4 10;
    #                           5 11; 6 12; 1 7; 2 8; 3 9;
    #                           4 10; 5 11; 6 12]
    #     @test wait(res1) == 6
    #     @test wait(res2) == 6
    #     @test wait(res3) == 6
    # end
    # @testset "queueing blocking reads" begin
    #     r = RingBuffer(Int, 8, 2)
    #     data = reshape(1:12, 6, 2)
    #     res1 = @async read(r, 2)
    #     res2 = @async read(r, 2)
    #     res3 = @async read(r, 2)
    #     yield()
    #     write(r, data)
    #     @test wait(res1) == [1 7; 2 8]
    #     @test wait(res2) == [3 9; 4 10]
    #     @test wait(res3) == [5 11; 6 12]
    # end
end
