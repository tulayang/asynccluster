when not defined(windows):
    import asyncdispatch, asyncnet, nativesockets, net, asyncmsg
    import posix, os, osproc, strutils, strtabs

    type
        PassSetting = object
            maxConnections: int
            port: Port
            reuseAddr: bool
            address: string

        Worker = object
            id: int
            connections: int
            process: Process
            pipe: tuple[fd1: AsyncPipeFD, fd2: AsyncPipeFD]            

        Cluster = ref object
            maxConnections: int
            connections: int
            sockTimeout: int
            workers: seq[Worker]
            socket: AsyncSocket
            reuseAddr: bool

    let isWorker* = existsEnv("CLUSTER_INSTANCE_PIPE")
    let isMaster* = not isWorker

    var workerId = 0
    var cluster: Cluster

    proc toLine(P: PassSetting): string =
        result = $P.maxConnections & '|' & 
                 $int(P.port) & '|' & 
                 (if P.reuseAddr: '1' else: '0') & '|' & 
                 P.address & 
                 "\r\n" 

    proc toPassSetting(s: string): PassSetting =
        let sq = split(s, '|')
        result.maxConnections = parseInt(sq[0])
        result.port = Port(parseInt(sq[1]))
        result.reuseAddr = if sq[2] == "0": false else: true
        result.address = sq[3]

    proc initWorker(id: int): Worker =
        result.id = id
        result.pipe = asyncmsg.open()
        discard fcntl(SocketHandle(result.pipe.fd1), F_SETFD, FD_CLOEXEC)
        discard fcntl(SocketHandle(result.pipe.fd2), F_SETFD, FD_CLOEXEC)

    proc initEnvTable(fd: AsyncPipeFD, isInit: bool): StringTableRef =
        result = newStringTable(modeCaseInsensitive)
        for key, value in envPairs(): 
            result[key] = value
        result["CLUSTER_INSTANCE_PIPE"] = $int(fd)
        if isInit:
            result["CLUSTER_INSTANCE_INIT"] = "ON"

    proc startPrc(w: var Worker, isInit = false) =
        discard fcntl(SocketHandle(w.pipe.fd2), F_SETFD, cint(0))
        w.process = startProcess(paramStr(0), 
                                 env = initEnvTable(w.pipe.fd2, isInit), 
                                 options = {poParentStreams})
        discard fcntl(SocketHandle(w.pipe.fd2), F_SETFD, FD_CLOEXEC)

    proc restartPrc(w: var Worker) = 
        if not isNil(w.process): 
            discard waitForExit(w.process)
            close(w.process)
        w.connections = 0
        startPrc(w)

    template connections(c: Worker): int =
        c.connections

    template incConnections(w: var Worker) =
        inc(w.connections)

    template decConnections(w: var Worker) =
        dec(w.connections)

    template sendHandle(w: Worker, handle: SocketHandle): Future[void] =
        sendHandle(w.pipe.fd1, handle)

    template recvState(w: Worker): Future[HandleState] =
        recvState(w.pipe.fd1)

    template recvPassSetting(w: Worker): Future[string] =
        recvLine(AsyncFD(w.pipe.fd1))

    template running(w: Worker): bool =
        running(w.process)

    proc getCluster*(): Cluster =
        if isMaster:
            if isNil(cluster):
                cluster = new(Cluster)
                cluster.workers = @[]
                cluster.maxConnections = 1000
                cluster.sockTimeout = 120
                cluster.socket = newAsyncSocket()
            result = cluster

    template incConnections(c: Cluster) =
        inc(c.connections)

    template decConnections(c: Cluster) =
        dec(c.connections)

    template decConnections(c: Cluster, n: int) =
        dec(c.connections, n)

    proc recvStateAlways(c: Cluster, id: int) {.async.} =
        while true:
            var state = await recvState(cluster.workers[id])
            case state
            of hsUnknow: 
                discard
            of hsLimit: 
                decConnections(c.workers[id])
                decConnections(c)
            of hsAppend: 
                discard
            of hsClose: 
                decConnections(c.workers[id])
                decConnections(c)

    proc selectWorker(c: Cluster): int =
        result = 0
        for id in 0..high(c.workers):
            if running(c.workers[id]):
                if connections(c.workers[id]) == 0:
                    return id
                if connections(c.workers[result]) > connections(c.workers[id]):
                    result = id
            else:
                decConnections(c, connections(c.workers[id]))
                restartPrc(c.workers[id])
                return id

    proc acceptClient(socket: AsyncSocket, flags = {SocketFlag.SafeDisconn}): Future[SocketHandle] =
        var retFuture = newFuture[SocketHandle]("acceptClient")
        proc cb(sock: AsyncFD): bool =
            result = true
            var client = accept(SocketHandle(sock), nil, nil)
            if client == osInvalidSocket:
                let lastError = osLastError()
                if int32(lastError) notin {EINTR, EWOULDBLOCK, EAGAIN}:
                    return false
                else:
                    if isDisconnectionError(flags, lastError):
                        return false
                    else:
                        fail(retFuture, newException(OSError, osErrorMsg(lastError)))
            else:
                complete(retFuture, client)
        addRead(AsyncFD(getFd(socket)), cb)
        return retFuture

    proc serve(c: Cluster, port: Port, address: string) {.async.} =
        if c.reuseAddr:
            setSockOpt(c.socket, OptReuseAddr, true)
        bindAddr(c.socket, port, address)
        listen(c.socket)
        while true:
            if c.connections < c.maxConnections:
                var client = await acceptClient(c.socket)
                var id = selectWorker(c)
                incConnections(c)
                incConnections(c.workers[id])
                await sendHandle(c.workers[id], client)
                close(client)
            else:
                await sleepAsync(0)    

    proc forkWorkers*(c: Cluster, n: Natural) =
        for i in 0..<n: 
            var worker = initWorker(workerId)
            if workerId == 0:
                startPrc(worker, true)
                let setting = toPassSetting(waitFor recvPassSetting(worker))
                c.reuseAddr = setting.reuseAddr
                c.maxConnections = setting.maxConnections * n
                add(c.workers, worker)
                asyncCheck recvStateAlways(c, 0)
                # TODO: asyncCheck recvErrorAlways(c, 0)
                asyncCheck serve(c, setting.port, setting.address)
            else:
                startPrc(worker)
                add(c.workers, worker)
                asyncCheck recvStateAlways(c, workerId)
                # TODO: asyncCheck recvErrorAlways(c, workerId)
            inc(workerId)

