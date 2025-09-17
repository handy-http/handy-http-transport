module handy_http_transport.http1.photon;

import handy_http_transport.http1.transport;
import handy_http_primitives;
import slf4d;

import photon;
import std.socket;

/** 
 * An implementation of Http1Transport which uses Dimitry Olshansky's Photon
 * library for asynchronous task processing. A main fiber is started which
 * accepts incoming client sockets, and a fiber is spawned for each client so
 * its request can be handled asynchronously.
 */
class PhotonHttp1Transport : Http1Transport {
    this(HttpRequestHandler handler, ushort port = 8080) {
        super(handler, port);
    }

    override void runServer() {
        initPhoton();
        go(() {
            Socket serverSocket = new TcpSocket();
            serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
            serverSocket.bind(parseAddress("127.0.0.1", port));
            debugF!"Bound the server socket to %s"(serverSocket.localAddress);
            serverSocket.listen(1024);
            debug_("Server is now listening.");

            while (super.isRunning) {
                try {
                    trace("Waiting to accept a new socket.");
                    Socket clientSocket = serverSocket.accept();
                    trace("Accepted a new socket.");
                    go(() => handleClient(clientSocket, requestHandler));
                    trace("Added handleClient() task to the task pool.");
                } catch (SocketAcceptException e) {
                    warn("Failed to accept socket connection.", e);
                }
            }
            serverSocket.close();
        });
        runScheduler();
    }

    override void stop() {
        super.stop();
        // Send a dummy request to cause the server's blocking accept() call to end.
        try {
            Socket dummySocket = new TcpSocket(new InternetAddress("127.0.0.1", port));
            dummySocket.shutdown(SocketShutdown.BOTH);
            dummySocket.close();
        } catch (SocketOSException e) {
            warn("Failed to send empty request to stop server.", e);
        }
    }
}

unittest {
    testHttp1Transport(new PhotonHttp1Transport(
        HttpRequestHandler.of((req, resp) {
            resp.status = HttpStatus.OK;
        }),
        8080
    ));
}