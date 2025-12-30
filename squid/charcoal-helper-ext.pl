#!/usr/bin/perl -s
#
# Charcoal - External ACL helper for squid
# Usage: ./charcoal-helper-ext.pl [-cdh] <api-key>
# Copyright (C) 2012-2025 Unmukti Technology Pvt Ltd <info@unmukti.in>
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

use strict;
use warnings;
our $VERSION = '1.2.1';
use vars qw($h $d $c $f); # -h (help), -d (debug), -c (compat), -f (fail-mode)
use IO::Socket;
use IO::Select;
use Time::HiRes qw(time);
use Socket;

$| = 1; 

# --- ARGUMENTS & HELP LOGIC ---
if ($h) {
    print STDERR "Charcoal External ACL Helper (Perl) v$VERSION\n";
    print STDERR "Usage:\t$0 [-cdfh] <api-key>\n";
    print STDERR "\t$0 -c -d <api-key>\t: debug to STDERR\n";
    print STDERR "\t$0 -f=ERR <api-key>\t: Fail-Closed (block on server error)\n";
    print STDERR "\t$0 -f=OK <api-key>\t: Fail-Open (allow on server error)\n";
    print STDERR "\t$0 -h\t\t\t: print this message\n";
    print STDERR "\t$0 -h\t\t\t: print help\n";
    print STDERR "\t$0 -c\t\t\t: Squid 2.x mode\n";
    exit 0;
}

my $apikey_arg = @ARGV ? shift @ARGV : undef;
my $squidver_arg = $c ? 2 : undef;

# --- SIGNAL HANDLING ---
$SIG{TERM} = $SIG{INT} = sub { exit(0); };

