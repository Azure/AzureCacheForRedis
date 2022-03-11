# Azure Cache for Redis Server Maintenance Notifications

## Overview

Maintenance notifications give your Redis client application some visibility into maintenance events impacting the Redis cache it's connected to. Maintenance is a routine part of any managed service, including Azure Cache for Redis. In a Redis cache, maintenance operations will take a primary or replica node within a cache offline temporarily. For a Standard or Premium tier cache, this will *not* cause downtime, but may cause connection failovers. In that case the impacted node will close its client connections before going offline, so the client can reconnect to its partner node which is staying online. Most Redis client libraries will handle the reconnection automatically, but there may be a few seconds of connection instability during the failover. That instability can cause transient Redis command failures, which can be avoided (or anticipated) by subscribing to maintenance notifications. 

Maintenance notifications are not intended to give hours or days of advance notice of upcoming maintenance. They're suitable for triggering actions within your Redis client application, rather than firing an alert that a person can respond to manually before the maintenance occurs. 

Notifications are delivered to client applications via a standard [Redis pub/sub](https://redis.io/topics/pubsub) channel. Most Redis client libraries support subscribing to pub/sub channels, so the notifications can be easily consumed in any client application with a connection to the cache. Notifications aren't available through any other mechanism outside of a Redis client application. 

## Applicable Scenarios

Maintenance notifications are for applications with strict requirements for performance and latency, which need to take action whenever maintenance is planned for the Redis server. For example, an application might open a circuit breaker to route traffic away from the cache during the maintenance operation, and instead send requests directly to a persistent store.

In most cases, client applications don't need to handle maintenance notifications directly. Instead, we recommend implementing these best practices to detect and handle all types of transient connection loss: [Building in resilience](https://docs.microsoft.com/azure/azure-cache-for-redis/cache-failover#build-in-resiliency). It's always possible that your application will lose its connection with the cache for reasons other than server maintenance, so notifications can't be relied upon as the only indication of connection loss. 

### We only recommend subscribing to maintenance notifications in a few noteworthy cases:

* Applications with extreme performance or latency requirements, where even minor delays must be avoided. For such cases, traffic could be rerouted to a backup cache or another store before maintenance begins on the current cache.
* Applications that explicitly read data from replica rather than primary nodes. Maintenace will take replica nodes offline for a few minutes, so applications may need to temporarily switch to read data from primary nodes.
* Applications that can't risk write operations failing silently or succeeding without confirmation, which can happen as connections are being closed for maintenance. If those cases would result in dangerous data loss or corruption, the application can proactively pause or redirect write commands *before* the maintenance is scheduled to begin.

## Types of notifications
Each notification from the AzureRedisEvents channel has a type, and includes details about the node being impacted.

`NodeMaintenanceScheduled` is sent when infrastructure maintenance scheduled by Azure, up to 15 minutes in advance. This notification will not be fired for user-initiated reboots, or for monthly patching. 

`NodeMaintenanceStarting` is sent ~20 seconds before maintenance occurs. 

`NodeMaintenanceStart` is sent when maintenance is imminent (within seconds). These notifications do not include a `StartTimeInUTC` because they are fired immediately before maintenance occurs.

`NodeMaintenanceFailoverComplete` is sent when a replica node has promoted itself to primary, and do not include a `StartTimeInUTC` because the failover has already occurred. This notification will only be sent when maintenance is impacting a primary node. Maintenance on replica nodes does not trigger a failover.

StackExchange.Redis v2.2.79+ automatically refreshes its view of the cluster topology in response to this notification, to avoid sending commands to the wrong node. We recommend that applications using other client libraries implement logic to do the same. 

`NodeMaintenanceEnded` indicates that the maintenance operation has completed and that all cache nodes once again available. You do *NOT* need to wait for this notification to use the load balancer endpoint, as it is available throughout. However, we included this for logging purposes and for customers who use the replica endpoint in clusters for read workloads. 

## Subscribing to the channel

For .NET client applications, we recommend using the StackExchange.Redis library. It will automatically subscribe to the AzureRedisEvents pub/sub channel and raise a `ConnectionMultiplexer.ServerMaintenanceEvent` in response to each maintenance notification. For more information, see the [StackExchange.Redis documentation](https://github.com/StackExchange/StackExchange.Redis/blob/main/docs/ServerMaintenanceEvent.md).

For other client libraries, you will need to [subscribe](https://redis.io/commands/SUBSCRIBE) to the AzureRedisEvents [pub/sub](https://redis.io/topics/pubsub) channel and implement logic to parse incoming notification messages. For an example of how to parse the messages, see the StackExchange.Redis implementation here: [AzureMaintenanceEvent.cs](https://github.com/StackExchange/StackExchange.Redis/blob/main/src/StackExchange.Redis/Maintenance/AzureMaintenanceEvent.cs)

## Notification message format

Notifications sent by Azure Redis are pipe (|) delimited strings. All messages start with a FieldName followed by the Entry for the field, followed by additional pairs of field names and entries.

```
NotificationType|{NotificationType}|StartTimeInUTC|{StartTimeInUTC}|IsReplica|{IsReplica}|IPAddress|{IPAddress}|SSLPort|{SSLPort}|NonSSLPort|{NonSSLPort}
```

## Example sequence of events

1. Client application is connected to the Redis cache and everything is functioning normally.
2. Current Time: [16:21:39] -> `NodeMaintenanceScheduled` message is received, with a `StartTimeInUTC` of 16:35:57 (about 14 minutes from current time).
    * Note: the start time is an approximation, because the cache prepares for maintenance in advance, and may take the node offline up to 3 minutes before maintenance is scheduled. We recommend listening for `NodeMaintenanceStarting` and `NodeMaintenanceStart` for more precise timing. Start times in those notifications will only be off by a few seconds at most.
3. Current Time: [16:34:26] -> `NodeMaintenanceStarting` message is received, and `StartTimeInUTC` is 16:34:46, about 20 seconds from the current time.
4. Current Time: [16:34:46] -> `NodeMaintenanceStart` message is received, so we know the node maintenance is about to happen. We break the circuit and stop sending new operations to the Redis connection. (Note: the appropriate action for your application may be different.)
5. Current Time: [16:34:47] -> The connection is closed by the Redis server.
6. Current Time: [16:34:56] -> `NodeMaintenanceFailoverComplete` message is received. This tells us that the replica node has promoted itself to primary, so the other node can go offline for maintenance. Note that this message will only be fired if the primary is undergoing maintenance, as replica node maintenance does not result in failover.
7. Current Time [16:34:56] -> The connection to the Redis server is restored. It is safe to send commands again to the connection and all commands will succeed.
8. Current Time [16:37:48] -> `NodeMaintenanceEnded` message is received, with a `StartTimeInUTC` of 16:37:48. Nothing to do here if you are talking to the load balancer endpoint (port 6380 or 6379). For clustered servers, you can resume sending readonly workloads to the replica(s).
