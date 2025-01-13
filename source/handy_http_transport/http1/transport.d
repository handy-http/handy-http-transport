module handy_http_transport.http1.transport;

import std.socket;

import handy_http_transport.interfaces;
import handy_http_transport.helpers;
import handy_http_transport.response_output_stream;

import handy_http_primitives;
import handy_http_primitives.address;

import streams;
import photon;

/**
 * The HTTP/1.1 transport protocol implementation, using Dimitry Olshansky's
 * Photon fiber scheduling library for concurrency.
 */
class Http1Transport : HttpTransport {
    private Socket serverSocket;
    private HttpRequestHandler requestHandler;
    private const ushort port;
    private bool running = false;

    this(HttpRequestHandler requestHandler, ushort port = 8080) {
        assert(requestHandler !is null);
        this.serverSocket = new TcpSocket();
        this.requestHandler = requestHandler;
        this.port = port;
    }

    void start() {
        startloop();
        go(() => runServer());
        runFibers();
    }

    void stop() {
        this.running = false;
        this.serverSocket.shutdown(SocketShutdown.BOTH);
        this.serverSocket.close();
    }

    private void runServer() {
        this.running = true;
        serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        serverSocket.bind(new InternetAddress("127.0.0.1", port));
        serverSocket.listen(100);
        while (running) {
            try {
                Socket clientSocket = serverSocket.accept();
                go(() => handleClient(clientSocket, requestHandler));
            } catch (SocketAcceptException e) {
                import std.stdio;
                stderr.writefln!"Failed to accept socket connection: %s"(e);
            }
        }
    }
}

/**
 * The main logic for handling an incoming request from a client. It involves
 * reading bytes from the client, parsing them as an HTTP request, passing that
 * to the HTTP Transport's request handler, and then writing the response back
 * to the client.
 * Params:
 *   clientSocket = The newly-accepted client socket.
 *   requestHandler = The request handler that will handle the received HTTP request.
 */
void handleClient(Socket clientSocket, HttpRequestHandler requestHandler) {
    auto inputStream = SocketInputStream(clientSocket);
    auto bufferedInput = bufferedInputStreamFor!(8192)(inputStream);
    // Get remote address from the socket.
    import handy_http_primitives.address;
    ClientAddress addr = getAddress(clientSocket);
    auto result = readHttpRequest(&bufferedInput, addr);
    if (result.hasError) {
        import std.stdio;
        stderr.writeln("Failed to read HTTP request: " ~ result.error.message);
        inputStream.closeStream();
        return;
    }
    scope ServerHttpRequest request = result.request;
    scope ServerHttpResponse response;
    SocketOutputStream outputStream = SocketOutputStream(clientSocket);
    response.outputStream = outputStreamObjectFor(HttpResponseOutputStream!(SocketOutputStream*)(
        &outputStream,
        &response
    ));
    try {
        requestHandler.handle(request, response);
    } catch (Exception e) {
        import std.stdio;
        stderr.writeln("Exception thrown while handling request: " ~ e.msg);
    }
    inputStream.closeStream();
}

/**
 * Gets a ClientAddress value from a socket's address information.
 * Params:
 *   socket = The socket to get address information for.
 * Returns: The address that was obtained.
 */
ClientAddress getAddress(Socket socket) {
    try {
        Address addr = socket.remoteAddress();
        if (auto a = cast(InternetAddress) addr) {
            union U {
                ubyte[4] bytes;
                uint intValue;
            }
            U u;
            u.intValue = a.addr();
            return ClientAddress.ofIPv4(IPv4InternetAddress(
                u.bytes,
                a.port()
            ));
        } else if (auto a = cast(Internet6Address) addr) {
            return ClientAddress.ofIPv6(IPv6InternetAddress(
                a.addr(),
                a.port()
            ));
        } else if (auto a = cast(UnixAddress) addr) {
            return ClientAddress.ofUnixSocket(UnixSocketAddress(a.path()));
        } else {
            return ClientAddress(ClientAddressType.UNKNOWN);
        }
    } catch (SocketOSException e) {
        return ClientAddress(ClientAddressType.UNKNOWN);
    }
}

/// Alias for the result of the `readHttpRequest` function which parses HTTP requests.
alias HttpRequestParseResult = Either!(ServerHttpRequest, "request", StreamError, "error");

/**
 * Parses an HTTP/1.1 request from a byte input stream.
 * Params:
 *   inputStream = The byte input stream to read from.
 *   addr = The client address, used in constructed the http request struct.
 * Returns: Either the request which was parsed, or a stream error.
 */
HttpRequestParseResult readHttpRequest(S)(S inputStream, in ClientAddress addr) if (isByteInputStream!S) {
    auto methodStr = consumeUntil(inputStream, " ");
    if (methodStr.hasError) return HttpRequestParseResult(methodStr.error);
    auto urlStr = consumeUntil(inputStream, " ");
    if (urlStr.hasError) return HttpRequestParseResult(urlStr.error);
    auto versionStr = consumeUntil(inputStream, "\r\n");
    if (versionStr.hasError) return HttpRequestParseResult(versionStr.error);
    
    HttpVersion httpVersion;
    if (versionStr.value == "HTTP/1.1") {
        httpVersion = HttpVersion.V1;
    } else {
        return HttpRequestParseResult(StreamError("Invalid HTTP version: " ~ versionStr.value, 1));
    }

    auto headersResult = parseHeaders(inputStream);
    if (headersResult.hasError) return HttpRequestParseResult(headersResult.error);

    import std.uri : decode; // TODO: Remove dependency on phobos for this?

    return HttpRequestParseResult(ServerHttpRequest(
        httpVersion,
        addr,
        methodStr.value,
        decode(urlStr.value),
        headersResult.headers,
        inputStreamObjectFor(inputStream)
    ));
}

/**
 * Parses HTTP headers from an input stream, and returns them as an associative
 * array mapping header names to their list of values.
 * Params:
 *   inputStream = The byte input stream to read from.
 * Returns: Either the headers, or a stream error.
 */
Either!(string[][string], "headers", StreamError, "error") parseHeaders(S)(S inputStream) if (isByteInputStream!S) {
    string[][string] headers;
    while (true) {
        auto headerStr = consumeUntil(inputStream, "\r\n");
        if (headerStr.hasError) return Either!(string[][string], "headers", StreamError, "error")(headerStr.error);
        if (headerStr.value.length == 0) {
            break; // We're done parsing headers if we read an additional empty CLRF.
        } else {
            ptrdiff_t separatorIdx = indexOf(headerStr.value, ':');
            if (separatorIdx == -1) return Either!(string[][string], "headers", StreamError, "error")(
                StreamError("Invalid header field: " ~ headerStr.value)
            );
            string headerName = headerStr.value[0 .. separatorIdx];
            string headerValue = headerStr.value[separatorIdx + 1 .. $];
            if (headerName !in headers) {
                headers[headerName] = [];
            }
            headers[headerName] ~= stripSpaces(headerValue);
        }
    }
    return Either!(string[][string], "headers", StreamError, "error")(headers);
}

unittest {
    class TestHandler : HttpRequestHandler {
        void handle(ref ServerHttpRequest request, ref ServerHttpResponse response) {
            response.status = HttpStatus.OK;
            response.headers.add("Content-Type", "application/json");
            response.outputStream.writeToStream(cast(ubyte[]) "{\"a\": 1}");
        }
    }

    HttpTransport tp = new Http1Transport(new TestHandler(), 8080);
    tp.start();
}
