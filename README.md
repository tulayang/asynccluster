This module implements multi-process support for asynchronous 
server. Howerer, this just a toy and does not provide any 
promise. 

This module has made an independent abstraction of multi-process 
management, but did'nt provide any server implementation. User
should implement an asynchronous server, and follow some 
conventions of the module. 

Expecting official multi-process support.

## Implementation details

### AsyncPipeFD

* open() - Open a pipe pair.
* close() - Close a pipe.
* sendHandle() - Send a file descriptor via a pipe.
* recvHandle() - Recv a file descriptor via a pipe.
* sendState() - Send a state of a file descriptor via a pipe.
* recvState() - Recv a state of a file descriptor via a pipe.

### Worker

The worker manager abstraction, which to start and restart child process, transfer client descriptors, receive the states of client descriptors.

* id               - No.
* process          - The worker process.
* pipe             - Pipe pair. The `fd1` is used by the master server, and the `fd2` is copied to the worker server.
* connections      - Current connections.

* initWorker()     - Init.
* initEnvTable()   - Init environment variable of worker process.
* startPrc()       - Start worker process.
* restartPrc()     - Restart worker process.
* connections()    - Get current connections.
* incConnections() - Increases current connections.
* decConnections() - Decreases current connections.
* sendHandle()     - Send a client descriptor via a pipe.
* recvState()      - Recv a state of a client descriptor via a pipe.
* recvSetting()    - Recv a `PassSetting` via a pipe.
* running()        - The worker processes are still running ?

## Cluster

The cluster manager abstraction, which to select a worker to process a client request.

* maxConnections    - Max connections.
* connections       - Current connections.
* sockTimeout       - 
* socket            - Server socket.
* reuseAddr         - 
* workers           - Workers sequence.

* getCluster()      - Return the cluster manager.
* forkWorkers()     - Instantiates worker servers.
* acceptClient()    - Accept client requests.
* selectWorker()    - Select the worker server with the lowest load.
* incConnections()  - Increases current connections.
* decConnections()  - Decreases current connections.
* serve()           - Start master server.

## Example:

```nim
import asynccluster, asyncdispatch, asyncnet, strutils, os, nativesockets

type
    AsyncServer = ref object
        pipefd: AsyncPipeFD  # Pipe fd for receive client descriptors from master server.
        maxConnections: int
        sockTimeout: int
        reuseAddr: bool

proc newAsyncServer(reuseAddr = true, maxConnections = 1024, sockTimeout = 120): AsyncServer =
    new(result)
    result.reuseAddr = reuseAddr
    result.maxConnections = maxConnections
    result.sockTimeout = sockTimeout
    # The pipe fd of worker server is passed through the environment `CLUSTER_INSTANCE_PIPE`
    # by master server. 
    result.pipefd = AsyncPipeFD(parseInt(getEnv("CLUSTER_INSTANCE_PIPE")))
    # Then, register it as a AsyncFD.
    register(AsyncFD(result.pipefd))
    setBlocking(SocketHandle(result.pipefd), false)

proc close(server: AsyncServer) =
    closeSocket(AsyncFD(server.pipefd))

template sendSetting(server: AsyncServer, data: PassSetting): Future[void] =
    # Send a `PassSetting` to master server to config server.
    send(AsyncFD(server.pipefd), toLine(data))

template recvHandle(server: AsyncServer): Future[SocketHandle] = 
    # Receive a client descriptor from master server.
    recvHandle(server.pipefd)

template sendState(server: AsyncServer, state: HandleState): Future[void] =
    # Report the state of client descriptor to master server, which can help
    # master server to manage workers. 
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
    ## If the worker server if the first instance, sends settings to master server.
    if getEnv("CLUSTER_INSTANCE_INIT") == "ON":
        await sendSetting(server, initPassSetting(server.maxConnections,
                port, server.reuseAddr, address))
    while true:
        var clientHandle = await recvHandle(server)
        case clientHandle
        of SocketHandle(-1):  # File descriptors limited 
            asyncCheck sendState(server, hsLimit)
        else:
            asyncCheck sendState(server, hsAppend)
            asyncCheck processClient(server, newClient(clientHandle), "")

if isMaster:  # In master process.
    forkWorkers(getCluster(), 6)  # Instances 6 worker servers.
    runForever()
else:  # In worker process.
    var server = newAsyncServer()
    asyncCheck serve(server, Port(8000))
    runForever()
```
