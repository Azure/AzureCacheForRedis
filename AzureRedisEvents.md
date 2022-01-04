# Azure Cache for Redis Server Maintenance Events

## Overview

Maintenance events are for applications with high performance requirements, which need to take advanced action (such as using circuit breakers to bypass the cache) whenever maintenance is planned for the Redis server. For example, an application might route traffic away from the cache during the maintenance operation, and instead send it directly to a persistent store.

In most cases, your application doesn't need to subscribe to AzureRedisEvents or respond to notifications. Instead, we recommend implementing [building in resilience](https://docs.microsoft.com/en-us/azure/azure-cache-for-redis/cache-failover#build-in-resiliency).

With sufficient resilience, applications gracefully handle any brief connection loss or cache unavailability like that experienced during node maintenance. It’s also possible that your application might unexpectedly lose its connection to the cache without warning from AzureRedisEvents because of network errors or other events.

The AzureRedisEvents channel isn't a mechanism that can notify you days or hours in advance. Maintenance events aren't intended to allow time for a person to be alerted and take manual action, and most of them will be fired within minutes or seconds of maintenance.

We only recommend subscribing to AzureRedisEvents in a few noteworthy cases:

* Applications with extreme performance requirements, where even minor delays must be avoided. In such scenarios, traffic could be seamlessly rerouted to a backup cache before maintenance begins on the current cache.
* Applications that explicitly read data from replica rather than primary nodes. During maintenance on a replica node, the application could temporarily switch to read data from primary nodes.
* Applications that can't risk write operations failing silently or succeeding without confirmation, which can happen as connections are being closed for maintenance. If those cases would result in dangerous data loss, the application can proactively pause or redirect write commands before the maintenance is scheduled to begin.

## Types of events

AzureRedisEvents currently sends the following notifications:
* `NodeMaintenanceScheduled`: Indicates that a maintenance event is scheduled. Usually between 10-15 minutes in advance.
* `NodeMaintenanceStarting`: Fired ~20s before maintenance begins
* `NodeMaintenanceStart`: Fired when maintenance is imminent (<5s)
* `NodeMaintenanceFailoverComplete`: Indicates that a replica has been promoted to primary
* `NodeMaintenanceEnded`: Indicates that the node maintenance operation is over

## Subscribing to the channel

If you are using C#, we recommend relying on the StackExchange.Redis library. It will automatically subscribe to the pub/sub channel and raise the ServerMaintenanceEvent in response to maintenance. For more information, please see the [StackExchange.Redis documentation](https://github.com/StackExchange/StackExchange.Redis/blob/main/docs/ServerMaintenanceEvent.md).

For other client libraries, you will need to subscribe to the AzureRedisEvents pub/sub channel and implement logic to parse incoming maintenance event messages.

## Message format

Messages sent by Azure Redis are pipe (|) delimited strings. All messages start with a FieldName followed by the Entry for the field, followed by additional pairs of field names and entries.

---
    NotificationType|{NotificationType}|StartTimeInUTC|{StartTimeInUTC}|IsReplica|{IsReplica}|IPAddress|{IPAddress}|SSLPort|{SSLPort}|NonSSLPort|{NonSSLPort}
---

## Walking through a sample maintenance event

1. App is connected to Redis and everything is functioning normally.
2. Current Time: [16:21:39] -> `NodeMaintenanceScheduled` message is received, with a `StartTimeInUTC` of 16:35:57 (about 14 minutes from current time).
    * Note: the start time for this event is an approximation, because we will start getting ready for the update proactively and the node may become unavailable up to 3 minutes sooner. We recommend listening for `NodeMaintenanceStarting` and `NodeMaintenanceStart` for the highest level of accuracy (these are only likely to differ by a few seconds at most).
3. Current Time: [16:34:26] -> `NodeMaintenanceStarting` message is received, and `StartTimeInUTC` is 16:34:46, about 20 seconds from the current time.
4. Current Time: [16:34:46] -> `NodeMaintenanceStart` message is received, so we know the node maintenance is about to happen. We break the circuit and stop sending new operations to the Redis connection. (Note: the appropriate action for your application may be different.)
5. Current Time: [16:34:47] -> The connection is closed by the Redis server.
6. Current Time: [16:34:56] -> `NodeMaintenanceFailoverComplete` message is received. This tells us that the replica node has promoted itself to primary, so the other node can go offline for maintenance. Note that this message will only be fired if the primary is undergoing maintenance, as replica node maintenance does not result in failover.
7. Current Time [16:34:56] -> The connection to the Redis server is restored. It is safe to send commands again to the connection and all commands will succeed.
8. Current Time [16:37:48] -> `NodeMaintenanceEnded` message is received, with a `StartTimeInUTC` of 16:37:48. Nothing to do here if you are talking to the load balancer endpoint (port 6380 or 6379). For clustered servers, you can resume sending readonly workloads to the replica(s).


##  Event details

#### NodeMaintenanceScheduled event

`NodeMaintenanceScheduled` events are raised for infrastructure maintenance scheduled by Azure, up to 15 minutes in advance. This event will not be fired for user-initiated reboots, or for monthly patching.

#### NodeMaintenanceStarting event

`NodeMaintenanceStarting` events are raised ~20 seconds ahead of upcoming maintenance. This means that one of the primary or replica nodes will be going down for maintenance.

It's important to understand that this does *not* mean downtime if you are using a Standard/Premier SKU cache. If the replica is targeted for maintenance, disruptions should be minimal. If the primary node is the one going down for maintenance, a failover will occur, which will close existing connections going through the load balancer port (6380/6379) or directly to the node (15000/15001). You may want to pause sending write commands until the replica node has assumed the primary role and the failover is complete.

#### NodeMaintenanceStart event

`NodeMaintenanceStart` events are raised when maintenance is imminent (within seconds). These messages do not include a `StartTimeInUTC` because they are fired immediately before maintenance occurs.

#### NodeMaintenanceFailoverComplete event

`NodeMaintenanceFailoverComplete` events are raised when a replica has promoted itself to primary. These events do not include a `StartTimeInUTC` because the action has already occurred. Note that this message will only be fired if the primary is undergoing maintenance, as replica node maintenance does not result in failover.

StackExchange.Redis will automatically refresh its view of the cluster topology in response to this event, and we recommend that client applications implementing their own logic do the same. 

#### NodeMaintenanceEnded event

`NodeMaintenanceEnded` events are raised to indicate that the maintenance operation has completed and that the replica is once again available. You do *NOT* need to wait for this event to use the load balancer endpoint, as it is available throughout. However, we included this for logging purposes and for customers who use the replica endpoint in clusters for read workloads.