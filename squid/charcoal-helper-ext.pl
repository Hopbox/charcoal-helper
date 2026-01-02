#!/usr/bin/perl -s
#
# Charcoal - External ACL helper for squid
# Version: 1.2.2 (Fully Optimized & Transparent)
# Copyright (C) 2012-2026 Unmukti Technology Pvt Ltd <info@unmukti.in>
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; either version 2 of the License, or
# (at your option) any later version.
#

use strict;
use warnings;
our $VERSION = '1.2.2';
use vars qw($h $d $c $f); # -h (help), -d (debug), -c (compat), -f (fail-mode)
use IO::Socket;
use IO::Select;
use Socket;

# --- BOOTSTRAP: MODULE DISCOVERY ---
my $HAS_HIRES = eval { require Time::HiRes; 1 };
sub get_now { return $HAS_HIRES ? Time::HiRes::time() : time(); }

# --- BOOTSTRAP: INDEPENDENT MODULE DISCOVERY ---
my $HAS_SSL = eval { require IO::Socket::SSL; 1 };
my $HAS_IP  = eval { require IO::Socket::IP;  1 };

# Set the primary engine for display/default purposes
my $SOCKET_CLASS = $HAS_SSL ? "IO::Socket::SSL" : ($HAS_IP ? "IO::Socket::IP" : "IO::Socket::INET");

# If IO::Socket::IP isn't found, we MUST load INET as the fallback
if (!$HAS_IP) {
    require IO::Socket::INET;
}

$| = 1; 

# --- GLOBALS & STATE ---
my $socket          = undef;
my $sel             = IO::Select->new(\*STDIN);
my @queue           = ();    
my %pending_queries = ( fifo => [] ); 
my $last_retry      = 0;
my $socket_buf      = '';

# Declarations for shared configuration variables
my ($DEBUG, $squidver, $apikey, $charcoal_server, $charcoal_port, $timeout, $default_reply);

my $apikey_arg = @ARGV ? shift @ARGV : undef;
$squidver = $c ? 2 : 3;
my $prec_mode = $HAS_HIRES ? "High (Time::HiRes)" : "Low (Standard)";
my $tls_stat  = $HAS_SSL   ? "Available (IO::Socket::SSL)" : "Disabled (Missing Module)";

# --- INIT ---
# --- ARGUMENTS & HELP (REINSTATED & ENHANCED) ---
if ($h) {
    
    print STDERR "Charcoal External ACL Helper (Perl) v$VERSION\n";
    print STDERR "=====================================================\n";
    print STDERR "Engine      : $SOCKET_CLASS\n";
    print STDERR "Preci       : $prec_mode\n";
    print STDERR "TLS Support : $tls_stat\n";
    print STDERR "Squid Mode  : " . ($squidver == 2 ? "Legacy (v2.x)" : "Modern (v3.x+)") . "\n";
    print STDERR "-----------------------------------------------------\n";
    print STDERR "Usage: $0 [-cdfh] <api-key>\n";
    print STDERR "  -c          : Force Squid 2.x compatibility mode\n";
    print STDERR "  -d          : Enable verbose debug logging to STDERR\n";
    print STDERR "  -f=<reply>  : Failover response (default: OK)\n";
    print STDERR "  -h          : Show this extended help message\n";
    print STDERR "=====================================================\n";
    exit 0;
}

# --- CONFIG LOADER ---
my %CONFIG;
sub load_config {
    my $uci_bin = `which uci 2>/dev/null`;
    if ($uci_bin) {
        $CONFIG{server}           = `uci -q get charcoal.main.server`           || 'active.charcoal.io';
        $CONFIG{port}             = `uci -q get charcoal.main.port`             || '6603';
        $CONFIG{api_key}          = `uci -q get charcoal.main.api_key`          || 'MISSING_KEY';
        $CONFIG{ver}              = `uci -q get charcoal.main.squid_version`    || '3';
        $CONFIG{debug}            = `uci -q get charcoal.main.debug`            || 0;
        $CONFIG{max_retries}      = `uci -q get charcoal.main.max_retries`      || 2;
        $CONFIG{timeout}          = `uci -q get charcoal.main.timeout`          || 2;
        $CONFIG{slow_threshold}   = `uci -q get charcoal.main.slow_threshold`   || 0.1;
        $CONFIG{default_reply}    = `uci -q get charcoal.main.default_reply`    || 'OK';
        $CONFIG{use_tls}          = `uci -q get charcoal.main.use_tls`          || 0;
        $CONFIG{tls_verify}       = `uci -q get charcoal.main.tls_verify`       || 0;
        $CONFIG{tls_ciphersuites} = `uci -q get charcoal.main.tls_ciphersuites`;
        $CONFIG{tls_cipher_list}  = `uci -q get charcoal.main.tls_cipher_list`;
    } else {
        my $file = -e "/etc/charcoal.conf" ? "/etc/charcoal.conf" : "./charcoal.conf";
        if (open(my $fh, '<', $file)) {
            while (<$fh>) {
                chomp; next if /^\s*#/ || /^\s*$/;
                my ($k, $v) = split(/\s*=\s*/, $_, 2);
                $v =~ s/^\s+|\s+$//g;
                $CONFIG{$k} = $v if $k;
            }
            close($fh);
        }
    }
    foreach (keys %CONFIG) { 
        if (defined $CONFIG{$_}) {
            chomp $CONFIG{$_}; 
            $CONFIG{$_} =~ s/^\s+|\s+$//g; 
        }
    }
}

