module handy_http_transport.http1.task_pool;

import std.socket;
import std.parallelism;

import handy_http_transport.http1.transport;
import handy_http_primitives;
import slf4d;

/**
 * Configuration options to provide when creating a new Http1Transport
 * instance.
 */
struct Http1TransportConfig {
    /// The host address to bind to.
    string host;
    /// The port to bind to.
    ushort port;
    /// The number of workers to use in the task pool.
    size_t workerCount;
}

/**
 * Defines the default configuration options if none are provided. They are:
 * * Host address 127.0.0.1
 * * Port 8080
 * * Worker count of 5.
 * Returns: The default configuration.
 */
Http1TransportConfig defaultConfig() {
    return Http1TransportConfig(
        "127.0.0.1",
        8080,
        5
    );
}

/**
 * An implementation of Http1Transport which uses D's standard library
 * parallelization, where each incoming client request is turned into a task
 * and submitted to the standard task pool.
 */
class TaskPoolHttp1Transport : Http1Transport {
    private TaskPool httpTaskPool;
    private immutable Http1TransportConfig config;

    /**
     * Creates a new transport instance using a std.parallelism TaskPool for
     * handling requests.
     * Params:
     *   requestHandler = The handler to call for each incoming request.
     *   workerCount = The number of workers to use in the task pool.
     *   port = The port.
     */
    this(HttpRequestHandler requestHandler, in Http1TransportConfig config = defaultConfig()) {
        super(requestHandler, config.port);
        this.config = config;
        this.httpTaskPool = new TaskPool(config.workerCount);
    }

    override void runServer() {
        Socket serverSocket = new TcpSocket();
        serverSocket.setOption(SocketOptionLevel.SOCKET, SocketOption.REUSEADDR, 1);
        serverSocket.bind(parseAddress(config.host, config.port));
        debugF!"Bound the server socket to %s"(serverSocket.localAddress);
        serverSocket.listen(1024);
        debug_("Server is now listening.");

        while (super.isRunning) {
            try {
                trace("Waiting to accept a new socket.");
                Socket clientSocket = serverSocket.accept();
                trace("Accepted a new socket.");
                auto t = task!handleClient(clientSocket, requestHandler);
                this.httpTaskPool.put(t);
                trace("Added handleClient() task to the task pool.");
            } catch (SocketAcceptException e) {
                warn("Failed to accept socket connection.", e);
            }
        }
        serverSocket.close();
        this.httpTaskPool.stop();
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
