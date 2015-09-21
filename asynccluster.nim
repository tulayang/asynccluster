import asynchttpserver
export asynchttpserver

when defined(windows):
    discard
else:
    import asyncpipe, osproc, os, posix, asyncdispatch, asyncnet, strutils
    from rawsockets import setBlocking

    type
        Worker* = ref object
            prc*: Process
            connections*: int
            pipefd*: AsyncFD
            slavefd*: AsyncFD

        AsyncMaster = ref object
            workers*: seq[Worker]
            maxConnections*: int
            connections*: int
            socket: AsyncSocket
            cores: int
            reuseAddr: bool

    proc newWorker*(id: int, first = false): Worker =  
        var (pipefd, slavefd) = socketpair()
        putEnv("CLUSTER_INSTANCE_ID", $id)
        result.new()
        result.pipefd = pipefd
        result.pipefd.register()
        result.pipefd.SocketHandle().setBlocking(false)
        result.slavefd = slavefd
        result.prc = if first: startProcess(paramStr(0), args = [$slavefd.int(), "0"])
                     else: startProcess(paramStr(0), args = [$slavefd.int()]) 

    proc restartProcess*(x: Worker) =
        x.prc.close()
        x.prc = startProcess(paramStr(0), args = [$x.slavefd.int()])
        x.connections = 0

    proc close*(x: Worker) =
        x.prc.kill()
        x.prc.close()
        x.pipefd.closeSocket()
        discard x.slavefd.SocketHandle().close()
        x.connections = 0

    proc newAsyncMaster*(cores: int, maxConnections = -1, reuseAddr = true): AsyncMaster = 
        assert cores > 0
        result.new()
        result.cores = cores
        result.workers = newSeq[Worker](cores)
        result.reuseAddr = reuseAddr
        result.socket = newAsyncSocket()
        result.maxConnections = maxConnections
        
    proc selectWorker(master: AsyncMaster): Worker =
        result = master.workers[0]
        for worker in master.workers:
            if worker.prc.running():
                if worker.connections == 0:
                    return worker 
                if result.connections > worker.connections:
                    result = worker
            else:
                master.connections.dec(worker.connections)
                worker.restartProcess()
                echo ">> worker restart "
                return worker

    proc recvStateAlways(master: AsyncMaster, worker: Worker) {.async.} =
        while true:
            var state = await worker.pipefd.recvState()
            case state
            of ssUnknow: 
                discard
            of ssLimit: 
                worker.connections.dec()
                master.connections.dec()
            of ssAppend: 
                discard
            of ssClose: 
                worker.connections.dec()
                master.connections.dec()

    proc sendHandleAndClose(fd: AsyncFD, handle: AsyncFD) {.async.} =
        await fd.sendHandle(handle)
        discard handle.SocketHandle().close()

    proc acceptAlways(master: AsyncMaster) {.async.} =
        while true:
            var fut = await master.socket.getFd().AsyncFD().acceptAddr()
            master.connections.inc()
            # if master.maxConnections > 0 and master.connections > master.maxConnections:
            #     while true:
            #         await sleepAsync(500)
            #         if master.connections < master.maxConnections:
            #             break
            #echo "connections ===  master ", master.connections 
            var worker = master.selectWorker()
            worker.connections.inc()
            asyncCheck worker.pipefd.sendHandleAndClose(fut.client)

    proc serve*(master: AsyncMaster) {.async.} =
        assert existsEnv("CLUSTER_INSTANCE_ID") == false

        for i in 0..master.cores-1:
            master.workers[i] = newWorker(i, if i == 0: true else: false)

        var port = await master.workers[0].pipefd.recvLine()
        var address = await master.workers[0].pipefd.recvLine()

        for i in 0..master.cores-1:
            asyncCheck master.recvStateAlways(master.workers[i])

        if master.reuseAddr:
            master.socket.setSockOpt(OptReuseAddr, true)
        master.socket.bindAddr(port.parseInt().Port(), address)
        master.socket.listen()
        asyncCheck master.acceptAlways()
        
when not defined(windows) and isMainModule:
    if isWorker:
        proc cb(req: Request) {.async.} =
            var arr: array[10000, int]
            for i in 0..9999:
                arr[i] = i
            for i in 0..9999:
                arr[i] += i * i
            await req.respond(Http200, "Hello World!")
        var server = newAsyncHttpServer()
        asyncCheck server.serve(Port(8000), cb, "127.0.0.1")
        runForever()
    else:
        var master = newAsyncMaster(2)
        asyncCheck master.serve()
        runForever()