sub refresh_settings {
    load_config();
    $DEBUG           = $d || $CONFIG{debug} || 0;
    $squidver        = $c ? 2 : ($CONFIG{ver} || 3);
    $apikey          = $apikey_arg || $CONFIG{api_key} || 'MISSING_KEY';
    $charcoal_server = $CONFIG{server} || 'active.charcoal.io';
    $charcoal_port   = $CONFIG{port} || '6603';
    $timeout         = $CONFIG{timeout} || 3;
    $default_reply   = $f || $CONFIG{default_reply} || 'OK';
#    $CONFIG{slow_threshold} = (defined $CONFIG{slow_threshold} && $CONFIG{slow_threshold} ne "") ? 0 + $CONFIG{slow_threshold} : 0.1;
    log_debug("Configuration loaded: Server=$charcoal_server, Port=$charcoal_port, Debug=$DEBUG, Squid Ver=$squidver");
    log_debug("Engine: $SOCKET_CLASS, Precision: $prec_mode, TLS: $tls_stat, TLS Toggle: $CONFIG{use_tls}, TLS Verify: $CONFIG{tls_verify}");
    log_debug("Connection Timeout: $timeout, Slow Threshold: $CONFIG{slow_threshold}, Default Reply: $default_reply");
}

refresh_settings();

# --- LOGGING ---
my $LOG_SOCK_PATH = '/dev/log';
socket(my $lp, PF_UNIX, SOCK_DGRAM, 0);
my $log_dest = sockaddr_un($LOG_SOCK_PATH);

sub get_conn_meta {
    my $tls_status = ($CONFIG{use_tls} || 0) == 1 ? "TLS" : "Plain";
    my $v_status   = (($CONFIG{use_tls} || 0) == 1 && ($CONFIG{tls_verify} || 0) == 1) ? "+Verify" : "-Verify";
    
    # 1. Determine the actual active class of the current socket
    my $active_engine = "None";
    if (defined $socket) {
        # ref($socket) returns the actual class (e.g., IO::Socket::IP)
        $active_engine = (split(/::/, ref($socket)))[-1] || "Socket";
    }
    
    return sprintf("%s [%s %s %s]", 
        ($CONFIG{current_peer} || "none"), $active_engine, $tls_status, $v_status);
}

