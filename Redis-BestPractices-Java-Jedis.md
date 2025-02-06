# Jedis Java Client

## Use JedisPool

* This allows you to talk to redis from multiple threads while still getting the benefits of reused connections.
* The JedisPool object is thread-safe and can be used from multiple threads at the same time.
* This pool should be configured once and reused.
* **Make sure to return the Jedis instance back to the pool when done, otherwise you will leak the connection**.
* We have seen a few cases where connections in the pool get into a bad state. As a failsafe, you may want to re-create the JedisPool if you see connection errors that continue for longer than 30 seconds.

Some important settings to consider:

| Setting | Description |
| --------| ------------|
| *connectTimeout* | How long to allow for new connections to be established (in milliseconds). In general, this should be at least 5000ms. If your client application tends to have high spikes CPU usage, setting this to 15000ms or 20000ms would be a good idea.|
| *soTimeout* | This configures the socket timeout (in milliseconds) for the underlying connection. You can basically think of this as the operation timeout (how long you are willing to wait for a response from Redis). Think about this one in terms of worst case, not best case. Setting this too low can cause you to get timeout errors due to unexpected bursts in load. I typically recommend 1000ms as a good value for most customers.|
| *port* | In Azure, 6379 is non-ssl and 6380 is SSL/TLS. **Important Note:** 6379 is disabled by default - you have to [explicitly enable this insecure port](https://docs.microsoft.com/en-us/azure/redis-cache/cache-faq#when-should-i-enable-the-non-ssl-port-for-connecting-to-redis) if you wish to use it.|

## Choose JedisPoolConfig settings with care

| Setting | Description |
|--------| -----------|
| *maxTotal* | This setting controls the max number of connections that can be created at a given time. Given that Jedis connections cannot be shared across threads, this setting affects the amount of concurrency your application can have when talking to Redis. Note that each connection does have some memory and CPU overhead, so setting this to a very high value may have negative side effects. If not set, the default value is 8, which is probably too low for most applications. When chosing a value, consider how many concurrent calls into Redis you think you will have *under load*. |
| *maxIdle* | This is the max number of connections that can be idle in the pool without being immediately evicted (closed). If not set, the default value is 8. I would recommend that this setting be configured the same as *maxTotal* to help avoid connection ramp-up costs when your application has many bursts of load in a short period of time. If a connection is idle for a long time, it will still be evicted until the idle connection count hits *minIdle* (described below). |
| *minIdle* | This is the number of "warm" connections (e.g. ready for immediate use) that remain in the pool even when load has reduced. If not set, the default is 0. When choosing a value, consider your *steady-state* concurrent requests to Redis. For instance, if your application is calling into Redis from 10 threads simultaneously, then you should set this to at least 10 (probably a bit higher to give you some room. |
| *blockWhenExhausted* | This controls behavior when a thread asks for a connection, but there aren't any that are free and the pool can't create more (due to *maxTotal*). If set to true, the calling thread will block for *maxWaitMillis* before throwing an exception. The default is true and I recommend true for production environments. You could set it to false in testing environments to help you more easily discover what value to use for *maxTotal*.|
| *maxWaitMillis* | How long to wait in milliseconds if calling JedisPool.getResource() will block. The default is -1, which means block indefinitely. I would set this to the same as the socketTimeout configured. Related to *blockWhenExhausted*. |
| *TestOnBorrow* | Controls whether or not the connection is tested before it is returned from the pool. The default is false. Setting to true may increase resilience to connection blips but may also have a performance cost when taking connections from the pool. In my quick testing, I saw a noticable increase in the 50th percentile latencies, but no significant increase in 98th percentile latencies. |
| *minEvictableIdleTimeMillis* | This specifies the minimum amount of time an connection may sit idle in the pool before it is eligible for eviction due to idle time. The default value is 60 seconds for `JedisPoolConfig`, and 30 minutes if you construct a configuration with `GenericObjectPoolConfig`. Azure Redis currently has 10 minute idle timeout for connections, so this should be set to less than 10 minutes. |

## Use Pipelining

* This will improve the throughput of the application. Read more about redis pipelining here <https://redis.io/topics/pipelining>.
* Jedis does not do pipelining automatically for you. You have to call diffeent APIs in order to get the significant performance benefits that can come from using pipelining.
* Examples can be found [here](https://github.com/xetorthio/jedis/wiki/AdvancedUsage#pipelining).

## Log Pool Usage Periodically

* Debugging performance problems due to JedisPool contention issues will be easier if you log the pool usage regularly.
* If you ever get an error when trying to get a connection from the pool, you should definitely log usage stats. There is [sample code here](Redis-SampleCode-Java-JedisPool.java) that shows which values to log.
