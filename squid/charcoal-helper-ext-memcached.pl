#!/usr/bin/perl -s
#
# Charcoal - URL Re-Director/Re-writer for Squid
# Copyright (C) 2012 Unmukti Technology Pvt Ltd <info@unmukti.in>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 59 Temple Place, Suite 330, Boston, MA 02111, USA.

use IO::Socket;
use Cache::Memcached;

$|=1; #Flush after write

my $DEBUG = 1 if $d;
my $CACHE = 0;
my $CACHE_TIME = 300;

my $squidver = 3;
$squidver = 2 if $c;

# ARGUMENTS REQUIRED
# 1. API Key

if ($h){
	print STDERR "Usage:\t$0 [-cdh] <api-key>\n";
	print STDERR "\t$0 -c -d <api-key>\t: send debug messages to STDERR\n";
	print STDERR "\t$0 -h\t\t\t: print this message\n";
	print STDERR "\t$0 -c\t\t\t: run helper in Squid 2.x compatibility mode.\n";
	exit 0;
}

if ( @ARGV < 1){
	print STDERR "BH message=\"Usage: $0 -[cdh] <api-key>\"\n";
	exit 1;
}


#########
## Server: charcoal.hopbox.in
## Port  : 80
## Uncomment server closest to your location - India, EU, US

# Servers for India
my $charcoal_server = 'active.charcoal.io';

# Servers for EU
#my $charcoal_server = 'eu.active.charcoal.io';

# Server for US
#my $charcoal_server = 'us.active.charcoal.io';

my $charcoal_port   = '6603';
my $proto           = 'tcp';
my $timeout         = 10;

my $apikey = shift @ARGV;

print STDERR "Received API KEY $apikey\n";
print STDERR "Running for Squid Version $squidver\n";


#For each requested URL, the rewriter will receive on line with the format
#
#	  [channel-ID <SP>] URL [<SP> extras]<NL>
#
#	See url_rewrite_extras on how to send "extras" with optional values to
#	the helper.
#	After processing the request the helper must reply using the following format:
#
#	  [channel-ID <SP>] result [<SP> kv-pairs]
#
#	The result code can be:
#
#	  OK status=30N url="..."
#		Redirect the URL to the one supplied in 'url='.
#		'status=' is optional and contains the status code to send
#		the client in Squids HTTP response. It must be one of the
#		HTTP redirect status codes: 301, 302, 303, 307, 308.
#		When no status is given Squid will use 302.
#
#	  OK rewrite-url="..."
#		Rewrite the URL to the one supplied in 'rewrite-url='.
#		The new URL is fetched directly by Squid and returned to
#		the client as the response to its request.
#
#	  OK
#		When neither of url= and rewrite-url= are sent Squid does
#		not change the URL.
#
#	  ERR
#		Do not change the URL.
#
#	  BH
#		An internal error occurred in the helper, preventing
#		a result being identified. The 'message=' key name is
#		reserved for delivering a log message.
#


$SIG{PIPE} = sub {
				print STDERR "ERROR: Charcoal: Lost connection to server: $!\n";
				print "BH message=\"Charcoal: Lost connection to server: $!\"\n";
				return 1;
			};

our ($memd, $socket);

$socket = new_socket();
connect_cache();

