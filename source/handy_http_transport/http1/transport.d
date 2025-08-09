module handy_http_transport.http1.transport;

import std.socket;
import core.atomic : atomicStore, atomicLoad;

import handy_http_transport.interfaces;
import handy_http_transport.helpers;
import handy_http_transport.response_output_stream;

import handy_http_primitives;
import handy_http_primitives.address;

import streams;
import slf4d;

/**
 * Base class for HTTP/1.1 transport, where different subclasses can define
 * how the actual socket communication works (threadpool / epoll/ etc).
 */
abstract class Http1Transport : HttpTransport {
    protected HttpRequestHandler requestHandler;
    protected immutable ushort port;
    private bool running = false;

    this(HttpRequestHandler requestHandler, ushort port = 8080) {
        assert(requestHandler !is null);
        this.requestHandler = requestHandler;
        this.port = port;
    }

    bool isRunning() {
        return atomicLoad(running);
    }

    void start() {
        infoF!"Starting Http1Transport server on port %d."(port);
        atomicStore(running, true);
        runServer();
    }

    protected abstract void runServer();

    void stop() {
        infoF!"Stopping Http1Transport server on port %d."(port);
        atomicStore(running, false);
    }
}

version(unittest) {
    /**
     * A generic test to ensure that any Http1Transport implementation behaves
     * properly to start & stop, and process requests when running.
     *
     * It's assumed that the given transport is configured to run on localhost,
     * port 8080, and return a standard 200 OK empty response to all requests.
     * Params:
     *   transport = The transport implementation to test.
     */
    void testHttp1Transport(Http1Transport transport) {
        import core.thread;
        import std.string;
        infoF!"Testing Http1Transport implementation: %s"(transport);

        Thread thread = transport.startInNewThread();
        Thread.sleep(msecs(100));

        Socket clientSocket1 = new TcpSocket(new InternetAddress(8080));
        const requestBody = "POST /users HTTP/1.1\r\n" ~
            "Host: example.com\r\n" ~
            "Content-Type: text/plain\r\n" ~
            "Content-Length: 13\r\n" ~
            "\r\n" ~
            "Hello, world!";
        ptrdiff_t bytesSent = clientSocket1.send(requestBody);
        assert(bytesSent == requestBody.length, "Couldn't send the full request body to the server.");

        ubyte[8192] buffer;
        size_t totalBytesReceived = 0;
        ptrdiff_t bytesReceived;
        do {
            bytesReceived = clientSocket1.receive(buffer[totalBytesReceived .. $]);
            if (bytesReceived == Socket.ERROR) {
                assert(false, "Socket error when attempting to receive a response from the HttpTransport server.");
            }
            totalBytesReceived += bytesReceived;
        } while (bytesReceived > 0);
         
        string httpResponseContent = cast(string) buffer[0 .. totalBytesReceived];
        string[] parts = httpResponseContent.split("\r\n\r\n");
        assert(parts.length > 0, "HTTP 1.1 response is missing required status and headers section:\n\n" ~ httpResponseContent);
        string[] headerLines = parts[0].split("\r\n");
        assert(headerLines.length > 0, "HTTP 1.1 response is missing required status line.");
        string statusLine = headerLines[0];
        string[] statusLineParts = statusLine.split(" ");
        assert(statusLineParts[0] == "HTTP/1.1");
        assert(
            statusLineParts[1] == "200",
            format!"Expected status line's HTTP code to be 200, but it was \"%s\"."(statusLineParts[1])
        );
        assert(statusLineParts[2] == "OK");

        info("Testing is complete. Stopping the server.");
        transport.stop();
        thread.join();
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
    SocketInputStream* inputStream = new SocketInputStream(clientSocket);
    BufferedInputStream!(SocketInputStream*, 8192)* bufferedInput
        = new BufferedInputStream!(SocketInputStream*, 8192)(inputStream);
    // Get remote address from the socket.
    import handy_http_primitives.address;
    ClientAddress addr = getAddress(clientSocket);
    traceF!"Got request from client: %s"(addr.toString());
    auto result = readHttpRequest(bufferedInput, addr);
    if (result.hasError) {
        if (result.error.code != -1) {
            // Only warn if we didn't read an empty request.
            warnF!"Failed to read request: %s"(result.error.message);
        }
        inputStream.closeStream();
        return;
    }
    scope ServerHttpRequest request = result.request;
    scope ServerHttpResponse response;
    SocketOutputStream* outputStream = new SocketOutputStream(clientSocket);
    HttpResponseOutputStream!(SocketOutputStream*) responseOutputStream
        = HttpResponseOutputStream!(SocketOutputStream*)(
            outputStream,
            &response
        );
    response.outputStream = outputStreamObjectFor(&responseOutputStream);
    try {
        requestHandler.handle(request, response);
        debugF!"%s %s -> %d %s"(request.method, request.url, response.status.code, response.status.text);
        // If the response's headers aren't flushed yet, write them now.
        if (!responseOutputStream.areHeadersFlushed()) {
            trace("Flushing response headers because they weren't flushed by the request handler.");
            auto writeResult = responseOutputStream.writeHeaders();
            if (writeResult.hasError) {
                errorF!"Failed to write response headers: %s"(writeResult.error.message);
            }
        }
    } catch (Exception e) {
        error("Exception thrown while handling request.", e);
    } catch (Throwable t) {
        errorF!"Throwable error while handling request: %s"(t.msg);
        throw t;
    }
    
    if (response.status != HttpStatus.SWITCHING_PROTOCOLS) {
        inputStream.closeStream();
    }
}

// Test case where we use a local socket pair to test the full handleClient
// workflow from the HttpRequestHandler's point of view.
unittest {
    Socket[2] sockets = socketPair();
    Socket clientSocket = sockets[0];
    Socket serverSocket = sockets[1];
    const requestContent =
        "POST /data HTTP/1.1\r\n" ~
        "Content-Type: application/json\r\n" ~
        "Content-Length: 22\r\n" ~
        "\r\n" ~
        "{\"x\": 5, \"flag\": true}";
    clientSocket.send(cast(ubyte[]) requestContent);
    
    class TestHandler : HttpRequestHandler {
        import std.conv;

        void handle(ref ServerHttpRequest request, ref ServerHttpResponse response) {
            assert(request.headers["Content-Type"] == ["application/json"]);
            assert("Content-Length" in request.headers && request.headers["Content-Length"].length > 0);
            ulong contentLength = request.headers["Content-Length"][0].to!ulong;
            assert(contentLength == 22);
            ubyte[22] bodyBuffer;
            auto readResult = request.inputStream.readFromStream(bodyBuffer);
            assert(readResult.hasCount && readResult.count == 22);
            assert(cast(string) bodyBuffer == "{\"x\": 5, \"flag\": true}");
        }
    }
    handleClient(serverSocket, new TestHandler());
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
    if (methodStr.hasError) {
        if (methodStr.error.code == 0) {
            // Set a custom code to indicate an empty request.
            return HttpRequestParseResult(StreamError(methodStr.error.message, -1));
        }
        return HttpRequestParseResult(methodStr.error);
    }

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

    auto queryParams = parseQueryParameters(urlStr.value);

    import std.uri : decode; // TODO: Remove dependency on phobos for this?

    return HttpRequestParseResult(ServerHttpRequest(
        httpVersion,
        addr,
        methodStr.value,
        decode(urlStr.value),
        headersResult.headers,
        queryParams,
        inputStreamObjectFor(inputStream)
    ));
}

unittest {
    import streams;

    auto makeStream(string text) {
        return arrayInputStreamFor(cast(ubyte[]) text);
    }

    // Basic HTTP request.
    ArrayInputStream!ubyte s1 = makeStream(
        "GET /test?x=5 HTTP/1.1\r\n" ~
        "Accept: text/plain\r\n" ~
        "\r\n"
    );
    auto r1 = readHttpRequest(&s1, ClientAddress.unknown());
    assert(r1.hasRequest);
    assert(r1.request.httpVersion == HttpVersion.V1);
    assert(r1.request.method == HttpMethod.GET);
    assert(r1.request.url == "/test?x=5");
    const r1ExpectedHeaders = ["Accept": ["text/plain"]];
    assert(r1.request.headers == r1ExpectedHeaders);
    assert(r1.request.clientAddress == ClientAddress.unknown());

    // POST request with body. Test that the body is read correctly.
    ArrayInputStream!ubyte s2 = makeStream(
        "POST /data HTTP/1.1\r\n" ~
        "Content-Type: text/plain\r\n" ~
        "Content-Length: 12\r\n" ~
        "\r\n" ~
        "Hello world!"
    );
    auto r2 = readHttpRequest(&s2, ClientAddress.unknown());
    assert(r2.hasRequest);
    assert(r2.request.method == HttpMethod.POST);
    ubyte[12] r2BodyBuffer;
    StreamResult r2BodyReadResult = s2.readFromStream(r2BodyBuffer);
    assert(r2BodyReadResult.count == 12);
    assert(cast(string) r2BodyBuffer == "Hello world!");
}

/**
 * Parses HTTP headers from an input stream, and returns them as an associative
 * array mapping header names to their list of values.
 * Params:
 *   inputStream = The byte input stream to read from. Note that this stream
 *                 should be passed as a pointer / reference, values will be
 *                 consumed from the stream.
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
    import streams;

    auto makeStream(string text) {
        return arrayInputStreamFor(cast(ubyte[]) text);
    }

    // Basic valid headers.
    auto s1 = makeStream("Content-Type: application/json\r\n\r\n");
    auto r1 = parseHeaders(&s1);
    assert(r1.hasHeaders);
    assert("Content-Type" in r1.headers);
    assert(r1.headers["Content-Type"] == ["application/json"]);

    // Multiple headers.
    auto s2 = makeStream("Accept: text, json, image\r\nContent-Length: 1234\r\n\r\n");
    auto r2 = parseHeaders(&s2);
    assert(r2.hasHeaders);
    assert("Accept" in r2.headers);
    assert(r2.headers["Accept"] == ["text, json, image"]);
    assert(r2.headers["Content-Length"] == ["1234"]);

    // Basic invalid header string.
    auto s3 = makeStream("Invalid headers");
    auto r3 = parseHeaders(&s3);
    assert(r3.hasError);
    
    // No trailing \r\n
    auto s4 = makeStream("Content-Type: application/json");
    auto r4 = parseHeaders(&s4);
    assert(r4.hasError);

    // Empty headers.
    auto s5 = makeStream("\r\n");
    auto r5 = parseHeaders(&s5);
    assert(r5.hasHeaders);
    assert(r5.headers.length == 0);
}
