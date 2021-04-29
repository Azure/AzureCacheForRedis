```golang
redis.NewClient(&redis.Options{
        Addr:     "*.redis.cache.windows.net:6379",
        Password: "", 
        DB:       0,  // use default DB,
        // Default is 3 retries; -1 (not 0) disables retries.
        MaxRetries : 14,
        // Minimum backoff between each retry.
        // Default is 8 milliseconds; -1 disables backoff.
        // MinRetryBackoff : 
        // Maximum backoff between each retry.
        // Default is 512 milliseconds; -1 disables backoff.
        // MaxRetryBackoff : 
        // DialTimeout:5,
        ReadTimeout:5000 * time.Millisecond,
        WriteTimeout:5000 * time.Millisecond,
        PoolSize:1000, // for benchmarking, ideally should be 10
        PoolTimeout:5000 * time.Millisecond,
        IdleTimeout:300000 * time.Millisecond,
    })
```
