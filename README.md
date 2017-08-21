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

## Memcached Support
A local memcached server is required on Squid machine. Cache::Memcached::Fast module is required to use memcached. The helper file with memcached support is `charcoal-helper-memcached.pl`.

Default time for caching the results is 60 seconds.

`my $CACHE_TIME = 60;`

The result for each request is cached in memcached and charcoal server is not queried unless result is found in the cache.

To install memcached on your machine, please refer to the documentation provided by your distribution. For Debian/Ubuntu, you may follow these steps:

`apt-get update`
`apt-get install memcached`
`systemctl enable memcached`
`systemctl restart memcached`

## Squid Versions supported

Squid-2.x is supported in compatibility mode with *-c* argument to the helper. While Squid-3.x is supported natively.
We will add support for Squid-4.x soon.

## Setup and Configuration
Add following lines to *squid.conf*:

`url_rewrite_program /path/to/charcoal-helper.pl YOUR_API_KEY`

`url_rewrite_children X startup=Y idle=Z concurrency=1

Adjust the values of X, Y and Z for your environment. Typically, X=10, Y=2 and Z=1 works fine on 
ALIX and Routerboard with around 10 machines in the network.

In order to obtain API key, kindly write to [charcoal@hopbox.in](mailto:charcoal@hopbox.in)

## Managing the ACL rules

Head to [active.charcoal.io](https://active.charcoal.io) and login with the credentials provided with the API key.
