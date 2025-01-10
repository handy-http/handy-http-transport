module handy_http_transport.http1.transport;

import std.socket;

import handy_http_transport.interfaces;
import handy_http_primitives;

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
    auto result = readHttpRequest(&bufferedInput);
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

/// Alias for the result of the `readHttpRequest` function which parses HTTP requests.
alias HttpRequestParseResult = Either!(ServerHttpRequest, "request", StreamError, "error");

/**
 * Parses an HTTP/1.1 request from a byte input stream.
 * Params:
 *   inputStream = The byte input stream to read from.
 * Returns: Either the request which was parsed, or a stream error.
 */
HttpRequestParseResult readHttpRequest(S)(S inputStream) if (isByteInputStream!S) {
    import handy_http_primitives.address;

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

    return HttpRequestParseResult(ServerHttpRequest(
        httpVersion,
        ClientAddress.init, // TODO: Get this from the socket, if possible?
        methodStr.value,
        urlStr.value,
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

/**
 * Helper function to consume string content from an input stream until a
 * certain target pattern of characters is encountered.
 * Params:
 *   inputStream = The stream to read from.
 *   target = The target at which to stop reading.
 * Returns: The string that was read, or a stream error.
 */
private Either!(string, "value", StreamError, "error") consumeUntil(S)(
    S inputStream,
    string target
) if (isByteInputStream!S) {
    ubyte[1024] buffer;
    size_t idx;
    while (true) {
        auto result = inputStream.readFromStream(buffer[idx .. idx + 1]);
        if (result.hasError) return Either!(string, "value", StreamError, "error")(result.error);
        if (result.count != 1) return Either!(string, "value", StreamError, "error")(
            StreamError("Failed to read a single element", 1)
        );
        idx++;
        if (idx >= target.length && buffer[idx - target.length .. idx] == target) {
            return Either!(string, "value", StreamError, "error")(
                cast(string) buffer[0 .. idx - target.length].idup
            );
        }
        if (idx >= buffer.length) {
            return Either!(string, "value", StreamError, "error")(
                StreamError("Couldn't find target \"" ~ target ~ "\" after reading 1024 bytes.", 1)
            );
        }
    }
}

/**
 * Internal helper function to get the first index of a character in a string.
 * Params:
 *   s = The string to look in.
 *   c = The character to look for.
 *   offset = An optional offset to look from.
 * Returns: The index of the character, or -1.
 */
private ptrdiff_t indexOf(string s, char c, size_t offset = 0) {
    for (size_t i = offset; i < s.length; i++) {
        if (s[i] == c) return i;
    }
    return -1;
}

/**
 * Internal helper function that returns the slice of a string excluding any
 * preceding or trailing spaces.
 * Params:
 *   s = The string to strip.
 * Returns: The slice of the string that has been stripped.
 */
private string stripSpaces(string s) {
    if (s.length == 0) return s;
    ptrdiff_t startIdx = 0;
    while (s[startIdx] == ' ' && startIdx < s.length) startIdx++;
    s = s[startIdx .. $];
    ptrdiff_t endIdx = s.length - 1;
    while (s[endIdx] == ' ' && endIdx >= 0) endIdx--;
    return s[0 .. endIdx + 1];
}

/**
 * Helper function to append an unsigned integer value to a char buffer. It is
 * assumed that there's enough space to write the value.
 * Params:
 *   value = The value to append.
 *   buffer = The buffer to append to.
 *   idx = A reference to a variable tracking the next writable index in the buffer.
 */
private void writeUIntToBuffer(uint value, char[] buffer, ref size_t idx) {
    const size_t startIdx = idx;
    while (true) {
        ubyte remainder = value % 10;
        value /= 10;
        buffer[idx++] = cast(char) ('0' + remainder);
        if (value == 0) break;
    }
    // Swap the characters to proper order.
    for (size_t i = 0; i < (idx - startIdx) / 2; i++) {
        size_t p1 = i + startIdx;
        size_t p2 = idx - i - 1;
        char tmp = buffer[p1];
        buffer[p1] = buffer[p2];
        buffer[p2] = tmp;
    }
}

/**
 * A wrapper around a byte output stream that's used for writing HTTP response
 * content. It keeps a reference to the `ServerHttpResponse` so that when a
 * handler writes data to the stream, it'll flush the HTTP response status and
 * headers beforehand.
 */
struct HttpResponseOutputStream(S) if (isByteOutputStream!S) {
    /// The underlying output stream to write to.
    private S outputStream;
    /// A pointer to the HTTP response that this stream is for.
    private ServerHttpResponse* response;
    /// Flag that keeps track of if the HTTP status and headers were written.
    private bool headersFlushed = false;

    this(S outputStream, ServerHttpResponse* response) {
        this.outputStream = outputStream;
        this.response = response;
    }

    /**
     * Writes the given data to the stream. If the referenced HTTP response's
     * status and headers haven't yet been written, they will be written first.
     * Params:
     *   buffer = The buffer containing data to write.
     * Returns: The result of writing. If status and headers are written, the
     * number of bytes written will include that in addition to the buffer size.
     */
    StreamResult writeToStream(ubyte[] buffer) {
        uint bytesWritten = 0;
        if (!headersFlushed) {
            auto result = writeHeaders();
            if (result.hasError) return result;
            bytesWritten += result.count;
            headersFlushed = true;
        }
        auto result = outputStream.writeToStream(buffer);
        if (result.hasError) return result;
        return StreamResult(result.count + bytesWritten);
    }

    /**
     * Writes HTTP/1.1 status line and headers to the underlying output stream,
     * which is done before any body content can be written.
     * Returns: The stream result of writing.
     */
    StreamResult writeHeaders() {
        // TODO: Come up with a better way of writing headers than string concatenation.
        size_t idx = 0;
        char[6] statusCodeBuffer; // Normal HTTP codes are 3 digits, but this leaves room for extensions.
        writeUIntToBuffer(response.status.code, statusCodeBuffer, idx);

        string statusAndHeaders = "HTTP/1.1 "
            ~ cast(string) statusCodeBuffer[0..idx]
            ~ " " ~ response.status.text
            ~ "\r\n";
        foreach (headerName; response.headers.keys) {
            string headerLine = headerName ~ ": ";
            string[] headerValues = response.headers.getAll(headerName);
            for (size_t i = 0; i < headerValues.length; i++) {
                headerLine ~= headerValues[i];
                if (i + 1 < headerValues.length) {
                    headerLine ~= ", ";
                }
            }
            headerLine ~= "\r\n";
            statusAndHeaders ~= headerLine;
        }
        statusAndHeaders ~= "\r\n"; // Trailing CLRF before the body.
        return outputStream.writeToStream(cast(ubyte[]) statusAndHeaders);
    }
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
