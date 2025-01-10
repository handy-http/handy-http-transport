# http-transport

Implementations of HTTP transport protocols, compatible with other Handy-Http components.

## HTTP/1.1

Use the `Http1Transport` implementation of `HttpTransport` to serve content
using the HTTP/1.1 protocol. See the example below:

```d
import handy_http_primitives;
import handy_http_transport;

class MyHandler : HttpRequestHandler {
    void handle(ref ServerHttpRequest req, ref Server HttpResponse resp) {
        response.status = HttpStatus.OK;
        response.headers.add("Content-Type", "text/plain");
        response.outputStream.writeToStream(cast(ubyte[]) "Hello world!");
    }
}

void main() {
    HttpTransport tp = new Http1Transport(new MyHandler(), 8080);
    tp.start();
}
```