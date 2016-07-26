@testset "LockFreeRingBuffer Tests" begin
    buf = LockFreeRingBuffer(Int32, 16)

    N = 10
    data = rand(Int32, N)
    result = zeros(Int32, N)
    @test write(buf, data) == N
    @test read!(buf, result) == N
    @test result == data
    close(buf)
end
