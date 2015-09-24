when not defined(windows):
    import posix, asyncdispatch, os

    type
        HandleMsg = ref object of RootObj
            buff: array[1, char]
            iov: array[1, IOVec]
            cmsg: ptr Tcmsghdr
            msg: Tmsghdr

        WriteableHandleMsg = ref object of HandleMsg
        ReadableHandleMsg = ref object of HandleMsg

        HandleState* = enum  ## State of currently descriptor.
            hsUnknow = '0', hsLimit = '1', hsAppend = '2', hsClose = '3'

    proc CMSG_LEN*(length: Socklen): Socklen {.importc, header: "<sys/socket.h>".}

    proc socketpair*(): tuple[pipefd1: AsyncFD, pipefd2: AsyncFD] =
        var fds: array[2, cint]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0:
            result.pipefd1 = fds[0].AsyncFD()
            result.pipefd2 = fds[1].AsyncFD()
        # else:
        #     raise newException(OSError, "Could not create socket pair.")

    let CmsgHandleLen* = CMSG_LEN(sizeof(AsyncFD).Socklen())

    template handleMsgImpl() =
        result.new()
        result.iov[0].iov_base = result.buff[0].addr()
        result.iov[0].iov_len = 1
        result.cmsg = createU(Tcmsghdr, CmsgHandleLen)  
        result.msg.msg_name = nil
        result.msg.msg_namelen = 0
        result.msg.msg_iov = result.iov[0].addr()
        result.msg.msg_iovlen = 1
        result.msg.msg_control = result.cmsg
        result.msg.msg_controllen = CmsgHandleLen

    proc newWriteableHandleMsg(client: AsyncFD): WriteableHandleMsg =
        handleMsgImpl()
        result.cmsg.cmsg_len = CmsgHandleLen
        result.cmsg.cmsg_level = SOL_SOCKET
        result.cmsg.cmsg_type = SCM_RIGHTS
        (cast[ptr AsyncFD](CMSG_DATA(result.cmsg)))[] = client

    proc newReadableHandleMsg(): ReadableHandleMsg =
        handleMsgImpl()

    proc getHandle(x: ReadableHandleMsg): AsyncFD =
        if x.cmsg.cmsg_len == CmsgHandleLen and 
           x.cmsg.cmsg_level == SOL_SOCKET and
           x.cmsg.cmsg_type == SCM_RIGHTS:  
            return (cast[ptr AsyncFD](CMSG_DATA(x.cmsg)))[]
        else:
            return AsyncFD(-1)

    proc sendHandle*(fd: AsyncFD, handle: AsyncFD): Future[void] = 
        var retFuture = newFuture[void]("sendHandle") 
        var handleMsg = newWriteableHandleMsg(handle)

        proc cb(sock: AsyncFD): bool =
            result = true
            let res = sock.SocketHandle().sendmsg(handleMsg.msg.addr(), 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    handleMsg.cmsg.dealloc()
                    retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                handleMsg.cmsg.dealloc()
                retFuture.complete() 
             
        fd.addWrite(cb)
        return retFuture

    proc recvHandle*(fd: AsyncFD): Future[AsyncFD] =
        var 
            retFuture = newFuture[AsyncFD]("recvHandle") 
            handleMsg = newReadableHandleMsg()

        proc cb(sock: AsyncFD): bool =
            result = true
            let res = sock.SocketHandle().recvmsg(handleMsg.msg.addr(), 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    handleMsg.cmsg.dealloc()
                    retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                retFuture.complete(handleMsg.getHandle()) 
                handleMsg.cmsg.dealloc()

        fd.addRead(cb)
        return retFuture

    proc sendState*(fd: AsyncFD, state: HandleState): Future[void] =
        var retFuture = newFuture[void]("sendState")
        var buff = [state.char()]
        
        proc cb(sock: AsyncFD): bool =
            result = true
            let res = sock.SocketHandle().send(buff[0].addr(), 1'i32, 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                retFuture.complete() 

        fd.addWrite(cb)
        return retFuture

    proc recvState*(fd: AsyncFD): Future[HandleState] =
        var retFuture = newFuture[HandleState]("recvState")
        var buff: array[1, char]

        proc cb(sock: AsyncFD): bool =
            result = true
            let res = sock.SocketHandle().recv(buff[0].addr(), 1'i32, 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                var state = case buff[0]
                            of hsLimit.char(): hsLimit
                            of hsClose.char(): hsClose
                            of hsAppend.char(): hsAppend
                            else: hsUnknow 
                retFuture.complete(state)

        fd.addRead(cb)
        return retFuture

when not defined(windows) and isMainModule:
    from rawsockets import setBlocking

    proc recvHandleAlways(fd: AsyncFD) {.async.} =
        while true:
            var handle = await fd.recvhandle()
            case handle
            of AsyncFD(-1):
                asyncCheck fd.sendState(hsLimit)
            else:
                asyncCheck fd.sendState(hsClose)
                handle.closeSocket()

    proc recvStateAlways(fd: AsyncFD) {.async.} =
        var i = 0
        while true:
            var state = await fd.recvState()
            i.inc()
            case state
            of hsUnknow: echo "unknow ", i
            of hsLimit: echo "limit ", i
            of hsAppend: echo "append ", i
            of hsClose: echo "close ", i

    proc sendHandleAndClose(fd: AsyncFD, handle: AsyncFD) {.async.} =
        await fd.sendHandle(handle)
        discard handle.SocketHandle().close()

    proc sendHandleColl(fd: AsyncFD) {.async.} =
        for i in 1..500:
            asyncCheck fd.sendHandleAndClose(socketpair().pipefd1)

    var (afd, bfd) = socketpair()
    afd.register()
    bfd.register()
    afd.SocketHandle().setBlocking(false)
    bfd.SocketHandle().setBlocking(false)
    asyncCheck bfd.recvHandleAlways()
    asyncCheck afd.recvStateAlways()
    asyncCheck afd.sendHandleColl()
    
    runForever()
