module handy_http_transport.response_output_stream;

import handy_http_transport.helpers : writeUIntToBuffer;
import handy_http_primitives : ServerHttpResponse;
import streams;
import slf4d;

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
     * Determines if the HTTP response headers have been flushed to the
     * underlying output stream.
     * Returns: `true` if the headers have been flushed, `false` otherwise.
     */
    bool areHeadersFlushed() const {
        return headersFlushed;
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
        if (headersFlushed) {
            return StreamResult(0); // No need to write again.
        }
        debug_("Flushing HTTP status and headers to the output stream.");
        headersFlushed = true;
        size_t idx = 0;
        char[6] statusCodeBuffer; // Normal HTTP codes are 3 digits, but this leaves room for extensions.
        writeUIntToBuffer(response.status.code, statusCodeBuffer, idx);
        // Write the status line.
        StreamResult r = outputStream.writeToStream(cast(ubyte[]) "HTTP/1.1 ");
        if (r.hasError) return r;
        size_t writeCount = r.count;
        traceF!"Wrote HTTP version. Bytes written: %d."(writeCount);
        r = outputStream.writeToStream(cast(ubyte[]) statusCodeBuffer[0..idx]);
        if (r.hasError) return r;
        writeCount += r.count;
        traceF!"Wrote status code. Bytes written: %d."(writeCount);
        r = outputStream.writeToStream([' ']);
        if (r.hasError) return r;
        writeCount += r.count;
        r = outputStream.writeToStream(cast(ubyte[]) response.status.text);
        if (r.hasError) return r;
        writeCount += r.count;
        r = outputStream.writeToStream(['\r', '\n']);
        if (r.hasError) return r;
        writeCount += r.count;
        traceF!"Wrote HTTP status line. Bytes written: %d."(writeCount);
        
        foreach (headerName; response.headers.keys) {
            // Write the header name.
            traceF!"Writing header name: %s"(headerName);
            r = outputStream.writeToStream(cast(ubyte[]) headerName);
            if (r.hasError) return r;
            writeCount += r.count;
            r = outputStream.writeToStream([':', ' ']);
            if (r.hasError) return r;
            writeCount += r.count;
            // Write the comma-separated list of values.
            string[] headerValues = response.headers.getAll(headerName);
            for (size_t i = 0; i < headerValues.length; i++) {
                r = outputStream.writeToStream(cast(ubyte[]) headerValues[i]);
                if (r.hasError) return r;
                writeCount += r.count;
                if (i + 1 < headerValues.length) {
                    r = outputStream.writeToStream([',', ' ']);
                    if (r.hasError) return r;
                    writeCount += r.count;
                }
            }
            r = outputStream.writeToStream(['\r', '\n']);
            if (r.hasError) return r;
            writeCount += r.count;
            traceF!"Wrote header %s: %s"(headerName, headerValues);
        }
        r = outputStream.writeToStream(['\r', '\n']); // Trailing CLRF before the body.
        if (r.hasError) return r;
        writeCount += r.count;
        return StreamResult(cast(uint) writeCount);
    }
}

// Test basic functionality for writing a standard response with headers and a
// body.
unittest {
    import handy_http_primitives.response;

    ArrayOutputStream!ubyte os;
    ServerHttpResponse resp;
    resp.status = HttpStatus.OK;
    resp.headers.add("Content-Type", "text/plain");
    auto httpOut = HttpResponseOutputStream!(ArrayOutputStream!ubyte*)(&os, &resp);
    resp.outputStream = outputStreamObjectFor(&httpOut);
    assert(httpOut.areHeadersFlushed() == false);
    StreamResult r = resp.outputStream.writeToStream(cast(ubyte[]) "Hello world!");
    const expectedOutput =
        "HTTP/1.1 200 OK\r\n" ~
        "Content-Type: text/plain\r\n" ~
        "\r\n" ~
        "Hello world!";
    assert(httpOut.areHeadersFlushed() == true);
    assert(os.toArray() == expectedOutput);
    assert(r.hasCount);
    assert(r.count == os.toArray().length);
}
