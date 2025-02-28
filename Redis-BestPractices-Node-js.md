# Node.js

## Avoid Idle Connections

Azure Redis currently has 10 minute idle timeout for connections, which can cause short network blips if your connection has long periods of inactivity. The most common Node.js libraries should automatically reconnect.

However, you can avoid this brief connectivity loss if you use `pingInterval` in the [createClient configuration](https://github.com/redis/node-redis/blob/259e9b2e1f184d5e83413a73a88bda85de814ac0/docs/client-configuration.md#createclient-configuration) to prevent them from being idle. Some client libraries send this ping automatically.  

## Recreate the Connection

We have seen a few cases where a node_redis connection gets into a bad state and can no longer successfully send commands to Redis even though other clients are actively able to interact with Redis.  If you see connection issues that last longer than some threshold (say 30 seconds), then you may want to add logic to your app that forcefully recreates the connection instead of waiting for node_redis to reconnect.
