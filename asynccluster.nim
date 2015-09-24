when not defined(windows):
    import asynchttp, asyncdispatch, asyncpipe, asyncnet, osproc, os, posix, strutils
    from rawsockets import setBlocking

    type
        Worker* = ref object  ## Work process for http server instance.
            prcocess: Process
            connections: int
            pipefd1: AsyncFD
            pipefd2: AsyncFD

        AsyncCluster = ref object  ## Cluster for manage workers.
            workers: seq[Worker]
            maxConnections*: int
            connections*: int
            socket: AsyncSocket
            cores: int
            reuseAddr: bool

    let isWorker* = existsEnv("CLUSTER_INSTANCE_ID")
    let isMaster* = not isWorker

    proc newWorker*(id: int, first = false): Worker =  
        ## Creates a new worker.
        var (pipefd1, pipefd2) = socketpair()
        putEnv("CLUSTER_INSTANCE_ID", $id)
        result.new()
        result.pipefd1 = pipefd1
        result.pipefd1.register()
        result.pipefd1.SocketHandle().setBlocking(false)
        result.pipefd2 = pipefd2
        result.prcocess = if first: startProcess(paramStr(0), args = [$pipefd2.int(), "0"])
                          else: startProcess(paramStr(0), args = [$pipefd2.int()]) 

    proc restartProcess*(x: Worker) =
        ## Restarts the worker process, connections will be reset 0.
        x.prcocess.close()
        x.prcocess = startProcess(paramStr(0), args = [$x.pipefd2.int()])
        x.connections = 0

    proc close*(x: Worker) =
        ## Closes the worker.
        x.prcocess.kill()
        x.prcocess.close()
        x.pipefd1.closeSocket()
        discard x.pipefd2.SocketHandle().close()
        x.connections = 0

    proc newAsyncCluster*(cores: int, maxConnections = 1000, reuseAddr = true): AsyncCluster = 
        ## Creates a new asynchronous cluster manager.
        assert cores > 0
        result.new()
        result.cores = cores
        result.workers = newSeq[Worker](cores)
        result.reuseAddr = reuseAddr
        result.socket = newAsyncSocket()
        result.maxConnections = maxConnections
        
    proc selectWorker(cluster: AsyncCluster): Worker =
        result = cluster.workers[0]
        for worker in cluster.workers:
            if worker.prcocess.running():
                if worker.connections == 0:
                    return worker 
                if result.connections > worker.connections:
                    result = worker
            else:
                cluster.connections.dec(worker.connections)
                worker.restartProcess()
                echo "restart"
                return worker

    proc recvStateAlways(cluster: AsyncCluster, index: int) {.async.} =
        var worker = cluster.workers[index]
        while true:
            var state = await worker.pipefd1.recvState()
            case state
            of hsUnknow: 
                discard
            of hsLimit: 
                worker.connections.dec()
                cluster.connections.dec()
            of hsAppend: 
                discard
            of hsClose: 
                worker.connections.dec()
                cluster.connections.dec()

    proc sendHandleAndClose(fd: AsyncFD, handle: AsyncFD) {.async.} =
        await fd.sendHandle(handle)
        discard handle.SocketHandle().close()

    proc acceptAlways(cluster: AsyncCluster) {.async.} =
        while true:
            if cluster.connections < cluster.maxConnections:
                var fut = await cluster.socket.getFd().AsyncFD().acceptAddr()
                var worker = cluster.selectWorker()
                cluster.connections.inc()
                worker.connections.inc()
                asyncCheck worker.pipefd1.sendHandleAndClose(fut.client)
            else:
               await sleepAsync(0)

    proc serve*(cluster: AsyncCluster) {.async.} =
        ## Starts the worker processes, and listening for incoming HTTP connections.
        assert existsEnv("CLUSTER_INSTANCE_ID") == false

        for i in 0..cluster.cores-1:
            cluster.workers[i] = newWorker(i, if i == 0: true else: false)

        var port = await cluster.workers[0].pipefd1.recvLine()
        var address = await cluster.workers[0].pipefd1.recvLine()

        for i in 0..cluster.cores-1:
            asyncCheck cluster.recvStateAlways(i)

        if cluster.reuseAddr:
            cluster.socket.setSockOpt(OptReuseAddr, true)
        cluster.socket.bindAddr(port.parseInt().Port(), address)
        cluster.socket.listen()
        asyncCheck cluster.acceptAlways()
        
when isMainModule:
    if isWorker:
        proc cb(req: Request) {.async.} =
            # var arr: array[10000, int]
            # for i in 0..9999:
            #     arr[i] = i
            # for i in 0..9999:
            #     arr[i] += i * i
            await req.send(Http200, "Hello World!")

        var server = newAsyncHttpServer()
        server.on("request", cb)
        asyncCheck server.serve(Port(8000), "127.0.0.1")
        runForever()
    else:
        var cluster = newAsyncCluster(3)
        asyncCheck cluster.serve()
        runForever()