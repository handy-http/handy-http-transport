module handy_http_transport.interfaces;

interface HttpTransport {
    void start();
    void stop();
}

import core.thread;

/**
 * Starts a new thread to run an HTTP transport implementation in, separate
 * from the calling thread. This is useful for running a server in the
 * background, like for integration tests.
 * Params:
 *   transport = The transport implementation to start.
 * Returns: The thread that was started.
 */
Thread startInNewThread(HttpTransport transport) {
    Thread t = new Thread(() {
        transport.start();
    });
    t.start();
    return t;
}