while(<>){

	chomp;

	print STDERR "RAW: $_\n" if $DEBUG;

	my @chunks = split(/\s+/);

	print STDERR scalar(@chunks) . " chunks received \n" if $DEBUG;

	$socket = new_socket() if (!$socket->connected());

	if ($chunks[0] =~ m/^\d+/){
	### Concurrency enabled
		print STDERR "Concurrency Enabled\n" if $DEBUG;
		my ($chan, $url, $clientip, $ident, $method, $blah, $proxyip, $proxyport) = split(/\s+/);
		my $query = "$apikey|$squidver|$clientip|$ident|$method|$blah|$url";
		my $access = get_access($query);

		if ($squidver == 2){

			if ($access =~ /Timed Out/){
				print STDERR "WARNING: Charcoal Server connection closed. Reattempting query.\n";
				$socket = new_socket();
				$access = get_access($query);
				if ($access =~ /Timed Out/){
					print STDERR "ERROR: Charcoal: Server connection closed again.\n";
					print STDOUT "BH message=\"Charcoal: Server connection closed while querying. Giving up on this query.\"\n";
					next;
				}
			}
		}
 		else {
			if ($access =~ /Timed Out/ or !$access or $access eq "\r\n"){
				print STDERR "WARNING: Charcoal Server connection closed. Reattempting query.\n";
				$socket = new_socket();
				$access = get_access($query);
				if ($access =~ /Timed Out/ or !$access or $access eq "\r\n"){
					print STDERR "ERROR: Charcoal: Server connection closed again.\n";
					print STDOUT "BH message=\"Charcoal: Server connection closed while querying. Giving up on this query.\"\n";
					next;
				}
			}
		}

		chomp $access;

		$access = "ERR message=NOTALLOWED" if ($access =~ /status=/);

		$memd->set($query, $access, $CACHE_TIME) if $CACHE != 1;

		my $res = $chan . ' ' . $access;
		print STDOUT "$res\n";
		print STDERR "$res\n" if $DEBUG;
		next;
	}

	else {
	### Concurrency disabled
		print STDERR "Concurrency Disabled\n" if $DEBUG;
		my ($url, $clientip, $ident, $method, $blah, $proxyip, $proxyport) = split(/\s+/);
		my $query = "$apikey|$squidver|$clientip|$ident|$method|$blah|$url";
		my $access = get_access($query);

		if ($squidver == 2){

			if ($access =~ /Timed Out/){
				print STDERR "WARNING: Charcoal Server connection closed. Reattempting query.\n";
				$socket = new_socket();
				$access = get_access($query);
				if ($access =~ /Timed Out/){
					print STDERR "ERROR: Charcoal: Server connection closed again.\n";
					print STDOUT "BH message=\"Charcoal: Server connection closed while querying. Giving up on this query.\"\n";
					next;
				}
			}
		}
 		else {
			if ($access =~ /Timed Out/ or !$access or $access eq "\r\n"){
				print STDERR "WARNING: Charcoal Server connection closed. Reattempting query.\n";
				$socket = new_socket();
				$access = get_access($query);
				if ($access =~ /Timed Out/ or !$access or $access eq "\r\n"){
					print STDERR "ERROR: Charcoal: Server connection closed again.\n";
					print STDOUT "BH message=\"Charcoal: Server connection closed while querying. Giving up on this query.\"\n";
					next;
				}
			}
		}


		chomp $access;

		$access = "ERR message=NOTALLOWED" if ($access =~ /status=/);

		$memd->set($query, $access, $CACHE_TIME) if $CACHE != 1;

		my $res = $access;
		print STDOUT "$res\n";
		print STDERR "$res\n" if $DEBUG;

	}

}

sub get_access {
	my $query = shift;
	$CACHE = 0;
	print STDERR "Charcoal: Checking memcached for $query\n" if $DEBUG;
	connect_cache() unless defined $memd;
	my $cres = $memd->get($query);
	if ($cres) {
		print STDERR "Charcoal: Found in memcached: $cres\n" if $DEBUG;
		$CACHE = 1;
		return $cres;
	}
	print STDERR "Charcoal: Sending $query\n" if $DEBUG;
	print $socket "$query\r\n";
	my $access = <$socket>;
	print STDERR "Charcoal: get_access ACCESS: $access\n" if $DEBUG;
	return $access;
}

sub new_socket {
	my $sock = IO::Socket::INET->new(PeerAddr  => $charcoal_server,
			PeerPort   => $charcoal_port,
			Proto	   => $proto,
			Timeout	   => $timeout,
			Type	   => SOCK_STREAM,
		);

	if (!$sock) {
		print STDOUT "BH message=\"Charcoal: Error connecting to server. $!\"\n";
		print STDERR "FATAL: Charcoal: Error connecting to server. $!\n"; 
		die;
	}

	print STDERR "Charcoal: Connected to $charcoal_server on $proto port $charcoal_port.\n" if $DEBUG;

	return $sock;
}

sub connect_cache {
	print STDERR "Connecting to memcached...\n";
	$memd = new Cache::Memcached {
		'servers'	=> [ "127.0.0.1:11211" ],
		'debug'		=> 0,		
		'compress_threshold' => 10_1000,
	};

}
