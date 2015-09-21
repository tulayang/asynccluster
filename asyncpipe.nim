when not defined(windows):
    import posix, asyncdispatch, os
    from net import isDisconnectionError

    type
        Fdmsg* = object of RootObj  ## A Tmsghdr wrapper for pass descriptorx. 
            buff: array[1, char]
            iov: array[1, TIOVec]
            cmsg: ptr Tcmsghdr
            msg*: Tmsghdr

        WriteableFdmsg* = object of Fdmsg
        ReadableFdmsg* = object of Fdmsg    

    proc CMSG_LEN*(length: Socklen): Socklen {.importc, header: "<sys/socket.h>".}

    proc socketpair*(): tuple[pipefd1: AsyncFD, pipefd2: AsyncFD] =
        var fds: array[2, cint]
        if socketpair(AF_UNIX, SOCK_STREAM, 0, fds) == 0:
            result.pipefd1 = fds[0].AsyncFD()
            result.pipefd2 = fds[1].AsyncFD()
        else:
            raise newException(OSError, "Could not create socket pair.")

    let CmsgHandleLen* = CMSG_LEN(sizeof(SocketHandle).Socklen())

    template fdmsgImpl() =
        result.iov[0].iov_base = result.buff.addr()
        result.iov[0].iov_len = 1
        result.cmsg = createU(Tcmsghdr, CmsgHandleLen)  
        result.msg.msg_name = nil
        result.msg.msg_namelen = 0
        result.msg.msg_iov = result.iov[0].addr()
        result.msg.msg_iovlen = 1
        result.msg.msg_control = result.cmsg
        result.msg.msg_controllen = CmsgHandleLen

    template freeCmsgImpl() = 
        x.cmsg.dealloc()

    template lenMsgImpl() =
        result = 1

    proc initWriteableFdmsg*(): WriteableFdmsg =
        fdmsgImpl()

    proc freeCmsg*(x: WriteableFdmsg) =
        x.cmsg.dealloc()

    proc lenMsg*(x: WriteableFdmsg): int = 
        result = 1

    proc setHandle*(x: var WriteableFdmsg, fd: AsyncFD) = 
        x.buff[0] = '0'
        x.cmsg.cmsg_len = CmsgHandleLen
        x.cmsg.cmsg_level = SOL_SOCKET
        x.cmsg.cmsg_type = SCM_RIGHTS
        (cast[ptr AsyncFD](CMSG_DATA(x.cmsg)))[] = fd

    proc initReadableFdmsg*(): ReadableFdmsg =
        fdmsgImpl()

    proc freeCmsg*(x: ReadableFdmsg) =
        freeCmsgImpl()

    proc lenMsg*(x: ReadableFdmsg): int = 
        lenMsgImpl()

    proc getHandle*(x: var ReadableFdmsg): AsyncFD = 
        if x.buff[0] == '0':
            if x.cmsg.cmsg_len == CmsgHandleLen and 
               x.cmsg.cmsg_level == SOL_SOCKET and
               x.cmsg.cmsg_type == SCM_RIGHTS:  
                return (cast[ptr AsyncFD](CMSG_DATA(x.cmsg)))[]
            else:
                return AsyncFD(0)
        else:
            return AsyncFD(-1)

    type
        SocketState* = enum  ## State of currently descriptor.
            ssUnknow = '0', ssLimit = '1', ssAppend = '2', ssClose = '3'

        Statemsg* = object of RootObj
            buff: array[1, char]

        WriteableStatemsg* = object of Statemsg
        ReadableStatemsg* = object of Statemsg 

    template lenMsgImpl() =
        result = 1

    proc initWriteableStatemsg*(): WriteableStatemsg = discard

    proc lenMsg*(x: WriteableStatemsg): int =
        lenMsgImpl()

    proc setState*(x: var WriteableStatemsg, state: SocketState) =
        x.buff[0] = state.char()

    proc initReadableStatemsg*(): ReadableStatemsg = discard

    proc lenMsg*(x: ReadableStatemsg): int =
        lenMsgImpl()

    proc getState*(x: ReadableStatemsg): SocketState =
        return case x.buff[0]
               of ssLimit.char(): ssLimit
               of ssClose.char(): ssClose
               of ssAppend.char(): ssAppend
               else: ssUnknow  

    proc sendHandle*(fd: AsyncFD, handle: AsyncFD, flags = {SocketFlag.SafeDisconn}): Future[void] = 
        var retFuture = newFuture[void]("sendHandle")
        var written = 0
        var fdmsg = initWriteableFdmsg()
        fdmsg.setHandle(handle)
        
        proc cb(sock: AsyncFD): bool =
            result = true
            let netSize = fdmsg.lenMsg() - written
            let res = sock.SocketHandle().sendmsg(fdmsg.msg.addr(), 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    if flags.isDisconnectionError(lastError):
                        retFuture.complete()
                        fdmsg.freeCmsg()
                    else:
                        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                        fdmsg.freeCmsg()
                else:
                    result = false
            else:
                written.inc(res)
                if res != netSize:
                    result = false
                else:
                    retFuture.complete()
                    fdmsg.freeCmsg()

        fd.addWrite(cb)
        return retFuture

    proc recvHandle*(fd: AsyncFD, flags = {SocketFlag.SafeDisconn}): Future[AsyncFD] =
        var retFuture = newFuture[AsyncFD]("recvHandle")
        var fdmsg = initReadableFdmsg()
        var readden = 0

        proc cb(sock: AsyncFD): bool =
            result = true
            let netSize = fdmsg.lenMsg() - readden
            let res = sock.SocketHandle().recvmsg(fdmsg.msg.addr(), 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    if flags.isDisconnectionError(lastError):                      
                        retFuture.complete(AsyncFD(-1))
                        fdmsg.freeCmsg()
                    else:
                        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                        fdmsg.freeCmsg()
                else:
                    result = false
            elif res == 0:
                retFuture.complete(AsyncFD(-1))
            else:
                readden.inc(res)
                if res != netSize:
                    result = false
                else:
                    retFuture.complete(fdmsg.getHandle())
                    fdmsg.freeCmsg()

        fd.addRead(cb)
        return retFuture

    proc sendState*(fd: AsyncFD, state: SocketState, flags = {SocketFlag.SafeDisconn}): Future[void] =
        var retFuture = newFuture[void]("sendState")
        var written = 0
        var statemsg = initWriteableStatemsg()
        statemsg.setState(state)
        
        proc cb(sock: AsyncFD): bool =
            result = true
            let netSize = statemsg.lenMsg() - written
            let res = sock.SocketHandle().send(statemsg.buff[0].addr(), netSize, 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    if flags.isDisconnectionError(lastError):
                        retFuture.complete()
                    else:
                        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            else:
                written.inc(res)
                if res != netSize:
                    result = false
                else:
                    retFuture.complete()

        fd.addWrite(cb)
        return retFuture

    proc recvState*(fd: AsyncFD, flags = {SocketFlag.SafeDisconn}): Future[SocketState] =
        var retFuture = newFuture[SocketState]("recvState")
        var statemsg = initReadableStatemsg()
        var readden = 0

        proc cb(sock: AsyncFD): bool =
            result = true
            let netSize = statemsg.lenMsg() - readden
            let res = sock.SocketHandle().recv(statemsg.buff[0].addr(), netSize, 0'i32)
            if res < 0:
                let lastError = osLastError()
                if lastError.int32() notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    if flags.isDisconnectionError(lastError):
                        retFuture.complete(ssUnknow)
                    else:
                        retFuture.fail(newException(OSError, osErrorMsg(lastError)))
                else:
                    result = false
            elif res == 0:
                retFuture.complete(ssUnknow)
            else:
                readden.inc(res)
                if res != netSize:
                    result = false
                else:
                    retFuture.complete(statemsg.getState())

        fd.addRead(cb)
        return retFuture

when not defined(windows) and isMainModule:
    from rawsockets import setBlocking

    proc recvHandleAlways(fd: AsyncFD) {.async.} =
        var i = 0
        while true:
            var sockfd = await fd.recvhandle()
            i.inc()
            if sockfd == AsyncFD(-1):
                asyncCheck fd.sendState(ssUnknow)
            elif sockfd == AsyncFD(0):
                asyncCheck fd.sendState(ssLimit)
            else:
                asyncCheck fd.sendState(ssClose)
                sockfd.closeSocket()

    proc recvStateAlways(fd: AsyncFD) {.async.} =
        var i = 0
        while true:
            var state = await fd.recvState()
            i.inc()
            case state
            of ssUnknow: echo "unknow ", i
            of ssLimit: echo "limit ", i
            of ssAppend: echo "append ", i
            of ssClose: echo "close ", i

    proc sendHandleColl(fd: AsyncFD) {.async.} =
        for i in 1..500:
            asyncCheck fd.sendHandle(socketpair().pipefd1)

    var (afd, bfd) = socketpair()
    afd.register()
    bfd.register()
    afd.SocketHandle().setBlocking(false)
    bfd.SocketHandle().setBlocking(false)

    asyncCheck bfd.recvHandleAlways()
    asyncCheck afd.recvStateAlways()
    asyncCheck afd.sendHandleColl()

    runForever()