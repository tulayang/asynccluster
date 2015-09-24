import strtabs, asyncnet, asyncdispatch, parseutils, uri, strutils,
       asyncevents, patterns

when defined(asynccluster) and not defined(windows):
    import asyncpipe, os, posix
    from rawsockets import setBlocking

type
    Request* = object
        client*: AsyncSocket
        reqMethod*: string
        headers*: StringTableRef
        protocol*: tuple[orig: string, major, minor: int]
        url*: Uri
        hostname*: string ## The hostname of the client that made the request.
        body*: string
        errorMsg*: string
        params*: StringTableRef

    AsyncHttpServer* = ref object
        when defined(asynccluster) and not defined(windows):
            pipefd: AsyncFD
        else:
            socket: AsyncSocket
        reuseAddr: bool
        emitter: AsyncEventEmitter[Request]
        routesEmitter: AsyncEventTypeEmitter[Request]
        readTimeout: int

    HttpCode* = enum
        Http100 = "100 Continue",
        Http101 = "101 Switching Protocols",
        Http200 = "200 OK",
        Http201 = "201 Created",
        Http202 = "202 Accepted",
        Http204 = "204 No Content",
        Http205 = "205 Reset Content",
        Http206 = "206 Partial Content",
        Http300 = "300 Multiple Choices",
        Http301 = "301 Moved Permanently",
        Http302 = "302 Found",
        Http303 = "303 See Other",
        Http304 = "304 Not Modified",
        Http305 = "305 Use Proxy",
        Http307 = "307 Temporary Redirect",
        Http400 = "400 Bad Request",
        Http401 = "401 Unauthorized",
        Http403 = "403 Forbidden",
        Http404 = "404 Not Found",
        Http405 = "405 Method Not Allowed",
        Http406 = "406 Not Acceptable",
        Http407 = "407 Proxy Authentication Required",
        Http408 = "408 Request Timeout",
        Http409 = "409 Conflict",
        Http410 = "410 Gone",
        Http411 = "411 Length Required",
        Http418 = "418 I'm a teapot",
        Http500 = "500 Internal Server Error",
        Http501 = "501 Not Implemented",
        Http502 = "502 Bad Gateway",
        Http503 = "503 Service Unavailable",
        Http504 = "504 Gateway Timeout",
        Http505 = "505 HTTP Version Not Supported"

    HttpVersion* = enum
        HttpVer11,
        HttpVer10

proc `==`*(protocol: tuple[orig: string, major, minor: int],
           version: HttpVersion): bool =
    let major =
        case version
        of HttpVer11, HttpVer10: 1
    let minor =
        case version
        of HttpVer11: 1
        of HttpVer10: 0
    result = protocol.major == major and protocol.minor == minor

proc addHeaders(msg: var string, headers: StringTableRef) =
    for k, v in headers: msg.add(k & ": " & v & "\c\L")

proc sendHeaders*(req: Request, headers: StringTableRef): Future[void] =
    ## Sends the specified headers to the requesting client.
    var msg = ""
    msg.addHeaders(headers)
    return req.client.send(msg)

proc send*(req: Request, code: HttpCode, content: string,
           headers: StringTableRef = nil): Future[void] =
    ## Responds to the request with the specified ``HttpCode``, headers and
    ## content.
    ##
    ## This procedure will **not** close the client socket.
    var msg = "HTTP/1.1 " & $code & "\c\L"

    if headers != nil: msg.addHeaders(headers)
    msg.add("Content-Length: " & $content.len() & "\c\L\c\L")
    msg.add(content)
    result = req.client.send(msg)

proc parseHeader(line: string): tuple[key, value: string] =
    var i = 0
    i = line.parseUntil(result.key, ':')
    i.inc() # skip :
    if i < line.len():
        i += line.skipWhiteSpace(i)
        i += line.parseUntil(result.value, {'\c', '\L'}, i)
    else:
        result.value = ""

proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
    var i = protocol.skipIgnoreCase("HTTP/")
    if i != 5:
        raise newException(ValueError, 
                           "Invalid request protocol. Got: " & protocol)
    result.orig = protocol
    i.inc(protocol.parseInt(result.major, i))
    i.inc() # Skip .
    i.inc(protocol.parseInt(result.minor, i))

proc sendStatus(client: AsyncSocket, status: string): Future[void] =
    client.send("HTTP/1.1 " & status & "\c\L")

proc recvLineInto(socket: AsyncSocket, resString: FutureVar[string], timeout = 0,
                  flags = {SocketFlag.SafeDisconn}): Future[bool] {.async.} =
    let recvFut = socket.recvLineInto(resString, flags)
    if timeout <= 0:
        await recvFut
        result = true
    else:
        await sleepAsync(timeout) or recvFut
        result = if recvFut.finished: true else: false

