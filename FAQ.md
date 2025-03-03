# Frequently Asked Questions

### Why do we see higher latencies during Host OS updates or failovers?

Higher latencies in your client application could be due to how the client library and client application is handling retries under the hood. It's important to note that network blips can happen due to unplanned events as well as planned maintenance, so applications should be designed and implemented in a way that's resilient to brief cache connection loss. The resilience may take the form of retrying commands and connections, circuit breaker patterns that redirect traffic away from impacted caches, or other strategies.

For example, Lettuce automatically retries commands that land on a temporarily broken connection during a network blip. While the retry should happen very quickly, some configuration settings can be tweaked to get a faster response. A colleague found that tweaking Lettuce config with settings like these may help with recovery times when using clustered caches: [Lettuce Best Practices.md](Lettuce%20Best%20Practices.md#creating-a-client-with-the-above-mapping-and-cluster-specific-settings)
