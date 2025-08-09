module handy_http_transport.http1.task_pool;

import std.socket;
import std.parallelism;

import handy_http_transport.http1.transport;
import handy_http_primitives;
import slf4d;

/**
 * An implementation of Http1Transport which uses D's standard library
 * parallelization, where each incoming client request is turned into a task
 * and submitted to the standard task pool.
 */
class TaskPoolHttp1Transport : Http1Transport {
    this(HttpRequestHandler requestHandler, ushort port = 8080) {
        super(requestHandler, port);
    }

    override void runServer() {
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
                auto t = task!handleClient(clientSocket, requestHandler);
                taskPool().put(t);
                trace("Added handleClient() task to the task pool.");
            } catch (SocketAcceptException e) {
                warn("Failed to accept socket connection.", e);
            }
        }
        serverSocket.close();
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
    import slf4d.default_provider;
    auto logProvider = DefaultProvider.builder().withRootLoggingLevel(Levels.DEBUG).build();
    configureLoggingProvider(logProvider);

    HttpRequestHandler handler = HttpRequestHandler.of(
        (ref ServerHttpRequest request, ref ServerHttpResponse response) {
            response.status = HttpStatus.OK;
        });
    testHttp1Transport(new TaskPoolHttp1Transport(handler));

    HttpRequestHandler handler2 = HttpRequestHandler.of(
        (ref ServerHttpRequest request, ref ServerHttpResponse response) {
            response.status = HttpStatus.OK;
            response.writeBodyString("Testing");
        });
    testHttp1Transport(new TaskPoolHttp1Transport(handler2));
}
