# ASP.Net Session State Provider

## Session State Best Practices

1. **Enable session state only on required pages** - This will avoid known session state provider performance problems.

- You can disable session state by setting the [web.config enableSessionState option](https://msdn.microsoft.com/en-us/library/950xf363(v=vs.85).aspx) to **false**.

    ```xml
       <system.web>
         <pages enableSessionState=false>
    ```

  - You can enable it on specific pages by setting the [page directive's EnableSessionState option](https://msdn.microsoft.com/en-us/library/ydy4x04a(v=vs.100).aspx) to **true**

    ```xml
       <%@ Page EnableSessionState=true %>
    ```

  - Mark pages using Session State as **ReadOnly** whenever possible - this helps avoid locking contention.

    ```xml
       <%@ Page EnableSessionState=ReadOnly %>
    ```

1. **Avoid Session State (or at least use ReadOnly) on pages that have long load times** - When a page with write-access to the session state takes a long time to load, it will hold the lock for that session until the load completes.  This can prevent other requests for other pages for the same session from loading.  Also, the session state module in ASP.NET will, in the background, continue to ask for the session lock for any additional requests for that same session until the lock is available or until the executionTime is exceeded for the lock.  This can generate additional load on your session state store.

1. **Make sure you understand the impact of session state locks.** [Read this article](https://stackoverflow.com/questions/3629709/i-just-discovered-why-all-asp-net-websites-are-slow-and-i-am-trying-to-work-out) for an example of why this is important.

1. **Select your httpRuntime/executionTime carefully** - The executionTime you select is the duration that the session lock is held should the app crash without releasing the lock.  Select a value that is as low as possible while still meeting your application's specific requirements.

`Note:` None of these recommendations are specific to Redis - they are good recommendations regardless of which SessionStateProvider you use.  Also, some of these recommendations are based on [this article](https://www.codeproject.com/Articles/201879/Few-important-tips-that-you-should-know-while-usin), which has additional recommendations beyond those specifically called out here.
