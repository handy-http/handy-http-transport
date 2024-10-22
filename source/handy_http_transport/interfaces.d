module handy_http_transport.interfaces;

import core.thread.osthread;

import handy_http_primitives;

abstract class HttpTransport {
    protected HttpRequestAcceptor requestAcceptor;
    this(HttpRequestAcceptor requestAcceptor) {
        this.requestAcceptor = requestAcceptor;
    }

    abstract void start();

    Thread startInThread() {
        Thread t = new Thread(&this.start);
        t.start();
        return t;
    }
}

interface HttpRequestAcceptor {
    void accept(HttpRequest request, HttpResponse response);
}
