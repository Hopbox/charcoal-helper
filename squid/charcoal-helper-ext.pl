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
our $VERSION = '1.2.4';
use vars qw($h $d $c $f); # -h (help), -d (debug), -c (compat), -f (fail-mode)
use IO::Socket qw(SO_KEEPALIVE IPPROTO_TCP TCP_KEEPIDLE TCP_KEEPINTVL TCP_KEEPCNT);
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
my $last_tls_fail = 0;
my $tls_retry_interval = 20; # 1 Hour (adjust as needed for your fleet)
# --- HEARTBEAT STATE ---
my $hb_count   = 0;
my $hb_latency = 0;
my $hb_errors  = 0;
my $hb_start   = get_now();
my $hb_interval = 60; # Send heartbeat at least every 60s
my $last_cfg_refresh = get_now();
my $cfg_refresh_interval = 300; # Auto-refresh every 5 minutes (adjust as needed)

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

# --- LOGGING ---
my $LOG_SOCK_PATH = '/dev/log';
socket(my $lp, PF_UNIX, SOCK_DGRAM, 0);
my $log_dest = sockaddr_un($LOG_SOCK_PATH);

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
        $CONFIG{queue_timeout}    = `uci -q get charcial.main.queue_timeout`    || 10;
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

$CONFIG{original_tls_pref} = $CONFIG{use_tls};

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
    log_debug("Configuration loaded: Version: $VERSION, Server=$charcoal_server, Port=$charcoal_port, Debug=$DEBUG, Squid Ver=$squidver");
    log_debug("Engine: $SOCKET_CLASS, Precision: $prec_mode, TLS: $tls_stat, TLS Toggle: $CONFIG{use_tls}, TLS Verify: $CONFIG{tls_verify}");
    log_debug("Connection Timeout: $timeout, Slow Threshold: $CONFIG{slow_threshold}, Default Reply: $default_reply");
}

refresh_settings();


