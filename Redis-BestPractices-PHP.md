## PHP 
### Reuse Connections
The most common problem we have seen with PHP clients is that they either don't support persistent connections or the ability to reuse connections is disabled by default.  When you don't reuse connections, it means that you have to pay the cost of establishing a new connection, including the SSL/TLS handshake, each time you want to send a request.  This can add a lot of latency to your request time and will manifest itself as a performance problem in your application.  Additionally, if you have a high request rate, this can cause significant CPU churn on both the Redis client-side and server-side, which can result in other issues.

As an example, the [Predis Redis client](https://github.com/nrk/predis/) has a [`"persistent"` connection property](https://github.com/nrk/predis/wiki/Connection-Parameters) that is **false by default**.  Setting the `"persistent"` property to *true* will should improve behavior drastically.

