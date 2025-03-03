import javax.net.ssl.HostnameVerifier;
import javax.net.ssl.SSLPeerUnverifiedException;
import javax.net.ssl.SSLSession;
import redis.clients.jedis.*;
import javax.net.ssl.*;

// Source Code Usage License: https://gist.github.com/JonCole/34ca1d2698da7a1aa65ff781c37ecdea
public class Redis {
    private static Object staticLock = new Object();
    private static JedisPool pool;
    private static String host;
    private static int port; // 6379 for NonSSL, 6380 for SSL
    private static int connectTimeout; //milliseconds
    private static int operationTimeout; //milliseconds
    private static String password;
    private static JedisPoolConfig config;

    // Should be called exactly once during App Startup logic.
    public static void initializeSettings(String host, int port, String password, int connectTimeout, int operationTimeout) {
        Redis.host = host;
        Redis.port = port;
        Redis.password = password;
        Redis.connectTimeout = connectTimeout;
        Redis.operationTimeout = operationTimeout;
    }

    // MAKE SURE to call the initializeSettings method first
    public static JedisPool getPoolInstance() {
        if (pool == null) { // avoid synchronization lock if initialization has already happened
            synchronized(staticLock) {
                if (pool == null) { // don't re-initialize if another thread beat us to it.
                    JedisPoolConfig poolConfig = getPoolConfig();
                    boolean useSsl = port == 6380 ? true : false;
                    int db = 0;
                    String clientName = "MyClientName"; // null means use default
                    SSLSocketFactory sslSocketFactory = null; // null means use default
                    SSLParameters sslParameters = null; // null means use default
                    HostnameVerifier hostnameVerifier = new SimpleHostNameVerifier(host);
                    pool = new JedisPool(poolConfig, host, port, connectTimeout,operationTimeout,password, db,
                            clientName, useSsl, sslSocketFactory, sslParameters, hostnameVerifier);
                }
            }
        }
        return pool;
    }

    public static JedisPoolConfig getPoolConfig() {
        if (config == null) {
            JedisPoolConfig poolConfig = new JedisPoolConfig();

            // Each thread trying to access Redis needs its own Jedis instance from the pool.
            // Using too small a value here can lead to performance problems, too big and you have wasted resources.
            int maxConnections = 200;
            poolConfig.setMaxTotal(maxConnections);
            poolConfig.setMaxIdle(maxConnections);

            // Using "false" here will make it easier to debug when your maxTotal/minIdle/etc settings need adjusting.
            // Setting it to "true" will result better behavior when unexpected load hits in production
            poolConfig.setBlockWhenExhausted(true);

            // How long to wait before throwing when pool is exhausted
            poolConfig.setMaxWaitMillis(operationTimeout);

            // This controls the number of connections that should be maintained for bursts of load.
            // Increase this value when you see pool.getResource() taking a long time to complete under burst scenarios
            poolConfig.setMinIdle(50);

            Redis.config = poolConfig;
        }

        return config;
    }

    public static String getPoolCurrentUsage()
    {
        JedisPool jedisPool = getPoolInstance();
        JedisPoolConfig poolConfig = getPoolConfig();

        int active = jedisPool.getNumActive();
        int idle = jedisPool.getNumIdle();
        int total = active + idle;
        String log = String.format(
                "JedisPool: Active=%d, Idle=%d, Waiters=%d, total=%d, maxTotal=%d, minIdle=%d, maxIdle=%d",
                active,
                idle,
                jedisPool.getNumWaiters(),
                total,
                poolConfig.getMaxTotal(),
                poolConfig.getMinIdle(),
                poolConfig.getMaxIdle()
        );

        return log;
    }

    private static class SimpleHostNameVerifier implements HostnameVerifier {

        private String exactCN;
        private String wildCardCN;
        public SimpleHostNameVerifier(String cacheHostname)
        {
            exactCN = "CN=" + cacheHostname;
            wildCardCN = "CN=*" + cacheHostname.substring(cacheHostname.indexOf('.'));
        }

        public boolean verify(String s, SSLSession sslSession) {
            try {
                String cn = sslSession.getPeerPrincipal().getName();
                return cn.equalsIgnoreCase(wildCardCN) || cn.equalsIgnoreCase(exactCN);
            } catch (SSLPeerUnverifiedException ex) {
                return false;
            }
        }
    }
}