sub get_conn_meta {
    my $tls_status = ($CONFIG{use_tls} || 0) == 1 ? "TLS" : "Plain";
    my $v_status   = (($CONFIG{use_tls} || 0) == 1 && ($CONFIG{tls_verify} || 0) == 1) ? "+Verify" : "-Verify";
    
    # Identify the actual socket class active in memory
    my $active_engine = "None";
    if (defined $socket) {
        $active_engine = (split(/::/, ref($socket)))[-1] || "Socket";
    }
    
    # Use the selected_ip stored in current_peer
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
    my $msg = shift;
    my $now = get_now();
    my ($sec,$min,$hour,$mday,$mon,$year) = localtime();
    my $ms = sprintf("%03d", ($now - int($now)) * 1000);
    printf STDERR "[%04d-%02d-%02d %02d:%02d:%02d.%s] Charcoal: %s\n", 
        $year+1900, $mon+1, $mday, $hour, $min, $sec, $ms, $msg;
        
    my $pri = 31; # daemon.debug
    my $log_msg = "<$pri>charcoal-helper: " . $msg;
    send($lp, $log_msg, 0, $log_dest);
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

    # --- 0. Periodic Config Refresh (Safety Net) ---
    if ($now - $last_cfg_refresh >= $cfg_refresh_interval) {
        $last_cfg_refresh = $now;
        # Only refresh if we are currently disconnected or failing
        # (This prevents interrupting a perfectly good active socket)
        if (!$socket) {
            log_debug("Periodic auto-refresh of settings...");
            refresh_settings();
        }
    }
    
    # --- HEARTBEAT TIMER CHECK ---
    if ($now - $hb_start >= $hb_interval) {
        flush_heartbeat();
    }
    
    my $queue_timeout = $CONFIG{queue_timeout} // 10;
    
    # --- 1. Connection & Fallback Management ---
    if (!$socket && @queue) {
        
        my $failed_attempts = $now - ($CONFIG{conn_established} || 0);
        
        if ($failed_attempts > 3) {
            $queue_timeout = 3;  # Aggressive drain after 3 failed attempts
        }
        
        my $drained = 0;
        
        while (@queue && ($now - $queue[0]->{queued_at} > $queue_timeout)) {
            my $stale = shift @queue;
            send_to_squid($stale->{chan}, $default_reply);
            $drained++;
        }
        
        if ($drained > 0){
            log_warn("queue_timeout_drained count=$drained", 0, "sys");
        }
        if ($now - $last_retry >= 1) { 
            $last_retry = $now;
            
            # --- FUTURE READINESS: IPv6 MIGRATION ---
            # To support IPv6, replace 'gethostbyname' with 'Socket::getaddrinfo'.
            # 'gethostbyname' only returns IPv4 addresses.
            my @host_info = gethostbyname($charcoal_server);
            
            if (@host_info) {
                # DNS Randomization: Distributes load across backend IPs
                my @raw_ips = @host_info[4..$#host_info];
                if (@raw_ips) {
                    my $all_ips = join(', ', map { inet_ntoa($_) } @raw_ips);
                    my $selected_ip = inet_ntoa($raw_ips[rand @raw_ips]);
                    log_debug("Selected $selected_ip randomly from $all_ips");
                                # SELF-HEALING: If TLS was disabled, check if it's time to try again
                    if ($CONFIG{use_tls} == 0 && ($CONFIG{original_tls_pref} // 0) == 1) {
                        if ($now - $last_tls_fail > $tls_retry_interval) {
                            log_debug("TLS Retry Timer reached. Attempting to re-enable TLS...");
                            $CONFIG{use_tls} = 1;
                        }
                    }
                
                    log_debug("Attempting connection to $selected_ip (Target: $charcoal_server)...");
                
                    my $should_use_tls = ($HAS_SSL && ($CONFIG{use_tls} || 0) == 1) ? 1 : 0;
                
                    # Setup core options for the socket
                    my %opts = ( 
                        PeerAddr => $selected_ip, 
                        PeerPort => $charcoal_port, 
                        Proto    => 'tcp', 
                        Blocking => 1, 
                        Timeout  => 2 
                    );

                    my $class;
                    if ($should_use_tls) {
                        log_debug("Engine: IO::Socket::SSL (TLS/Blocking)...");
                        $class = "IO::Socket::SSL";
                    
                        # SSL-Specific Handshake options
                        $opts{SSL_verify_mode}   = ($CONFIG{tls_verify} || 0);
                        $opts{SSL_verifycn_name} = $charcoal_server; # Required for SNI with IP-based connection
                        $opts{SSL_ciphersuites}  = $CONFIG{tls_ciphersuites} if $CONFIG{tls_ciphersuites};
                        $opts{SSL_cipher_list}   = $CONFIG{tls_cipher_list}  if $CONFIG{tls_cipher_list};
                    } else {
                        log_debug("Engine: Standard IPv4 (Blocking)...");
                        # --- FUTURE READINESS: IPv6 MIGRATION ---
                        # When moving to dual-stack, change the fallback to 'IO::Socket::IP'.
                        # For current IPv4-only RB750Gr3 fleet, 'INET' is leaner and more stable.
                        $class = $HAS_IP ? "IO::Socket::IP" : "IO::Socket::INET";
                    }

                    # Attempt the socket creation
                    $socket = $class->new(%opts);
                
                    if (!$socket) {
                        # Capture specific SSL error vs generic socket error
                        my $err = ($should_use_tls && $IO::Socket::SSL::SSL_ERROR) ? $IO::Socket::SSL::SSL_ERROR : ($! || "Connection Refused");
                        log_debug("Connect to $selected_ip failed: $err.");
                    
                        if ($should_use_tls) {
                            log_debug("TLS failure. Disabling 'use_tls' for next retry to ensure service continuity.");
                            $CONFIG{use_tls} = 0;
                            $last_tls_fail = $now;
                        }
                    } else {
                        # SUCCESS: Move to Non-Blocking state for Squid's IO loop
                        setsockopt($socket, SOL_SOCKET, SO_LINGER, pack("ii", 1, 0));
                        setsockopt($socket, SOL_SOCKET, SO_KEEPALIVE, 1);
                        # TCP Keepalive: Detect dead servers within 60s
                        eval {
                            setsockopt($socket, IPPROTO_TCP, TCP_KEEPIDLE, 30);
                            setsockopt($socket, IPPROTO_TCP, TCP_KEEPINTVL, 10);
                            setsockopt($socket, IPPROTO_TCP, TCP_KEEPCNT, 3);
                        }; # May fail on non-Linux, hence eval
                        $socket->blocking(0); 
                        $sel->add($socket);
                    
                        # Use the actual connected IP rather than peerhost() to avoid reverse DNS delays
                        $CONFIG{current_peer} = $selected_ip;
                        $CONFIG{conn_established} = get_now();
                    
                        log_debug("Connection established to " . get_conn_meta() . " (Non-Blocking). Ready.");
                    }
                } else {
                    log_debug("DNS result returned no valid IP addresses in the host info list.");
                }
            } else {
                log_debug("DNS Resolution failed for $charcoal_server. Retrying in next cycle.");
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
                $item->{queued_at} = $item->{queued_at} || get_now();  # ✅ Preserve original or set now
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
    push @queue, { 
        chan        => $chan, 
        payload     => $payload, 
        retries     => 0, 
        queued_at   => get_now()
    };
    return 1;
}

sub handle_socket_read {
    return unless (defined $socket && $socket->opened);
    my $data;
    my $rv = sysread($socket, $data, 8192);
    if (!defined($rv)) {
        # Handle connection reset/broken pipe
        if ($!{ECONNRESET} || $!{EPIPE} || $!{ENOTCONN}) {
            close_socket("peer_reset_$!");
            return;
        }
        return if ($!{EAGAIN} || $!{EWOULDBLOCK});
        close_socket("read_error_$!"); return;
    } elsif ($rv == 0) {
        close_socket("EOF_idle_timeout"); return;
    }

    $socket_buf .= $data;
    
    # CRITICAL: Timeout stale queries before processing new responses
    my $now = get_now();
    while (@{$pending_queries{fifo}} && 
           ($now - $pending_queries{fifo}[0]{sent_at}) > $CONFIG{timeout} // 5.0) {
        my $stale = shift @{$pending_queries{fifo}};
        log_warn("query_expired", $now - $stale->{sent_at}, $stale->{chan});
        retry_or_fail($stale);
    }
    
    while ($socket_buf =~ s/^(.*?)[\r\n]+//) {
        my $response = $1;
        $response =~ s/^\s+|\s+$//g;
        next if $response eq "";
        my $current_item = shift @{$pending_queries{fifo}};
        if ($current_item) {
            my $latency = get_now() - $current_item->{sent_at};
            
            # --- UPDATE HEARTBEAT COUNTERS ---
            $hb_count++;
            $hb_latency += $latency;
            
            # If we hit 100 samples, flush the heartbeat to /dev/log
            if ($hb_count >= 100) {
                my $avg = $hb_count > 0 ? ($hb_latency / $hb_count) : 0;
                my $duration = get_now() - $hb_start;
                
                # pri 30 = daemon.info
                my $hb_msg = sprintf("<30>charcoal-helper: v=\"%s\" msg=\"heartbeat\" samples=%d avg_lat=%.4f errors=%d wall_clock=%.2fs server=\"%s\"", 
                                     $VERSION, $hb_count, $avg, $hb_errors, $duration, get_conn_meta());
                send($lp, $hb_msg, 0, $log_dest);
                
                # Reset batch
                $hb_count = 0; $hb_latency = 0; $hb_errors = 0; $hb_start = get_now();
            }
            # --- END HEARTBEAT ---
            
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
    
    $hb_errors++; # Count this toward our heartbeat error rate
    
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
    my $now = get_now();
    return unless defined $socket;
    log_warn("socket_closed_$reason", 0, "sys");
    $sel->remove($socket) if $sel->exists($socket);
    eval { $socket->shutdown(2) if $socket->opened; $socket->close(); };
    $socket = undef; $socket_buf = ''; $last_retry = $now;
    my $inflight = $pending_queries{fifo};
    $pending_queries{fifo} = [];
    foreach my $item (@$inflight) { 
        my $age = $now - ($item->{queued_at} || $now);
        if ($age > $CONFIG{timeout}){
            send_to_squid($item->{chan}, $default_reply); # Don't retry old queries
        }
        else {
            retry_or_fail($item); 
        }
    }
    $CONFIG{conn_established} = undef;
    $CONFIG{current_peer} = "none";
}

sub flush_heartbeat {
    my $now = get_now();
    my $duration = $now - $hb_start;
    
    # Only log if some time has passed or we have data
    if ($hb_count > 0 || $hb_errors > 0) {
        my $avg = $hb_count > 0 ? ($hb_latency / $hb_count) : 0;
        my $conn_meta = get_conn_meta();
        
        # We use daemon.info (pri 30) for the pulse
        my $hb_msg = sprintf("<30>charcoal-helper: v=\"%s\" msg=\"heartbeat\" samples=%d avg_lat=%.4f system_errors=%d wall_clock=%.2fs server=\"%s\"", 
                             $VERSION, $hb_count, $avg, $hb_errors, $duration, $conn_meta);
        send($lp, $hb_msg, 0, $log_dest);
    }

    # Reset batch
    $hb_count = 0; $hb_latency = 0; $hb_errors = 0; $hb_start = $now;
}
