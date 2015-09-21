import strtabs, asyncnet, asyncdispatch, parseutils, uri, strutils

type
    Request* = object
        client*: AsyncSocket
        reqMethod*: string
        headers*: StringTableRef
        protocol*: tuple[orig: string, major, minor: int]
        url*: Uri
        hostname*: string ## The hostname of the client that made the request.
        body*: string

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
                     ver: HttpVersion): bool =
    let major =
        case ver
        of HttpVer11, HttpVer10: 1
    let minor =
        case ver
        of HttpVer11: 1
        of HttpVer10: 0
    result = protocol.major == major and protocol.minor == minor

proc addHeaders(msg: var string, headers: StringTableRef) =
    for k, v in headers:
        msg.add(k & ": " & v & "\c\L")

proc sendHeaders*(req: Request, headers: StringTableRef): Future[void] =
    ## Sends the specified headers to the requesting client.
    var msg = ""
    addHeaders(msg, headers)
    return req.client.send(msg)

proc respond*(req: Request, code: HttpCode, content: string,
              headers: StringTableRef = nil): Future[void] =
    ## Responds to the request with the specified ``HttpCode``, headers and
    ## content.
    ##
    ## This procedure will **not** close the client socket.
    var msg = "HTTP/1.1 " & $code & "\c\L"

    if headers != nil:
        msg.addHeaders(headers)
    msg.add("Content-Length: " & $content.len & "\c\L\c\L")
    msg.add(content)
    result = req.client.send(msg)

proc parseHeader(line: string): tuple[key, value: string] =
    var i = 0
    i = line.parseUntil(result.key, ':')
    inc(i) # skip :
    if i < len(line):
        i += line.skipWhiteSpace(i)
        i += line.parseUntil(result.value, {'\c', '\L'}, i)
    else:
        result.value = ""

proc parseProtocol(protocol: string): tuple[orig: string, major, minor: int] =
    var i = protocol.skipIgnoreCase("HTTP/")
    if i != 5:
        raise newException(ValueError, "Invalid request protocol. Got: " &
                protocol)
    result.orig = protocol
    i.inc protocol.parseInt(result.major, i)
    i.inc # Skip .
    i.inc protocol.parseInt(result.minor, i)

proc sendStatus(client: AsyncSocket, status: string): Future[void] =
    client.send("HTTP/1.1 " & status & "\c\L")

proc processClient(client: AsyncSocket, address: string,
                   callback: proc (request: Request):
                   Future[void] {.closure, gcsafe.}) {.async.} =
    var request: Request
    request.url = initUri()
    request.headers = newStringTable(modeCaseInsensitive)
    var lineFut = newFutureVar[string]("asynchttpserver.processClient")
    lineFut.mget() = newStringOfCap(80)
    var key, value = ""

    while not client.isClosed:
        # GET /path HTTP/1.1
        # Header: val
        # \n
        request.headers.clear(modeCaseInsensitive)
        request.body = ""
        request.hostname.shallowCopy(address)
        assert client != nil
        request.client = client

        # First line - GET /path HTTP/1.1
        lineFut.mget().setLen(0)
        lineFut.clean()
        await client.recvLineInto(lineFut) # TODO: Timeouts.
        if lineFut.mget == "":
            client.close()
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
                    asyncCheck request.respond(Http400,
                        "Invalid request protocol. Got: " & linePart)
                    continue
            else:
                await request.respond(Http400, "Invalid request. Got: " & lineFut.mget)
                continue
            inc i

        # Headers
        while true:
            i = 0
            lineFut.mget.setLen(0)
            lineFut.clean()
            await client.recvLineInto(lineFut)

            if lineFut.mget == "":
                client.close(); return
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

            # Read the body
            # - Check for Content-length header
            if request.headers.hasKey("Content-Length"):
                var contentLength = 0
                if parseInt(request.headers["Content-Length"], contentLength) == 0:
                    await request.respond(Http400, "Bad Request. Invalid Content-Length.")
                    continue
                else:
                    request.body = await client.recv(contentLength)
                    assert request.body.len == contentLength
            else:
                await request.respond(Http400, "Bad Request. No Content-Length.")
                continue

        case request.reqMethod
        of "get", "post", "head", "put", "delete", "trace", "options", "connect", "patch":
            await callback(request)
        else:
            await request.respond(Http400, "Invalid request method. Got: " & request.reqMethod)

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
            break

when defined(windows):
    type
        AsyncHttpServer* = ref object
            socket: AsyncSocket
            reuseAddr: bool

    proc newAsyncHttpServer*(reuseAddr = true): AsyncHttpServer =
        ## Creates a new ``AsyncHttpServer`` instance.
        new result
        result.reuseAddr = reuseAddr

    proc close*(server: AsyncHttpServer) =
        ## Terminates the async http server instance.
        server.socket.close()

    proc serve*(server: AsyncHttpServer, port: Port,
                callback: proc (request: Request): Future[void] {.closure,gcsafe.},
                address = "") {.async.} =
        ## Starts the process of listening for incoming HTTP connections on the
        ## specified address and port.
        ##
        ## When a request is made by a client the specified callback will be called.
        server.socket = newAsyncSocket()
        if server.reuseAddr:
            server.socket.setSockOpt(OptReuseAddr, true)
        server.socket.bindAddr(port, address)
        server.socket.listen()

        while true:
            var fut = await server.socket.acceptAddr()
            asyncCheck processClient(fut.client, fut.address, callback)
