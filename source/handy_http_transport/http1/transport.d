module handy_http_transport.http1.transport;

import std.socket;

import handy_http_transport.interfaces;
import handy_http_primitives;

/**
 * The HTTP/1.1 transport protocol implementation.
 */
class Http1Transport : HttpTransport {
    private Socket serverSocket;
    private SocketSet socketSet;

    this(HttpRequestAcceptor requestAcceptor) {
        super(requestAcceptor);
        this.serverSocket = new TcpSocket();
    }

    void start() {
        serverSocket.bind(new InternetAddress("127.0.0.1", 8080));
        while (true) {
            uint socketCount = 0;
        }
    }
}