# Introducing AzureRedisEvents channel

A lot of customers have asked us for the ability to know about upcoming maintenance so that they can handle downtime/connection blips more gracefully.

*AzureRedisEvents* is the new Pub/Sub channel we are introducing that publishes notifications during planned maintenance events.

## Message format

Each entry in the message is separated by using a pipe (|) as a delimiter. All messages start with a *FieldName* followed by the *Entry* for the field and so on so forth.

---
    NotificationType|{NotificationType}|StartTimeInUTC|{StartTimeInUTC}|IsReplica|{IsReplica}|IPAddress|{IPAddress}|SSLPort|{SSLPort}|NonSSLPort|{NonSSLPort}
---

You can use the following C# sample class to parse the message into a simple AzureRedisEvent type.

    public class AzureRedisEvent
    {
        public AzureRedisEvent(string message)
        {
            var info = message.Split('|');
            for (int i = 0; i < info.Length / 2; i++)
            {
                var key = info[2 * i];
                var value = info[2 * i + 1];
                switch (key)
                {
                    case "NotificationType":
                        NotificationType = value;
                        break;
                    case "StartTimeInUTC":
                        StartTimeInUTC = DateTime.Parse(value);
                        break;
                    case "IsReplica":
                        IsReplica = bool.Parse(value);
                        break;
                    case "IPAddress":
                        IPAddress = value;
                        break;
                    case "SSLPort":
                        SSLPort = Int32.Parse(value);
                        break;
                    case "NonSSLPort":
                        NonSSLPort = Int32.Parse(value);
                        break;
                    default:
                        Console.WriteLine($"Unexpected i={i}, case {key}");
                        break;
                }
            }
        }
        public readonly string NotificationType;
        public readonly DateTime StartTimeInUTC;
        public readonly bool IsReplica;
        public readonly string IPAddress;
        public readonly int SSLPort;
        public readonly int NonSSLPort;
    }

### `NodeMaintenanceStarting message`

*NodeMaintenanceStarting* messages are published 30 seconds ahead of upcoming maintenance - which usually means that one of the nodes (primary/replica) is going to be down for Standard/Premier Sku caches. 

It's important to understand that this does *not* mean downtime if you are using a Standard/Premier sku caches. Rather, it means there is going be a failover that will disconnect existing connections going through the LB port (6380/6379) or directly to the node (15000/15001) and operations might fail until these connections reconnect.

In the case of clustered nodes, you might have to stop sending read/write operations to this node until it comes back up and use the node which will have been promoted to primary. For basic sku only, this will mean complete downtime until the update finishes.

One of the things that can be done to reduce impact of connection blips would be to stop sending operations to the cache a second before the *StartTimeinUTC* until the connection is restored which typically takes less than a second in most clients like StackExchange.Redis and Lettuce.

### `NodeMaintenanceEnded` message

Similarly, there will be a notification message that is received when the maintenance ends that will sent through the *AzureRedisEvents* channel. You do *NOT* need to wait for this message to use the LB endpoint. The LB endpoint is always available. However, we included this for logging purposes or for customers who use the replica endpoint in clusters for read workloads.

## Walking through a sample maintenance event

1. App is connected to Redis and everything is working fine. 

2. Current Time: [16:25:40] -> Message received through *AzureRedisEvents* channel. The message notification type is "NodeMaintenanceStarting" and StartTimeInUTC is "16:26:10" (about 30 seconds from current time). So we wait. 

        NotificationType|NodeMaintenanceStarting|StartTimeInUTC|2020-10-14T16:26:10|IsReplica|False|IPAddress|52.158.249.185|SSLPort|15001|NonSSLPort|13001

3. Current Time: [16:26:09] -> This is one second before the maintenance events. We break the circuit and stop sending new operations to the Redis object.

4. Current Time: [16:26:10] -> The Redis object is disconnected from the Redis server. You can listen to these ConnectionDisconnected events from most clients [StackExchange Events](<https://stackexchange.github.io/StackExchange.Redis/Events>) or [Lettuce Events](<https://github.com/lettuce-io/lettuce-core/wiki/Connection-Events#connection-events>).

5. Current Time [16:26:10] -> The Redis object is reconnected back to the Redis server (again, you can listen to the Reconnected event on your client). It is safe to send ops again to the Redis connection and all ops will succeed.

6. Current Time [16:27:42] -> Message received through *AzureRedisEvents* channel. The message notification type is "NodeMaintenanceEnded" and StartTimeInUTC is "16:27:42". Nothing to do here if you are talking to 6380/6379. For clustered caches, you can start sending readonly workloads to the replica. 

        NotificationType|NodeMaintenanceEnded|StartTimeInUTC|2020-10-14T16:27:42|IsReplica|True|IPAddress|52.158.249.185|SSLPort|15001|NonSSLPort|13001


## Sample code to listen to the *AzureRedisEvents* 

            var sub = multiplexer.GetSubscriber();
            var failover = sub.SubscribeAsync("AzureRedisEvents", async (channel, message) =>
            {
                Console.WriteLine($"[{DateTime.UtcNow:hh.mm.ss.ffff}] { message }");
                var newMessage = new AzureRedisEvent(message);
                if (newMessage.NotificationType == "NodeMaintenanceStarting")
                {
                    var delay = newMessage.StartTimeInUTC.Subtract(DateTime.UtcNow) - TimeSpan.FromSeconds(1);
                    Console.WriteLine($"[{DateTime.UtcNow:hh.mm.ss.ffff}] Waiting for {delay.TotalSeconds} seconds before breaking circuit");
                    await Task.Delay(delay);
                    circuitBroken = true;
                    Console.WriteLine($"[{DateTime.UtcNow:hh.mm.ss.ffff}] Breaking circuit since update coming at {newMessage.StartTimeInUTC}");
                }
                
                

### Clustered cache: targeted circuit breaking for StackExchange.Redis

In the case of clustered caches, since only one of the shards is going to have availability issues at a time. It is possible to only stop calls going to the specific shard instead of all the calls. You can do this by hashing the key and figuring out the endpoint.

            var multiplexer = ConnectionMultiplexer.Connect(configuration);
            // Ideally clusterConfig is stored and not executed every single time, since it can be expensive
            var lastKnownClusterConfig = multiplexer.GetServer(configuration.EndPoints.FirstOrDefault()).ClusterNodes();

            var endpoint = (System.Net.IPEndPoint) lastKnownClusterConfig.GetBySlot(key).EndPoint;
            
            // Figure out the shardId from Port number
            // Use 13000 instead of 15000 below if communicating over non-SSL
            var shardId = (endpoint.Port - 15000) / 2;

            // Compare this to the shardId of the failing endpoint (SSLPort - 15000)/2  from the AzureRedisEvent above
            if (shardId == failingShardId) 
            {
                // Don't send the operation.
            }
