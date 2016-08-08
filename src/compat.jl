# we define our own compatibilty layer here until Compat.jl#261 is merged
if isdefined(Base, :AsyncCondition)
    import Base.AsyncCondition
else
    type AsyncCondition
        cond::Condition
        handle::Ptr{Void}

        function AsyncCondition(func=nothing)
            this = new(Condition())
            # the callback is supposed to be called with this AsyncCondition
            # as the argument, so we need to create a wrapper callback
            if func == nothing
                function wrapfunc(data)
                    notify(this.cond)

                    nothing
                end
            else
                function wrapfunc(data)
                    notify(this.cond)
                    func(this)

                    nothing
                end
            end
            work = Base.SingleAsyncWork(wrapfunc)
            this.handle = work.handle

            this
        end
    end

    Base.wait(c::AsyncCondition) = wait(c.cond)
end
