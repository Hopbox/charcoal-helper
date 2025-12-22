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
use vars qw($h $d $c $f); # -h (help), -d (debug), -c (compat), -f (fail-mode)
use IO::Socket;
use IO::Select;
use Time::HiRes qw(time);

$| = 1; 

# --- ARGUMENTS & HELP LOGIC ---
if ($h) {
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

sub log_debug {
    return unless $DEBUG;
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d] Charcoal: %s\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, shift;
}

log_debug("Started. Server: $charcoal_server, API: $apikey, Fail-Mode: $default_reply, Squid Ver: $squidver");

# --- MAIN LOOP & LOGIC ---
my $socket          = undef;
my $sel             = IO::Select->new(\*STDIN);
my @queue           = ();    
my %pending_queries = ( fifo => [] ); 
my $connect_start   = 0;
my $last_retry      = 0;

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
                log_debug("Connected to node: " . ($socket->peerhost() || "unknown"));
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
    my $response = <$socket>;
    if (!defined $response) { close_socket("Socket EOF"); return; }
    
    $response =~ s/^\s+|\s+$//g; 
    return if $response eq "";

    log_debug("Received from server - response: $response");
    
    if ($response =~ /Timed Out/i) {
        close_socket("Server-side Internal Timeout");
        return;
    }

    my $current_item = shift @{$pending_queries{fifo}};
    return unless $current_item;

    $response = "ERR message=NOTALLOWED" if ($response =~ /status=/);
    send_to_squid($current_item->{chan}, $response);
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
    log_debug("Closing socket: " . ($_[0] || "Unknown"));
    $sel->remove($socket); 
    $socket->close(); 
    $socket = undef;

    # Reset retry timer to allow immediate reconnection attempt
    $last_retry = 0; 

    # Move all pending requests back to the main queue
    my $inflight = $pending_queries{fifo}; 
    $pending_queries{fifo} = [];
    foreach my $item (@$inflight) { retry_or_fail($item); }
}
