# Best Practices for using Azure Cache for Redis with Lettuce

Lettuce is one of the most popular Redis clients for Java. A lot of our customers use Lettuce to access Redis on Azure.

Lettuce is great out of the box, especially for a non-clustered Redis. However, we found that it can be less than ideal for clustered caches on Azure. This can be improved greatly using a few configurations - making the experience a lot smoother and better, especially during updates.

## How to get started Lettuce on Azure for a simple non-clustered caches

This is rather simple. To get started you need:

1. The Redis connection string, which can be found on the Azure Portal. This contains host, password and port information.
2. Install the latest version of Lettuce in your project and simply use the code snippet below to get started. That's all!

### Code snippet to get started on Lettuce with Azure

        // In a production server, the value of host/password will be gotten from Keyvault or other 
        // secret manager. However for code simplicity, these are local here. 
        
        String host = "cacheName.redis.cache.windows.net";
        String password = "*******************************************";
        int port = 6380; //6379 for Non-ssl port, this needs to be enabled from Azure portal before being used.

        RedisURI redisURI = RedisURI.Builder.redis(host).withSsl(true)
                .withPassword(password)
                .withClientName("LettuceClient")
                .withPort(6380)
                .build();

        RedisClient redisClient = RedisClient.create(redisURI);
        
        redisClient.setOptions(ClientOptions.builder()
        .socketOptions(SocketOptions.builder()
              .keepAlive(true)
              .build()))
              
        StatefulRedisConnection<String, String> connection = redisClient.connect();
        RedisCommands<String,String> syncCommands = connection.sync();
        RedisAsyncCommands<String,String> asyncCommands = connection.async();

That's it. As expected, getting started with Lettuce on Azure Redis is rather simple and since Lettuce relies on Netty for the connection management, it tends to be pretty reliable for non-clustered caches.

## Getting started with Lettuce on Azure for clustered caches

Using Lettuce with Azure Redis Clustered caches is reasonably easy but doing it properly takes few more extra steps.

The simple solution is not that different from the non-clustered case where you just inititiate the RedisURI and create a clustered client. However, there are few things that need to be changed.

### Extra configuration required in clustered caches

1. Changes to make certificate verification to work properly with Azure SSL connections.
2. Detecting Cluster configuration changes to avoid downtime during Redis updates.

#### Creating the RedisURI from the connection string

        // In a production server, the value of host/password will be gotten from Keyvault or other 
        // secret manager. However for code simplicity, these are local here. 
        
        String host = "cacheName.redis.cache.windows.net";
        String password = "*******************************************";
        int port = 6380; //6379 for Non-ssl port, this needs to be enabled from Azure portal before being used.        

        RedisURI redisURI = RedisURI.Builder.redis(host).withSsl(true)
                .withPassword(password)
                .withClientName("LettuceClient")
                .withPort(6380)
                .build();

#### Creating a MappingSocketAddressResolver for mapping Host <--> IP

The reason this is required is because SSL certification validates the address of the Redis Nodes with the SAN (Subject Alternative Names) in the SSL certificate. Redis protocol requires that these node addresses should be IP addresses. However, the SANs in the Azure Redis SSL certificates contains only the Hostname since Public IP addresses can change and as a result not completely secure.

We use the following map to resolve Node addresses back to the host name.

        Function<HostAndPort, HostAndPort> mappingFunction = new Function<HostAndPort, HostAndPort>() {
            @Override
            public HostAndPort apply(HostAndPort hostAndPort) {
                InetAddress[] addresses = new InetAddress[0];
                try {
                    addresses = DnsResolvers.JVM_DEFAULT.resolve(host);
                } catch (UnknownHostException e) {
                    e.printStackTrace();
                }
                String cacheIP = addresses[0].getHostAddress();
                HostAndPort finalAddress = hostAndPort;

                if (hostAndPort.hostText.equals(cacheIP))
                    finalAddress = HostAndPort.of(host, hostAndPort.getPort());
                return finalAddress;
            }
        };

        MappingSocketAddressResolver resolver = MappingSocketAddressResolver.create(DnsResolvers.JVM_DEFAULT,mappingFunction);

        ClientResources res =  DefaultClientResources.builder()
                .socketAddressResolver(resolver).build();

#### Creating a client with the above mapping and Cluster specific settings

Here we create the RedisClusterClient with the RedisURI and the Client resources object from above.
After that we create Cluster specific settings to detect configuration changes quickly. This helps to recover quickly in case of updates or failovers that can happen.

        RedisClusterClient redisClient = RedisClusterClient.create(res, redisURI);    

        // Cluster specific settings for optimal reliability. 
        ClusterTopologyRefreshOptions refreshOptions = ClusterTopologyRefreshOptions.builder()
                .enablePeriodicRefresh(Duration.ofSeconds(5))
                .dynamicRefreshSources(false)
                .adaptiveRefreshTriggersTimeout(Duration.ofSeconds(5))
                .enableAllAdaptiveRefreshTriggers().build();

        redisClient.setOptions(ClusterClientOptions.builder()
              .socketOptions(SocketOptions.builder()              
              .keepAlive(true)
              .build())
              .topologyRefreshOptions(refreshOptions).build());

        RedisAdvancedClusterCommands<String, String> syncCommands = connection.sync();
        RedisAdvancedClusterAsyncCommands<String, String> asyncCommands = connection.async();

With the cluster settings configure above, the number of errors seen during failovers are very minimal and should be a lot better the default experience.
