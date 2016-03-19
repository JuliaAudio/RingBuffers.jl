using RingBuffers
if VERSION >= v"0.5.0-"
    using Base.Test
else
    using BaseTestNext
end

@testset "RingBuffer Tests" begin
    @testset "Construction" begin
        r = RingBuffer(Float64, 8, 1)
        @test eltype(r) == Float64
        @test RingBuffers.read_space(r) == 0
        @test RingBuffers.write_space(r) == 8
    end
    @testset "Basic read/write" begin
        r = RingBuffer(Int, 8, 2)
        data = reshape(1:12, 6, 2)
        write(r, data[1:4, :])
        @test read(r, 4) == data[1:4, :]
        write(r, data)
        @test read(r, 6) == data
    end
    @testset "Overwriting overflow" begin
        r = RingBuffer(Int, 8, 2; overflow=OVERWRITE)
        data = reshape(1:12, 6, 2)
        @test write(r, data[1:4, :]) == 4
        @test write(r, data) == 6
        @test read(r, 4) == [3 9; 4 10; 1 7; 2 8]
    end
    @testset "Single-write overwrite overflow" begin
        r = RingBuffer(Int, 8, 2; overflow=OVERWRITE)
        data = reshape(1:20, 10, 2)
        @test write(r, data) == 10
        @test read(r, 4) == [3 13; 4 14; 5 15; 6 16]
    end
    @testset "truncating overflow" begin
        r = RingBuffer(Int, 8, 2; overflow=TRUNCATE)
        data = reshape(1:12, 6, 2)
        @test write(r, data[1:4, :]) == 4
        @test write(r, data) == 4
        @test write(r, data) == 0
        @test read(r, 5) == [1 7; 2 8; 3 9; 4 10; 1 7]
    end
    @testset "truncating underflow" begin
        r = RingBuffer(Int, 8, 2; underflow=TRUNCATE)
        data = reshape(1:6, 3, 2)
        @test write(r, data) == 3
        @test read(r, 5) == [1 4; 2 5; 3 6]
    end

    @testset "padded underflow" begin
        r = RingBuffer(Int, 8, 2; underflow=PAD)
        data = reshape(1:6, 3, 2)
        @test write(r, data) == 3
        @test read(r, 5) == [1 4; 2 5; 3 6; 0 0; 0 0]
    end

    @testset "queuing blocking writes" begin
        r = RingBuffer(Int, 4, 2)
        data = reshape(1:12, 6, 2)
        res1 = @async write(r, data)
        res2 = @async write(r, data)
        res3 = @async write(r, data)
        yield()
        @test read(r, 5) == [1 7; 2 8; 3 9; 4 10; 5 11]
        @test read(r, 13) == [6 12; 1 7; 2 8; 3 9; 4 10;
                              5 11; 6 12; 1 7; 2 8; 3 9;
                              4 10; 5 11; 6 12]
        @test wait(res1) == 6
        @test wait(res2) == 6
        @test wait(res3) == 6
    end
    @testset "queueing blocking reads" begin
        r = RingBuffer(Int, 8, 2)
        data = reshape(1:12, 6, 2)
        res1 = @async read(r, 2)
        res2 = @async read(r, 2)
        res3 = @async read(r, 2)
        yield()
        write(r, data)
        @test wait(res1) == [1 7; 2 8]
        @test wait(res2) == [3 9; 4 10]
        @test wait(res3) == [5 11; 6 12]
    end
end
