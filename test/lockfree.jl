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
        startcond = Condition()
        endcond = Condition()
        data = rand(Int32, 10)
        woke = false
        @schedule begin
            notify(startcond)
            wait(buf)
            woke = true
            notify(endcond)
        end
        wait(startcond)
        @test !woke
        write(buf, data)
        wait(endcond)
        # if we get here then the waiter was successfully woken
        @test woke
        close(buf)
    end

    @testset "wake up waiters when read from" begin
        buf = LockFreeRingBuffer(Int32, 16)
        startcond = Condition()
        endcond = Condition()
        data = rand(Int32, 10)
        result = zeros(Int32, 10)
        write(buf, data)
        wait(buf) # we need to make sure that the internal AsyncConditino gets triggered
        woke = false
        @schedule begin
            notify(startcond)
            wait(buf)
            woke = true
            notify(endcond)
        end
        wait(startcond)
        @test !woke
        read!(buf, result)
        wait(endcond)
        # if we get here then the waiter was successfully woken
        @test woke
        close(buf)
    end

    @testset "supports nreadable and nwritable" begin
        buf = LockFreeRingBuffer(Int32, 16)
        data = rand(Int32, 10)
        result = rand(Int32, 5)
        @test nreadable(buf) == 0
        @test nwritable(buf) == 16
        write(buf, data)
        @test nreadable(buf) == 10
        @test nwritable(buf) == 6
        read!(buf, result)
        @test nreadable(buf) == 5
        @test nwritable(buf) == 11
        close(buf)
    end
end
