# Node.js

## Avoid Idle Connections

Azure Redis closes idle connections after 10 minutes, which can cause disruption for client applications that want to keep their Redis connections open but may have long periods without Redis activity. To keep the connection open, you can configure your client library to automatically send periodic commands to Redis. For example with node-redis you can set the `pingInterval` to something like 60000 milliseconds in the [createClient configuration](https://github.com/redis/node-redis/blob/259e9b2e1f184d5e83413a73a88bda85de814ac0/docs/client-configuration.md#createclient-configuration)

## Recreate the Connection

We have seen a few cases where a node_redis connection gets into a bad state and can no longer successfully send commands to Redis even though other clients are actively able to interact with Redis.  If you see connection issues that last longer than some threshold (say 30 seconds), then you may want to add logic to your app that forcefully recreates the connection instead of waiting for node_redis to reconnect.
