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

    @testset "wake up waiters when written to" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        waitcond = Condition()
        @async begin
            wait(buf)
            notify(waitcond)
        end
        yield()
        println("waiting at $(@__FILE__):$(@__LINE__)")
        write(buf, data)
        wait(waitcond)
        # if we get here then the waiter was successfully woken
        println("woke at $(@__FILE__):$(@__LINE__)")
        @test true
        close(buf)
    end

    @testset "wake up waiters when read from" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = zeros(Int32, 10)
        waitcond = Condition()
        write(buf, data)
        @async begin
            wait(buf)
            notify(waitcond)
        end
        yield()
        println("waiting at $(@__FILE__):$(@__LINE__)")
        read!(buf, result)
        wait(waitcond)
        # if we get here then the waiter was successfully woken
        println("woke at $(@__FILE__):$(@__LINE__)")
        @test true
        close(buf)
    end
end
