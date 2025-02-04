# Node.js

## Avoid Idle Connections

Azure Redis currently has 10 minute idle timeout for connections, which will cause short network blips if your connection has long periods of inactivity.  The most common Node.js libraries should automatically reconnect.  

However, you can avoid this brief connectivity loss if your application sends a [PING command](http://redis.io/commands/ping) on connections to prevent them from being idle.  Some client libraries send this ping automatically.  

At the time of this writing, the node.js redis client library I tested (node_redis) did NOT do this automatically.  You can do this yourself by adding a timer that sends PING command every minute or two.  Below is an example of how to do this.  

```Node.js
    setInterval(function(){
     console.log('redisClient => Sending Ping...');
     redisClient.ping();
    }, 60000); // 60 seconds
```

## Recreate the Connection

We have seen a few cases where a node_redis connection gets into a bad state and can no longer successfully send commands to Redis even though other clients are actively able to interact with Redis.  If you see connection issues that last longer than some threshold (say 30 seconds), then you may want to add logic to your app that forcefully recreates the connection instead of waiting for node_redis to reconnect.
