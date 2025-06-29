/+ dub.sdl:
    dependency "handy-http-transport" path="../../"
+/
module integration_tests.http1_speed_test;

import handy_http_primitives;
import handy_http_transport;
import slf4d;
import slf4d.default_provider;

void main() {
    auto loggingProvider = DefaultProvider.builder()
        .withRootLoggingLevel(Levels.ERROR)
        .withConsoleSerializer(true, 48)
        .build();
    configureLoggingProvider(loggingProvider);
    HttpTransport transport;
    transport = new TaskPoolHttp1Transport(HttpRequestHandler.of(
        (ref ServerHttpRequest request, ref ServerHttpResponse response) {
            if (request.method == HttpMethod.DELETE) {
                transport.stop();
            }
            response.headers.add("Content-Type", "text/plain");
            response.headers.add("Content-Length", "13");
            response.outputStream.writeToStream(cast(ubyte[]) "Hello, world!");
        }));
    transport.start();
}
