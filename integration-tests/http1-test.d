/+ dub.sdl:
    dependency "handy-http-transport" path="../"
    dependency "requests" version="~>2.1"
+/

/**
 * This tests the basic HTTP functionality of the Http1Transport implementation
 * by starting a server, sending a request, and checking the response.
 */
module integration_tests.http1_test;

import handy_http_primitives;
import handy_http_transport;
import slf4d;
import slf4d.default_provider;
import requests;

import core.thread;

int main() {
    auto loggingProvider = DefaultProvider.builder()
        .withRootLoggingLevel(Levels.INFO)
        .withConsoleSerializer(true, 48)
        .build();
    configureLoggingProvider(loggingProvider);

    HttpTransport transport = new Http1Transport(HttpRequestHandler.of((ref ServerHttpRequest request, ref ServerHttpResponse response) {
        response.headers.add("Content-Type", "text/plain");
        response.headers.add("Content-Length", "13");
        response.outputStream.writeToStream(cast(ubyte[]) "Hello, world!");
    }));
    Thread thread = transport.startInNewThread();
    scope(exit) {
        transport.stop();
        thread.join();
    }
    info("Started server in another thread.");
    Thread.sleep(msecs(100)); // Wait for the server to start.

    // Send a simple GET request to the server.
    auto content = getContent("http://localhost:8080");
    ubyte[] data = content.data;
    if (data.length != 13 || (cast(string) data) != "Hello, world!") {
        error("Received unexpected content: " ~ cast(string) data);
        return 1;
    }

    info("Test completed successfully.");
    return 0;
}