else:
    import asyncpipe, os, posix

    let isWorker* = existsEnv("CLUSTER_INSTANCE_ID")
    let isMaster* = not isWorker
    from rawsockets import setBlocking

    type
        WorkKind* = enum
            wkOwner, wkWorker

        AsyncHttpServer* = ref object
            case kind: WorkKind
            of wkWorker:
                pipefd: AsyncFD
            of wkOwner:
                socket: AsyncSocket
            reuseAddr: bool

    proc newAsyncHttpServer*(reuseAddr = true): AsyncHttpServer =
        result.new()
        if isWorker:
            result.kind = wkWorker
            result.pipefd = paramStr(1).parseInt().AsyncFD()
            result.pipefd.register()
            result.pipefd.SocketHandle().setBlocking(false)
        else:
            result.kind = wkOwner
            result.socket = newAsyncSocket()
        result.reuseAddr = reuseAddr

    proc processClient*(pipefd: AsyncFD, client: AsyncSocket, address: string,
                        callback: proc (request: Request):
                        Future[void] {.closure, gcsafe.}) {.async.} =
        var request: Request
        request.url = initUri()
        request.headers = newStringTable(modeCaseInsensitive)
        var lineFut = newFutureVar[string]("asynchttpserver.processClient")
        lineFut.mget() = newStringOfCap(80)
        var key, value = ""

        while not client.isClosed:
            # GET /path HTTP/1.1
            # Header: val
            # \n
            request.headers.clear(modeCaseInsensitive)
            request.body = ""
            request.hostname.shallowCopy(address)
            assert client != nil
            request.client = client

            # First line - GET /path HTTP/1.1
            lineFut.mget().setLen(0)
            lineFut.clean()
            await client.recvLineInto(lineFut) # TODO: Timeouts.
            if lineFut.mget == "":
                client.close()
                asyncCheck pipefd.sendState(ssClose)
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
                        asyncCheck request.respond(Http400,
                            "Invalid request protocol. Got: " & linePart)
                        continue
                else:
                    await request.respond(Http400, "Invalid request. Got: " & lineFut.mget)
                    continue
                inc i

            # Headers
            while true:
                i = 0
                lineFut.mget.setLen(0)
                lineFut.clean()
                await client.recvLineInto(lineFut)

                if lineFut.mget == "":
                    client.close()
                    asyncCheck pipefd.sendState(ssClose)
                    return
                if lineFut.mget == "\c\L": 
                    break
                let (key, value) = parseHeader(lineFut.mget)
                request.headers[key] = value

            if request.reqMethod == "post":
                # Check for Expect header
                if request.headers.hasKey("Expect"):
                    if request.headers["Expect"].toLower == "100-continue":
                        await client.sendStatus("100 Continue")
                    else:
                        await client.sendStatus("417 Expectation Failed")

                # Read the body
                # - Check for Content-length header
                if request.headers.hasKey("Content-Length"):
                    var contentLength = 0
                    if parseInt(request.headers["Content-Length"], contentLength) == 0:
                        await request.respond(Http400, "Bad Request. Invalid Content-Length.")
                        continue
                    else:
                        request.body = await client.recv(contentLength)
                        assert request.body.len == contentLength
                else:
                    await request.respond(Http400, "Bad Request. No Content-Length.")
                    continue

            case request.reqMethod
            of "get", "post", "head", "put", "delete", "trace", "options", "connect", "patch":
                await callback(request)
            else:
                await request.respond(Http400, "Invalid request method. Got: " & request.reqMethod)

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
                asyncCheck pipefd.sendState(ssClose)
                break

    proc serve*(server: AsyncHttpServer, port: Port, 
                callback: proc (request: Request): Future[void] {.closure,gcsafe.},
                address = "") {.async.} =
        if isWorker:
            if paramCount() >= 2 and paramStr(2) == "0":
               await server.pipefd.send($port.int() & "\r\n" & address & "\r\n", {})
            while true:
                var client = await server.pipefd.recvHandle()
                case client
                of AsyncFD(-1):
                    asyncCheck server.pipefd.sendState(ssUnknow)
                of AsyncFD(0):
                    asyncCheck server.pipefd.sendState(ssLimit)
                else:
                    client.register()
                    client.SocketHandle().setBlocking(false)
                    asyncCheck server.pipefd.sendState(ssAppend)
                    asyncCheck server.pipefd.processClient(client.newAsyncSocket(), "", callback)
        else:
            if server.reuseAddr:
                server.socket.setSockOpt(OptReuseAddr, true)
            server.socket.bindAddr(port, address)
            server.socket.listen()
            while true:
                var fut = await server.socket.acceptAddr()
                asyncCheck processClient(fut.client, fut.address, callback)

    proc close*(server: AsyncHttpServer) =
        if server.kind == wkWorker:
            server.pipefd.closeSocket()
        else:
            server.socket.close()
