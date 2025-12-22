# charcoal-helper
### Web API squid redirector helper client

Copyright Unmukti Technology Private Limited, India

Licensed under GNU General Public License. See LICENCE for more details.

## System Requirements

Squid helper is written in Perl and is currently running on following systems:

* [OpenWRT](http://openwrt.org) / [LEDE Project](http://lede-project.org) on
    - [PCEngines ALIX](http://pcengines.ch/alix.htm)
    - [PCEngines APU](http://pcengines.ch/apu.htm)
    - [PCEngines APU2](http://pcengines.ch/apu2.htm)
    - Routerboard RB951Ui-2HnD

* [PfSense](http://pfsense.org) on x86 and AMD64 (ALIX & APU/APU2 included)

It can run on any POSIX compliant Unix system which has:

+ Perl >= 5.14.x
    - IO::Socket
    - optionally Cache::Memcached::Fast (for memcached enabled helper)
    - Cache:Memcached on OpenWrt

## Memcached Support
A local memcached server is suggested on Squid machine. `Cache::Memcached::Fast` module is required to use memcached. Helper files with `-memcached` in the names use memcached, if available.

Default time for caching the results is 60 seconds.

`my $CACHE_TIME = 60;`

The result for each request is cached in memcached and charcoal server is not queried unless result is not found in the cache.

To install memcached on your machine, please refer to the documentation provided by your distribution. For Debian/Ubuntu, you may follow these steps:

`apt-get update`

`apt-get install memcached`

`systemctl enable memcached`

`systemctl restart memcached`

Following is a transcript of a successful telnet session to memcached:

```
telnet localhost 11211
Trying 127.0.0.1...
Connected to localhost.
Escape character is '^]'.
stats
STAT pid 1108
STAT uptime 11402
STAT time 1503303182
STAT version 1.4.25 Ubuntu
STAT libevent 2.0.21-stable
STAT pointer_size 64
STAT rusage_user 0.144000
STAT rusage_system 0.176000
STAT curr_connections 5
STAT total_connections 7
...
...
...
END
quit
Connection closed by foreign host.
```

## Squid Versions supported

* Squid-2.x is supported in compatibility mode with `-c` argument to the helper. 
* Squid > 3.x are supported natively as external acl helper.

## Setup and Configuration
Add following lines to `squid.conf`:

Configuration as External ACL Helper:

```
http_access deny !safe_ports
http_access deny connect !ssl_ports

external_acl_type charcoal_helper ttl=60 negative_ttl=60 children-max=X children-startup=Y children-idle=Z concurrency=10 %URI %SRC %IDENT %METHOD %% %MYADDR %MYPORT /etc/config/squid-helpers/charcoal-helper-ext-memcached.pl <API_KEY>
acl charcoal external charcoal_helper
http_access deny !charcoal

http_access allow localhost manager
http_access deny manager
```

Configuration as URL Rewrite Program **not recommended**:

```
url_rewrite_program /path/to/charcoal-helper.pl YOUR_API_KEY
url_rewrite_children X startup=Y idle=Z concurrency=1
```

Adjust the values of X, Y and Z for your environment. Typically, X=10, Y=2 and Z=1 works fine on 
ALIX and Routerboard with around 10 machines in the network.

In order to obtain API key, kindly write to [charcoal@hopbox.in](mailto:charcoal@hopbox.in)

Alternatively, self-host charcoal server - https://github.com/hopbox/charcoal/

## Managing the ACL rules

Head to [my.charcoal.io](https://my.charcoal.io) and login with the credentials provided with the API key.
