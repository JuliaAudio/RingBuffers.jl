@testset "LockFreeRingBuffer Tests" begin
    @testset "basic read/write" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = zeros(Int32, 10)
        @test write(buf, data) == 10
        @test read!(buf, result) == 10
        @test result == data
        close(buf)
    end

    @testset "read/write that wraps the ringbuf" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = zeros(Int32, 10)
        write(buf, data)
        read!(buf, result)
        data = rand(Int32, 10)
        @test write(buf, data) == 10
        @test read!(buf, result) == 10
        @test result == data
        close(buf)
    end

    @testset "overflow" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 20)
        result = zeros(Int32, 16)
        @test write(buf, data) == 16
        @test read!(buf, result) == 16
        @test result == data[1:16]
        close(buf)
    end

    @testset "underflow" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = zeros(Int32, 16)
        @test write(buf, data) == 10
        @test read!(buf, result) == 10
        @test result[1:10] == data
        close(buf)
    end

    @testset "writing raw array doesn't allocate" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        dataptr = pointer(data)
        # call once to trigger compilation
        write(buf, dataptr, length(data))
        alloc = @allocated write(buf, dataptr, length(data))
        @test alloc == 0
        close(buf)
    end

    @testset "reading raw array doesn't allocate" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = zeros(Int32, 10)
        resultptr = pointer(result)
        # call once to trigger compilation
        write(buf, data)
        read!(buf, resultptr, length(result))
        write(buf, data)
        alloc = @allocated read!(buf, resultptr, length(result))
        @test alloc == 0
        close(buf)
    end
end