when not defined(windows) and isMainModule:
    type
        AsyncServer* = ref object
            pipefd: AsyncPipeFD
            maxConnections: int
            sockTimeout: int
            reuseAddr: bool

    proc newAsyncServer(reuseAddr = true, maxConnections = 1024, sockTimeout = 120): AsyncServer =
        new(result)
        result.reuseAddr = reuseAddr
        result.maxConnections = maxConnections
        result.sockTimeout = sockTimeout
        result.pipefd = AsyncPipeFD(parseInt(getEnv("CLUSTER_INSTANCE_PIPE")))
        register(AsyncFD(result.pipefd))
        setBlocking(SocketHandle(result.pipefd), false)

    proc close(server: AsyncServer) =
        closeSocket(AsyncFD(server.pipefd))

    template sendSetting(server: AsyncServer, data: PassSetting): Future[void] =
        send(AsyncFD(server.pipefd), toLine(data))

    template recvHandle(server: AsyncServer): Future[SocketHandle] = 
        recvHandle(server.pipefd)

    template sendState(server: AsyncServer, state: HandleState): Future[void] =
        sendState(server.pipefd, state)

    template newClient(fd: SocketHandle): AsyncSocket = 
        register(AsyncFD(fd))
        setBlocking(fd, false)
        newAsyncSocket(AsyncFD(fd))

    proc processClient(server: AsyncServer, client: AsyncSocket, address: string) {.async.} =
        await send(client, "Hello world!")
        close(client)
        await sendState(server, hsClose)

    proc serve(server: AsyncServer, port: Port, address = "") {.async.} =
        if getEnv("CLUSTER_INSTANCE_INIT") == "ON":
            await sendSetting(server, PassSetting(maxConnections: server.maxConnections,
                                                  port: port, 
                                                  reuseAddr: server.reuseAddr,
                                                  address: address))
        while true:
            var clientHandle = await recvHandle(server)
            case clientHandle
            of SocketHandle(-1):
                asyncCheck sendState(server, hsLimit)
            else:
                asyncCheck sendState(server, hsAppend)
                asyncCheck processClient(server, newClient(clientHandle), "")

    if isMaster:
        forkWorkers(getCluster(), 6)
        runForever()
    else:
        var server = newAsyncServer()
        asyncCheck serve(server, Port(8000)) # TODO: sockTimeout maxConnections
        # TODO: 
        # routes:
        #     get "/":
        #         resp "111"
        runForever()