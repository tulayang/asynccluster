when not defined(windows):
    import posix, asyncdispatch, os
    from nativesockets import setBlocking

    type
        AsyncPipeFD* = distinct AsyncFD

        HandleMsg = object
            buf: array[1, char]
            iov: array[1, IOVec]
            cmsg: ptr Tcmsghdr
            msg: Tmsghdr

        WriteableHmsg = ptr HandleMsg
        ReadableHmsg = ptr HandleMsg

        HandleState* = enum  ## State of currently descriptor.
            hsUnknow = '0', hsLimit = '1', hsAppend = '2', hsClose = '3'

    # proc CMSG_LEN*(length: Socklen): Socklen {.importc, header: "<sys/socket.h>".}
    # let CmsgHandleLen* = CMSG_LEN(Socklen(sizeof(SocketHandle)))

    let CmsgHandleLen = Socklen(((sizeof(Tcmsghdr) + sizeof(SocketHandle) - 1) and 
                                 (not(sizeof(SocketHandle) - 1))) + sizeof(SocketHandle))

    proc createWriteableHmsg(handle: SocketHandle): WriteableHmsg = 
        var cmsgPtr = cast[ptr Tcmsghdr](alloc(CmsgHandleLen))
        result = createU(HandleMsg) 
        result.iov[0].iov_base = addr(result.buf[0])
        result.iov[0].iov_len = 1
        result.cmsg = cmsgPtr
        result.msg.msg_name = nil
        result.msg.msg_namelen = 0 
        result.msg.msg_iov = addr(result.iov[0])
        result.msg.msg_iovlen = 1
        result.msg.msg_control = cmsgPtr
        result.msg.msg_controllen = CmsgHandleLen
        cmsgPtr.cmsg_len = CmsgHandleLen
        cmsgPtr.cmsg_level = SOL_SOCKET
        cmsgPtr.cmsg_type = SCM_RIGHTS
        (cast[ptr SocketHandle](CMSG_DATA(cmsgPtr)))[] = handle

    proc createReadableHmsg(): ReadableHmsg = 
        var cmsgPtr = cast[ptr Tcmsghdr](alloc(CmsgHandleLen))
        result = createU(HandleMsg)
        result.iov[0].iov_base = addr(result.buf[0])
        result.iov[0].iov_len = 1
        result.cmsg = cmsgPtr
        result.msg.msg_name = nil
        result.msg.msg_namelen = 0
        result.msg.msg_iov = addr(result.iov[0])
        result.msg.msg_iovlen = 1
        result.msg.msg_control = cmsgPtr
        result.msg.msg_controllen = CmsgHandleLen

    proc freeHmsg(x: ptr HandleMsg) =
        dealloc(x.cmsg)
        dealloc(x)

    proc open*(): tuple[fd1: AsyncPipeFD, fd2: AsyncPipeFD] =
        var fds: array[0..1, cint]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == -1:
            raiseOsError(osLastError())
        register(AsyncFD(fds[0]))
        setBlocking(SocketHandle(fds[0]), false)
        register(AsyncFD(fds[1]))
        setBlocking(SocketHandle(fds[1]), false)
        result = (AsyncPipeFD(fds[0]), AsyncPipeFD(fds[1]))

    proc close*(pipefd: AsyncPipeFD) =
        closeSocket(AsyncFD(pipefd))

    proc sendHandle*(fd: AsyncPipeFD, handle: SocketHandle): Future[void] = 
        var retFuture = newFuture[void]("sendHandle")  

        proc cb(sock: AsyncFD): bool =
            result = true
            let hmsg = createWriteableHmsg(handle)
            let res = sendmsg(SocketHandle(sock), addr(hmsg.msg), cint(0))
            if res == -1:
                let lastError = osLastError()
                if int32(lastError) notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    fail(retFuture, newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                complete(retFuture)
            freeHmsg(hmsg)
             
        addWrite(AsyncFD(fd), cb)
        return retFuture

    proc recvHandle*(fd: AsyncPipeFD): Future[SocketHandle] =
        var retFuture = newFuture[SocketHandle]("recvHandle") 

        proc cb(sock: AsyncFD): bool =
            result = true
            var hmsg = createReadableHmsg()
            let res = recvmsg(SocketHandle(sock), addr(hmsg.msg), cint(0))
            if res == -1:
                let lastError = osLastError()
                if int32(lastError) notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    fail(retFuture, newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            elif hmsg.cmsg.cmsg_len == CmsgHandleLen and 
                 hmsg.cmsg.cmsg_level == SOL_SOCKET and
                 hmsg.cmsg.cmsg_type == SCM_RIGHTS:
                 complete(retFuture, (cast[ptr SocketHandle](CMSG_DATA(hmsg.cmsg)))[]) 
            else:
                complete(retFuture, SocketHandle(-1)) 
            freeHmsg(hmsg)

        addRead(AsyncFD(fd), cb)
        return retFuture

    proc sendState*(fd: AsyncPipeFD, state: HandleState): Future[void] =
        var retFuture = newFuture[void]("sendState")
        
        proc cb(sock: AsyncFD): bool =
            result = true
            var smsg = char(state)
            let res = send(SocketHandle(sock), addr(smsg), cint(1), cint(0))
            if res == -1:
                let lastError = osLastError()
                if int32(lastError) notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    fail(retFuture, newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                complete(retFuture) 

        addWrite(AsyncFD(fd), cb)
        return retFuture

    proc recvState*(fd: AsyncPipeFD): Future[HandleState] =
        var retFuture = newFuture[HandleState]("recvState")

        proc cb(sock: AsyncFD): bool =
            result = true
            var smsg = '\0'
            let res = recv(SocketHandle(sock), addr(smsg), cint(1), cint(0))
            if res == -1:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    fail(retFuture, newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                var state = case smsg
                            of char(hsLimit): hsLimit
                            of char(hsClose): hsClose
                            of char(hsAppend): hsAppend
                            else: hsUnknow 
                complete(retFuture, state)

        addRead(AsyncFD(fd), cb)
        return retFuture

when not defined(windows) and isMainModule:
    import os, osproc, strutils
    from rawsockets import setBlocking

    const handleNums = 110000

    proc recvHandleAlways(fd: AsyncPipeFD) {.async.} =
        while true:
            var handle = await recvhandle(fd)
            echo "recv handle ", repr handle
            case handle
            of SocketHandle(-1):
                asyncCheck sendState(fd, hsLimit)
            else:
                assert close(handle) == 0
                asyncCheck sendState(fd, hsClose)

    proc recvStateAlways(fd: AsyncPipeFD) {.async.} =
        var i = 0
        while true:
            var state = await recvState(fd)
            inc(i)
            case state
            of hsUnknow: echo "unknow ", i
            of hsLimit: echo "limit ", i
            of hsAppend: echo "append ", i
            of hsClose: echo "close ", i
            if i == handleNums: quit(0)

    proc sendHandleQueue(fd: AsyncPipeFD) {.async.} =
        for i in 1..handleNums:
            var fds: array[2, cint]
            assert pipe(fds) == 0
            assert close(fds[1]) == 0
            await sendHandle(fd, SocketHandle(fds[0]))
            assert close(fds[0]) == 0

    if existsEnv("CHILD"):
        var fd = parseInt(paramStr(1))
        register(AsyncFD(fd))
        setBlocking(SocketHandle(fd), false)
        asyncCheck recvHandleAlways(AsyncPipeFD(fd))
        runForever()
    else:
        var (fd1, fd2) = open()

        putEnv("CHILD", "1")
        var prcocess = startProcess(paramStr(0), args = [$int(fd2)], options = {poParentStreams})

        asyncCheck recvStateAlways(fd1)
        asyncCheck sendHandleQueue(fd1)

        runForever()
