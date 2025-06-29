module handy_http_transport.http1.epoll;

import core.sys.posix.sys.socket;
import core.sys.linux.epoll;
import core.sys.posix.netinet.in_;
import core.sys.posix.fcntl;
import core.sys.posix.unistd;

import core.stdc.errno;

extern(C) {
    int accept4(int sockfd, sockaddr *addr, socklen_t *addrlen, int flags);
}

import handy_http_transport.interfaces;
import handy_http_transport.http1;
import handy_http_primitives;
import slf4d;

class Http1EpollTransport : Http1Transport {

    this(HttpRequestHandler requestHandler, ushort port) {
        super(requestHandler, port);
    }

    override void start() {
        super.start();
        // Create the server socket.
        enum SOCK_NONBLOCK = 0x4000;
        int listenFd = socket(AF_INET, SOCK_STREAM | SOCK_NONBLOCK, 0);
        sockaddr_in serverAddress;
        serverAddress.sin_family = AF_INET;
        serverAddress.sin_port = htons(port);
        serverAddress.sin_addr.s_addr = INADDR_ANY;

        if (bind(listenFd, cast(sockaddr*) &serverAddress, serverAddress.sizeof) == -1) {
            errorF!"Failed to bind socket: %d"(errno);
            close(listenFd);
            return;
        }

        if (listen(listenFd, SOMAXCONN) == -1) {
            errorF!"Failed to listen on socket: %d"(errno);
            close(listenFd);
            return;
        }


        int epollFd = epoll_create1(0);
        if (epollFd == -1) {
            errorF!"Failed to create epoll instance: %d"(errno);
            return;
        }

        epoll_event event;
        epoll_event[64] events;
        event.events = EPOLLIN | EPOLLET;
        event.data.fd = listenFd;
        if (epoll_ctl(epollFd, EPOLL_CTL_ADD, listenFd, &event) == -1) {
            errorF!"Failed to add listen socket to epoll: %d"(errno);
            close(listenFd);
            close(epollFd);
            return;
        }

        infoF!"Server listening on port %d."(port);

        while (true) {
            int eventCount = epoll_wait(epollFd, &event, 64, 5000);
            if (eventCount == -1) {
                errorF!"Epoll wait failed: %d"(errno);
                break;
            }

            for (int i = 0; i < eventCount; i++) {
                if (events[i].data.fd == listenFd) {
                    // New incoming connection.
                    while (true) {
                        sockaddr_in clientAddress;
                        socklen_t clientAddressLength = clientAddress.sizeof;
                        int clientFd = accept4(
                            listenFd,
                            cast(sockaddr*) &clientAddress,
                            &clientAddressLength,
                            SOCK_NONBLOCK
                        );
                        if (clientFd == -1) {
                            if (errno == EAGAIN || errno == EWOULDBLOCK) {
                                // No more connections to accept.
                                break;
                            } else {
                                errorF!"Failed to accept connection: %d"(errno);
                                break;
                            }
                        }

                        // Add the client socket to epoll's listening list.
                        event.events = EPOLLIN | EPOLLET;
                        event.data.fd = clientFd;
                        if (epoll_ctl(epollFd, EPOLL_CTL_ADD, clientFd, &event) == -1) {
                            errorF!"Failed to add client socket to epoll: %d"(errno);
                            close(clientFd);
                        }

                        infoF!"Accepted new connection from %s:%d."(
                            inet_ntoa(clientAddress.sin_addr),
                            ntohs(clientAddress.sin_port)
                        );
                    }
                } else {
                    // Event on an existing client socket.

                    int clientFd = events[i].data.fd;

                    if (events[i].events & EPOLLIN) {
                        
                    }
                }
            }
        }
    }
}