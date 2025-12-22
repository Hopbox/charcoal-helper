* **charcoal-helper-ext.pl: Update for reliability and stability**
    
It now handles both network issues and server-side timeouts gracefully.
    
* The script now follows this high-level logic for maximum reliability:

1. **Queueing**: Every request from Squid is assigned a Channel ID and placed in a Main Queue.
1. **Multiplexing**: It monitors both Squid (STDIN) and the Filtering Server (Socket) simultaneously using IO::Select.
1. **In-Flight Tracking**: Once a request is sent, it moves to a FIFO (First-In-First-Out) Pending List with a timestamp.
1. **Error Recovery**: 
- If the server sends "Timed Out.", the script closes the socket and moves all pending requests back to the Main Queue.
- If the server is silent for too long (In-flight timeout), the script forces a reconnection.
- If the connection breaks (EOF), the script "rescues" pending items and retries them.

    
**How to Run and Deploy**
    
_Squid Configuration_

Add the helper to your squid.conf. Using concurrency is highly recommended since this script handles it natively:
    
For Squid 3.x/4.x/5.x/6.x/7.x - if API Key is not specified in /etc/charcoal.conf or /etc/config/charcoal
    
`external_acl_type charcoal_helper children-max=5 children-startup=3 children-idle=1 concurrency=100 ttl=60 %URI %SRC %IDENT %METHOD %% %MYADDR %MYPOR /usr/lib/squid/charcoal-helper-ext.pl YOUR_API_KEY`
    
For Squid 2.x (using the -c flag)a - if API Key is not specified in /etc/charcoal.conf or /etc/config/charcoal

`external_acl_type charcoal_helper children-max=5 children-startup=3 children-idle=1 concurrency=100 ttl=60 %URI %SRC %IDENT %METHOD %% %MYADDR %MYPOR /usr/lib/squid/charcoal-helper-ext.pl -c YOUR_API_KEY`
    
If API key is specified in /etc/charcoal.conf or /etc/config/charcoal:
    
`external_acl_type charcoal_helper children-max=5 children-startup=3 children-idle=1 concurrency=100 ttl=60 %URI %SRC %IDENT %METHOD %% %MYADDR %MYPOR /usr/lib/squid/charcoal-helper-ext.pl`
    
_Common config_
```
acl charcoal external charcoal_helper
http_access deny !charcoal   
```

**Maintenance**
    
- Logs: Debug messages go to STDERR. When running under Squid, these are typically captured in Squid’s cache.log.
- UCI/Config: If you change the server IP or port in /etc/config/charcoal (OpenWrt) or /etc/charcoal.conf, Squid will need a squid -k reconfigure to restart the helper and pick up the new settings.

    