proc recv(socket: AsyncSocket, resString: ptr string, size: int, timeout = 0,
          flags = {SocketFlag.SafeDisconn}): Future[bool] {.async.} =
    let recvFut = socket.recv(size, flags)
    if timeout <= 0:
        await recvFut
        resString[] = recvFut.read()
        result = true
    else:
        await sleepAsync(timeout) or recvFut
        if recvFut.finished:
            resString[] = recvFut.read()
            result = true
        else:
            result = false

proc on*(x: var AsyncHttpServer, 
         name: string, p: proc(e: Request): Future[void] {.closure.}) {.inline.} =
    x.emitter.on(name, p)

proc on*(x: var AsyncHttpServer, 
         name: string, ps: varargs[proc(e: Request): Future[void] {.closure.}]) {.inline.} =
    x.emitter.on(name, ps)

proc on*(x: var AsyncHttpServer, 
         typ: string, name: string, p: proc(e: Request): Future[void] {.closure.}) {.inline.} =
    x.routesEmitter.on(typ, name, p)

proc on*(x: var AsyncHttpServer, 
         typ: string, name: string, ps: varargs[proc(e: Request): Future[void] {.closure.}]) {.inline.} =
    x.routesEmitter.on(typ, name, ps)

proc off*(x: var AsyncHttpServer, 
          name: string, p: proc(e: Request): Future[void] {.closure.}) {.inline.} =
    x.emitter.off(name, p)

proc off*(x: var AsyncHttpServer, 
          name: string, ps: varargs[proc(e: Request): Future[void] {.closure.}]) {.inline.} =
    x.emitter.off(name, ps)

proc off*(x: var AsyncHttpServer, 
          typ: string, name: string, p: proc(e: Request): Future[void] {.closure.}) {.inline.} =
    x.routesEmitter.off(typ, name, p)

proc off*(x: var AsyncHttpServer, 
          typ: string, name: string, ps: varargs[proc(e: Request): Future[void] {.closure.}]) {.inline.} =
    x.routesEmitter.off(typ, name, ps)

proc newAsyncHttpServer*(reuseAddr = true, readTimeout = 0): AsyncHttpServer =
    ## Creates a new ``AsyncHttpServer`` instance.
    result.new()
    result.reuseAddr = reuseAddr
    result.emitter = initAsyncEventEmitter[Request]()
    result.routesEmitter = initAsyncEventTypeEmitter[Request]()
    result.readTimeout = readTimeout * 1000
    when defined(asynccluster):
        result.pipefd = paramStr(1).parseInt().AsyncFD()
        result.pipefd.register()
        result.pipefd.SocketHandle().setBlocking(false)
        var server = result
        proc closeCb(req: Request) {.async, closure.} =
            await server.pipefd.sendState(hsClose)
        result.on("end", closeCb)
    else:
        result.socket = newAsyncSocket()

proc processClient(server: AsyncHttpServer, client: AsyncSocket, address: string) {.async.} =
    var request: Request
    request.url = initUri()
    request.headers = newStringTable(modeCaseInsensitive)
    var lineFut = newFutureVar[string]("asynchttpserver.processClient")
    lineFut.mget() = newStringOfCap(80)
    var key, value = ""
    var readState = false

    await server.emitter.emit("connection", request)

    while not client.isClosed:
        # GET /path HTTP/1.1
        # Header: val
        # \n
        request.headers.clear(modeCaseInsensitive)
        request.body = ""
        request.hostname.shallowCopy(address)
        assert client != nil
        request.client = client

        request.errorMsg = nil
        request.params = nil

        # First line - GET /path HTTP/1.1
        lineFut.mget().setLen(0)
        lineFut.clean()
        readState = await client.recvLineInto(lineFut, server.readTimeout) # TODO: Timeouts.
        if not readState or lineFut.mget == "":
            client.close()
            await server.emitter.emit("end", request)
            return

        var i = 0
        for linePart in lineFut.mget.split(' '):
            case i
            of 0: request.reqMethod.shallowCopy(linePart.normalize)
            of 1: parseUri(linePart, request.url)
            of 2:
                try:
                    request.protocol = parseProtocol(linePart)
                except ValueError:
                    request.errorMsg = "Invalid request protocol. Got: " & linePart
                    asyncCheck request.send(Http400, request.errorMsg)
                    asyncCheck server.emitter.emit("clientError", request)
                    continue
            else:
                request.errorMsg = "Invalid request. Got: " & lineFut.mget()
                await request.send(Http400, request.errorMsg)
                await server.emitter.emit("clientError", request)
                continue
            inc i

        # Headers
        while true:
            i = 0
            lineFut.mget.setLen(0)
            lineFut.clean()
            readState = await client.recvLineInto(lineFut, server.readTimeout)

            if not readState or lineFut.mget == "":
                client.close(); 
                await server.emitter.emit("end", request)
                return
            if lineFut.mget == "\c\L": break
            let (key, value) = parseHeader(lineFut.mget)
            request.headers[key] = value

        if request.reqMethod == "post":
            # Check for Expect header
            if request.headers.hasKey("Expect"):
                if request.headers["Expect"].toLower == "100-continue":
                    await client.sendStatus("100 Continue")
                else:
                    await client.sendStatus("417 Expectation Failed")
                    await server.emitter.emit("clientError", request)


            # Read the body
            # - Check for Content-length header
            if request.headers.hasKey("Content-Length"):
                var contentLength = 0
                if parseInt(request.headers["Content-Length"], contentLength) == 0:
                    request.errorMsg = "Bad Request. Invalid Content-Length."
                    await request.send(Http400, request.errorMsg)
                    await server.emitter.emit("clientError", request)
                    continue
                else:
                    readState = await client.recv(request.body.addr(), contentLength, server.readTimeout)
                    if not readState:
                        client.close()
                        await server.emitter.emit("end", request)
                        return
                    assert request.body.len == contentLength
            else:
                request.errorMsg = "Bad Request. No Content-Length."
                await request.send(Http400, request.errorMsg)
                await server.emitter.emit("clientError", request)
                continue

        case request.reqMethod
        of "get", "post", "head", "put", "delete", "trace", "options", "connect", "patch":
            await server.emitter.emit("request", request)
            var eNode = server.routesEmitter.find(request.reqMethod)
            if not eNode.isNil():
                for nNode in eNode.nodes():
                    var px = nNode.value.parsePattern().match(request.url.path)
                    if px.matched:
                        request.params = px.params
                        await server.routesEmitter.emit(request.reqMethod, nNode.value, request)
                        break
        else:
            request.errorMsg = "Invalid request method. Got: " & request.reqMethod
            await request.send(Http400, request.errorMsg)
            await server.emitter.emit("clientError", request)

        # Persistent connections
        if (request.protocol == HttpVer11 and
                request.headers["connection"].normalize != "close") or
             (request.protocol == HttpVer10 and
                request.headers["connection"].normalize == "keep-alive"):
            # In HTTP 1.1 we assume that connection is persistent. Unless connection
            # header states otherwise.
            # In HTTP 1.0 we assume that the connection should not be persistent.
            # Unless the connection header states otherwise.
            discard
        else:
            request.client.close()
            await server.emitter.emit("end", request)
            break