# --- UNIVERSAL CONFIG LOADER ---
my %CONFIG;
sub load_config {
    my $uci_bin = `which uci 2>/dev/null`;
    if ($uci_bin) {
        $CONFIG{server}  = `uci -q get charcoal.main.server`  || 'active.charcoal.io';
        $CONFIG{port}    = `uci -q get charcoal.main.port`    || '6603';
        $CONFIG{api_key} = `uci -q get charcoal.main.api_key` || 'MISSING_KEY';
        $CONFIG{ver}     = `uci -q get charcoal.main.squid_version` || '3';
        $CONFIG{debug}   = `uci -q get charcoal.main.debug`   || 0;
        $CONFIG{max_retries} = `uci -q get charcoal.main.max_retries` || 2;
        $CONFIG{timeout} = `uci -q get charcoal.main.timeout` || 2;
        $CONFIG{slow_threshold} = `uci -q get charcoal.main.slow_threshold` || 0.1;
        $CONFIG{default_reply} = `uci -q get charcoal.main.default_reply` || 'OK';
    } else {
        my $file = -e "/etc/charcoal.conf" ? "/etc/charcoal.conf" : "./charcoal.conf";
        if (open(my $fh, '<', $file)) {
            while (<$fh>) {
                chomp; next if /^\s*#/ || /^\s*$/;
                my ($k, $v) = split(/\s*=\s*/, $_, 2);
                $CONFIG{$k} = $v if $k;
            }
            close($fh);
        }
    }
    foreach (keys %CONFIG) { chomp $CONFIG{$_} if defined $CONFIG{$_}; $CONFIG{$_} =~ s/\s+//g if $CONFIG{$_}; }
}

load_config();

# --- VARIABLE ASSIGNMENT ---
my $DEBUG = $d || $CONFIG{debug} || 0;
my $squidver = $c ? 2 : ($CONFIG{ver} || 3);
my $apikey = $apikey_arg || $CONFIG{api_key} || 'MISSING_KEY';
my $charcoal_server = $CONFIG{server} || 'active.charcoal.io';
my $charcoal_port   = $CONFIG{port}   || '6603';
my $max_retries     = $CONFIG{max_retries} || 2;
my $timeout         = $CONFIG{timeout} || 3;
my $default_reply   = $f || $CONFIG{default_reply} || 'OK'; # OK = Fail-Open, ERR = Fail-Closed
$CONFIG{current_peer} = "none";
$CONFIG{conn_established} = undef;

# Pre-connect to the local log socket
my $LOG_SOCK_PATH = '/dev/log';
socket(my $lp, PF_UNIX, SOCK_DGRAM, 0);
my $log_dest = sockaddr_un($LOG_SOCK_PATH);

sub log_warn {
    my ($msg, $latency, $chan) = @_;
    $latency //= 0; # THE FIX: Default to 0 if undefined
    my $now = time();
    
    # Calculate connection age
    my $conn_age = defined $CONFIG{conn_established} ? int($now - $CONFIG{conn_established}) : 0;
    my $peer = $CONFIG{current_peer} || "none";

    # 1. Local terminal log (STDERR) with millisecond precision
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    my $ms = sprintf("%03d", ($now - int($now)) * 1000);
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d.%s] Charcoal: !!! SLOW [%s] Latency: %.4fs Age: %ds Peer: %s !!!\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, $ms, ($chan // '0'), $latency, $conn_age, $peer;

    # 2. Remote telemetry log (/dev/log) - Quoted strings, unquoted numbers
    my $pri = 28; # daemon.warn
    my $structured = sprintf("<%d>charcoal-helper: v=\"%s\" msg=\"%s\" latency=%.4f chan=%s server=\"%s\" conn_age=%d", 
                             $pri, $VERSION, $msg, $latency, ($chan // 0), $peer, $conn_age);

    send($lp, $structured, 0, $log_dest);
}

sub log_debug {
    return unless $DEBUG;
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    # Use Time::HiRes::time() for fractional seconds
    my $now = time();
    my $ms = sprintf("%03d", ($now - int($now)) * 1000);
    
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d.%s] Charcoal: %s\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, $ms, shift;
}


log_debug("Started v$VERSION. Server: $charcoal_server, API: $apikey, Fail-Mode: $default_reply, Squid Ver: $squidver");

# --- MAIN LOOP & LOGIC ---
my $socket          = undef;
my $sel             = IO::Select->new(\*STDIN);
my @queue           = ();    
my %pending_queries = ( fifo => [] ); 
my $connect_start   = 0;
my $last_retry      = 0;
my $socket_buf      = '';

while (1) {
    my $now = time();

    # 1. Lazy Connection Management
    # Only try to connect if we have no socket AND there is work to do
    if (!$socket && @queue) {
        if ($now - $last_retry > 1) { 
            $last_retry = $now;
            log_debug("Requests waiting. Attempting to connect to $charcoal_server...");
            
            $socket = IO::Socket::INET->new(
                PeerAddr => $charcoal_server, PeerPort => $charcoal_port,
                Proto => 'tcp', Blocking => 0, Timeout => 2
            );
            
            if ($socket) {
                $sel->add($socket);
                $connect_start = 0; # Reset connection timer
                $CONFIG{current_peer} = $socket->peerhost() || $charcoal_server;
                $CONFIG{conn_established} = time(); # NEW: Track start time
                log_debug("Connected to node: $CONFIG{current_peer}");
            } else {
                # Mark when we started failing to connect to enforce the timeout
                $connect_start = $now if !$connect_start;
                log_debug("Connection failed. Will retry...");
            }
        }
    }

    # 2. Check for Fail-Safe (Timeout handling)
    my $waiting_since = 0;
    if (!$socket && $connect_start > 0) { 
        $waiting_since = $connect_start; 
    } elsif (@{$pending_queries{fifo}}) { 
        $waiting_since = $pending_queries{fifo}[0]{sent_at}; 
    }

    if ($waiting_since > 0 && ($now - $waiting_since > $timeout)) {
        if (!$socket) {
            log_debug("Could not connect within $timeout seconds. Flushing queue with $default_reply.");
            while (my $item = shift @queue) { send_to_squid($item->{chan}, $default_reply); }
            $connect_start = 0;
        } else {
            close_socket("In-flight response timeout");
        }
    }

    # 3. I/O Multiplexing (Wait for Squid or Server)
    my @ready = $sel->can_read(0.1); 
    foreach my $fh (@ready) {
        if ($fh == \*STDIN) { 
            exit(0) unless handle_stdin(); # This adds to @queue
        }
        elsif ($socket && $fh == $socket) { 
            handle_socket_read(); 
        }
    }

    # 4. Sending Data
    if ($socket && $socket->connected && @queue) {
        while (my $item = shift @queue) {
            log_debug("Sending to server - payload: $item->{payload}");
            $item->{sent_at} = time(); 
            print $socket $item->{payload} . "\r\n";
            push @{$pending_queries{fifo}}, $item;
        }
    }
}

sub handle_stdin {
    my $line = <STDIN>;
    return 0 unless defined $line;
    chomp $line;
    my @chunks = split(/\s+/, $line);
    return 1 if !@chunks;

    my ($chan, $url, $cip, $id, $meth, $blah);
    if ($chunks[0] =~ /^\d+$/) { ($chan, $url, $cip, $id, $meth, $blah) = @chunks; }
    else { $chan = ""; ($url, $cip, $id, $meth, $blah) = @chunks; }
    
    my $payload = join('|', $apikey, $squidver, ($cip||"-"), ($id||"-"), ($meth||"-"), ($blah||"-"), ($url||"-"));
    push @queue, { chan => $chan, payload => $payload, retries => 0 };
    return 1;
}

sub handle_socket_read {
    return unless (defined $socket && $socket->opened);
    
    my $data;
    my $rv = sysread($socket, $data, 8192);

    if (!defined($rv)) {
        # Check if it's just a "no data yet" error
        if ($!{EAGAIN} || $!{EWOULDBLOCK}) {
            return; # Do nothing, just go back to the main loop
        } else {
            close_socket("Socket read error: $!");
            return;
        }
    } elsif ($rv == 0) {
        close_socket("Remote server closed connection (EOF)");
        return;
    }

    # Append new data to our persistent buffer
    $socket_buf .= $data;

    # Process every complete line in the buffer
    while ($socket_buf =~ s/^(.*?)[\r\n]+//) {
        my $response = $1;
        $response =~ s/^\s+|\s+$//g;
        next if $response eq "";

        if ($response =~ /Timed Out/i) {
            close_socket("Server-side Internal Timeout");
            return;
        }

        my $current_item = shift @{$pending_queries{fifo}};
        if ($current_item) {
            my $recv_time = time();
            my $latency = $recv_time - $current_item->{sent_at};
            
            if ($latency > $CONFIG{slow_threshold}) {
                log_warn("slow_response", $latency, $current_item->{chan});
            }
            
            log_debug(sprintf("Received [Chan: %s] Latency: %.4fs - Response: %s", 
                ($current_item->{chan} // "none"), $latency, $response));

            my $final_reply = ($response =~ /status=/) ? "ERR message=NOTALLOWED" : $response;
            send_to_squid($current_item->{chan}, $final_reply);
        }
    }
}

sub retry_or_fail {
    my ($item) = @_;
    $item->{retries}++;
    if ($item->{retries} < $max_retries) {
		log_debug("Retrying Chan: $item->{chan} (Attempt $item->{retries}/$max_retries)");        
		unshift @queue, $item; 
    } else { 
        log_debug("Max retries reached for Chan: $item->{chan}. Sending $default_reply.");
        send_to_squid($item->{chan}, $default_reply); 
    }
}

sub send_to_squid {
    my ($chan, $msg) = @_;
    my $out = ($chan ne "") ? "$chan $msg" : ($msg || $default_reply);
    print STDOUT "$out\n";
}

sub close_socket {
    return unless $socket;
    log_warn("socket_closed_" . ($_[0] || "unknown"), 0, "sys");
    $sel->remove($socket); 
    $socket->close(); 
    $socket = undef;
    $socket_buf = '';

    # Reset retry timer to allow immediate reconnection attempt
    $last_retry = time(); 

    # Move all pending requests back to the main queue
    my $inflight = $pending_queries{fifo}; 
    $pending_queries{fifo} = [];
    foreach my $item (@$inflight) { retry_or_fail($item); }
    
    $CONFIG{conn_established} = undef; # Reset timer for next connection
    $CONFIG{current_peer} = "none";
}