sub log_warn {
    my ($msg, $latency, $chan) = @_;
    $latency //= 0;
    
    my $now = get_now();
    # This line stays: it calculates how long the socket has been open
    my $conn_age = defined $CONFIG{conn_established} ? int($now - $CONFIG{conn_established}) : 0;
    
    # This line stays: it gets the [IP TLS Verify] string
    my $conn_meta = get_conn_meta();

    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    my $ms = sprintf("%03d", ($now - int($now)) * 1000);
    
    # The printf STILL includes %ds for $conn_age
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d.%s] Charcoal: !!! %s [%s] Latency: %.4fs Age: %ds Peer: %s !!!\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, $ms, 
        uc($msg), ($chan // '0'), $latency, $conn_age, $conn_meta;

    # Structured logging for /dev/log also includes age
    my $pri = 28; # daemon.warn
    my $structured = sprintf("<%d>charcoal-helper: v=\"%s\" msg=\"%s\" latency=%.4f chan=%s server=\"%s\" age=%d", 
                             $pri, $VERSION, $msg, $latency, ($chan // 0), $conn_meta, $conn_age);
    send($lp, $structured, 0, $log_dest);
}

sub log_debug {
    return unless $DEBUG;
    my $now = get_now();
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    my $ms = sprintf("%03d", ($now - int($now)) * 1000);
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d.%s] Charcoal: %s\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, $ms, shift;
}

$CONFIG{current_peer} = "none";
$CONFIG{conn_established} = undef;

$SIG{TERM} = $SIG{INT} = sub { exit(0); };
$SIG{HUP} = sub { 
    refresh_settings(); 
    close_socket("config_reload") if defined $socket;
    log_debug("SIGHUP: Settings applied. Next connect will use: $charcoal_server");
};

# --- MAIN LOOP ---
while (1) {
    my $now = get_now();

    # --- 1. Connection & Fallback Management ---
    if (!$socket && @queue) {
        if ($now - $last_retry >= 1) { 
            $last_retry = $now;
            log_debug("Connecting to $charcoal_server:$charcoal_port...");
            
            my $should_use_tls = ($HAS_SSL && ($CONFIG{use_tls} || 0) == 1) ? 1 : 0;
            my %opts = ( PeerAddr => $charcoal_server, PeerPort => $charcoal_port, Proto => 'tcp', Blocking => 1, Timeout => 2 );
            my $class;

            if ($should_use_tls) {
                log_debug("Attempting TLS (Blocking)...");
                $class = "IO::Socket::SSL";
                $opts{SSL_verify_mode} = ($CONFIG{tls_verify} || 0);
                $opts{SSL_ciphersuites} = $CONFIG{tls_ciphersuites} if $CONFIG{tls_ciphersuites};
                $opts{SSL_cipher_list}  = $CONFIG{tls_cipher_list}  if $CONFIG{tls_cipher_list};
            } else {
                log_debug("Using Plain-text (Blocking)...");
                $class = $HAS_IP ? "IO::Socket::IP" : "IO::Socket::INET";
                log_debug("Engine $class selected...");
            }

            $socket = $class->new(%opts);
            
            if (!$socket) {
                my $err = $! || "Connection Refused";
                log_debug("Connect failed: $err.");
                if ($should_use_tls) {
                    log_debug("TLS connection failed. Dropping 'use_tls' to 0.");
                    $CONFIG{use_tls} = 0;
                }
            } else {
                $socket->blocking(0); 
                $sel->add($socket);
                $CONFIG{current_peer} = $socket->peerhost() || $charcoal_server;
                $CONFIG{conn_established} = get_now();
                log_debug("Connection established to " . get_conn_meta() . " (Non-Blocking). Ready.");
            }
        }
    }
    
    # --- 2. Multiplexing (Read) ---
    my @ready = $sel->can_read(0.01);
    foreach my $fh (@ready) {
        if ($fh == \*STDIN) { exit(0) unless handle_stdin(); }
        elsif ($socket && $fh == $socket) { handle_socket_read(); }
    }

    # --- 3. Transmission (Send) ---
    if ($socket && @queue && $sel->can_write(0)) {
        while (my $item = shift @queue) {
            if ($socket->opened) {
                log_debug("Sending to server $CONFIG{current_peer}: $item->{payload}");
                $item->{sent_at} = get_now(); 
                $item->{peer_info} = get_conn_meta(); # Capture meta at send-time
                print $socket $item->{payload} . "\r\n";
                push @{$pending_queries{fifo}}, $item;
            } else {
                unshift @queue, $item; last;
            }
        }
    }
}

# --- SUBS ---

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
        return if ($!{EAGAIN} || $!{EWOULDBLOCK});
        close_socket("read_error_$!"); return;
    } elsif ($rv == 0) {
        close_socket("EOF_idle_timeout"); return;
    }

    $socket_buf .= $data;
    while ($socket_buf =~ s/^(.*?)[\r\n]+//) {
        my $response = $1;
        $response =~ s/^\s+|\s+$//g;
        next if $response eq "";
        my $current_item = shift @{$pending_queries{fifo}};
        if ($current_item) {
            my $latency = get_now() - $current_item->{sent_at};
                        
            my $threshold = $CONFIG{slow_threshold} || 0.1;
            if ($latency > $threshold) {
            # IMPORTANT: Pass only the raw number here!
                log_warn("slow_response", $latency, $current_item->{chan});
            }
            # We still use peer_meta here because it makes the debug trace useful.
            if ($DEBUG) {
                my $peer_meta = $current_item->{peer_info} || get_conn_meta();
                log_debug(sprintf("Received [Chan: %s] [Peer: %s] Latency: %.4fs - Response: %s", 
                    ($current_item->{chan} // "none"), 
                    $peer_meta, 
                    $latency, 
                    $response));
            }

            my $final_reply = ($response =~ /status=/) ? "ERR message=NOTALLOWED" : $response;
            $final_reply = "ERR message=NOTALLOWED" if ($response eq "0");
            send_to_squid($current_item->{chan}, $final_reply);
        }
    }
}

sub retry_or_fail {
    my ($item) = @_;
    $item->{retries}++;
    if ($item->{retries} < ($CONFIG{max_retries} || 2)) {
        unshift @queue, $item; 
    } else { 
        send_to_squid($item->{chan}, $default_reply); 
    }
}

sub send_to_squid {
    my ($chan, $msg) = @_;
    print STDOUT (($chan ne "") ? "$chan $msg" : ($msg || $default_reply)) . "\n";
}

sub close_socket {
    my $reason = shift || "unknown";
    return unless defined $socket;
    log_warn("socket_closed_$reason", 0, "sys");
    $sel->remove($socket) if $sel->exists($socket);
    eval { $socket->shutdown(2) if $socket->opened; $socket->close(); };
    $socket = undef; $socket_buf = ''; $last_retry = get_now();
    my $inflight = $pending_queries{fifo};
    $pending_queries{fifo} = [];
    foreach my $item (@$inflight) { retry_or_fail($item); }
    $CONFIG{conn_established} = undef;
    $CONFIG{current_peer} = "none";
}