proc serve*(server: AsyncHttpServer, port: Port, address = "") {.async.} =
    ## Starts the process of listening for incoming HTTP connections on the
    ## specified address and port.
    ##
    ## When a request is made by a client the specified callback will be called.
    when defined(asynccluster) and not defined(windows):
        if paramCount() >= 2 and paramStr(2) == "0":
           await server.pipefd.send($port.int() & "\r\n" & address & "\r\n", {})
        while true:
            var client = await server.pipefd.recvHandle()
            case client
            of AsyncFD(-1):
                asyncCheck server.pipefd.sendState(hsLimit)
            else:
                client.register()
                client.SocketHandle().setBlocking(false)
                asyncCheck server.pipefd.sendState(hsAppend)
                asyncCheck server.processClient(client.newAsyncSocket(), "")
    else:
        if server.reuseAddr:
            server.socket.setSockOpt(OptReuseAddr, true)
        server.socket.bindAddr(port, address)
        server.socket.listen()
        while true:
            var fut = await server.socket.acceptAddr()
            asyncCheck server.processClient(fut.client, fut.address)

proc close*(server: AsyncHttpServer) =
    ## Terminates the async http server instance.
    when defined(asynccluster) and not defined(windows):
        server.pipefd.closeSocket()
    else:
        server.socket.close()

when isMainModule:
    proc server() =
        var server = newAsyncHttpServer(readTimeout = 1)
        asyncCheck server.serve(Port(8000))

        proc doConection(req: Request) {.async, closure.} =
            echo "--- conection"

        proc doRequest(req: Request) {.async, closure.} =
            echo "--- request"
            echo req.reqMethod, " ", req.url

        proc doEnd(req: Request) {.async, closure.} =
            echo "--- end"
        
        proc doClientError(req: Request) {.async, closure.} =
            echo "--- client error " & req.errorMsg

        proc doArticles(req: Request) {.async, closure.} =
            echo "--- request articles"
            echo req.params
            echo req.body
            await req.send(Http200, "Hello world!")

        server.on("connection",  doConection)
        server.on("request",     doRequest)
        server.on("end",         doEnd)
        server.on("clientError", doClientError)
        server.on("post", "/@username/articles", doArticles)
        server.on("get",  "/@username/articles", doArticles)

    import net, os
    proc client() =
        var socket = newSocket() 
        socket.connect("127.0.0.1", Port(8000)) 
        socket.send("POST /xiaoming/articles?method=__put HTTP/1.1\r\n")
        socket.send("Content-Type: application/octet-stream\r\n")
        socket.send("Content-Length: 6\r\n\r\n")
        socket.send("000000")
        socket.send("GET /xiaoming/articles?method=__put HTTP/1.1\r\n")
        socket.send("Content-Type: application/octet-stream\r\n\r\n")

    server()
    client()

    runForever()