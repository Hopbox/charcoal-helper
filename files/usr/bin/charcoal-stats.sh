#!/bin/sh
# /usr/bin/charcoal-stats.sh

echo "=== Charcoal Helper Stats ==="
echo "Version: $(grep "our \$VERSION" /usr/lib/squid/charcoal-helper-ext.pl 2>/dev/null | cut -d"'" -f2)"
echo "Helpers Running: $(ps aux | grep charcoal-helper-ext.pl | grep -v grep | wc -l)"
echo "Current Server: $(uci get charcoal.main.server 2>/dev/null || echo 'Not configured')"
echo ""

echo "=== Last 100 Events Analysis ==="
logread | grep "charcoal-helper:" | tail -100 | awk '
BEGIN {
    heartbeats=0; slow=0; socket_closed=0; queue_timeout=0; query_expired=0;
    hb_total_lat=0; hb_samples_total=0; hb_query_count=0;
    slow_total_lat=0; slow_count_num=0; max_slow_lat=0; min_slow_lat=0;
    errors=0; sys_errors=0;
}

# Heartbeat messages
/msg="heartbeat"/ {
    heartbeats++;
    # Extract avg_lat value
    for (i=1; i<=NF; i++) {
        if ($i ~ /^avg_lat=/) {
            sub(/avg_lat=/, "", $i);
            lat = $i + 0;
            hb_total_lat += lat;
            hb_samples_total++;
        }
        if ($i ~ /^samples=/) {
            sub(/samples=/, "", $i);
            hb_query_count += ($i + 0);
        }
    }
}

# Slow response messages
/msg="slow_response"/ {
    slow++;
    # Extract latency value
    for (i=1; i<=NF; i++) {
        if ($i ~ /^latency=/) {
            sub(/latency=/, "", $i);
            lat = $i + 0;
            slow_total_lat += lat;
            slow_count_num++;
            if (lat > max_slow_lat) max_slow_lat = lat;
            if (min_slow_lat == 0 || lat < min_slow_lat) min_slow_lat = lat;
        }
    }
}

# Socket closures
/msg="socket_closed_/ {
    socket_closed++;
    # Extract reason from msg field
    for (i=1; i<=NF; i++) {
        if ($i ~ /^msg="socket_closed_/) {
            reason = $i;
            sub(/msg="socket_closed_/, "", reason);
            sub(/"$/, "", reason);
            reasons[reason]++;
        }
    }
}

# Queue timeouts
/msg="queue_timeout_drained"/ {
    queue_timeout++;
    for (i=1; i<=NF; i++) {
        if ($i ~ /^count=/) {
            sub(/count=/, "", $i);
            queue_drained += ($i + 0);
        }
    }
}

# Query expiry
/msg="query_expired/ {
    query_expired++;
}

# System errors
/system_errors=/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /^system_errors=/) {
            sub(/system_errors=/, "", $i);
            sys_errors += ($i + 0);
        }
    }
}

# ERROR level
/ERROR/ { errors++; }

END {
    # Heartbeats
    printf "Heartbeats: %d\n", heartbeats;
    if (hb_samples_total > 0) {
        avg_hb = hb_total_lat / hb_samples_total;
        printf "  Average response latency: %.4fs (from %d queries)\n", avg_hb, hb_query_count;
    } else {
        printf "  (No latency data captured)\n";
    }
    
    # Slow responses
    printf "\nSlow Responses: %d (threshold exceeded)\n", slow;
    if (slow_count_num > 0) {
        avg_slow = slow_total_lat / slow_count_num;
        printf "  Min: %.4fs, Max: %.4fs, Avg: %.4fs\n", min_slow_lat, max_slow_lat, avg_slow;
    }
    
    # Socket closures
    if (socket_closed > 0) {
        printf "\nSocket Closures: %d\n", socket_closed;
        for (reason in reasons) {
            printf "  %s: %d\n", reason, reasons[reason];
        }
    }
    
    # Issues
    if (queue_timeout > 0) {
        printf "\nQueue Timeouts: %d events (%d queries drained)\n", queue_timeout, queue_drained;
    }
    
    if (query_expired > 0) {
        printf "\nQuery Expired: %d\n", query_expired;
    }
    
    if (sys_errors > 0) {
        printf "\nSystem Errors: %d\n", sys_errors;
    }
    
    if (errors > 0) {
        printf "\n!!! ERRORS: %d !!!\n", errors;
    }
}
'

echo ""
echo "=== Backend Server Distribution ==="
logread | grep "charcoal-helper:" | tail -100 | grep -o 'server="[^"]*"' | sort | uniq -c | sort -rn

echo ""
echo "=== Connection Age Distribution ==="
logread | grep "charcoal-helper:" | tail -100 | awk '
/age=/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /^age=/) {
            sub(/age=/, "", $i);
            age = $i + 0;
            if (age < 60) bucket="<1min";
            else if (age < 300) bucket="1-5min";
            else if (age < 900) bucket="5-15min";
            else if (age < 1800) bucket="15-30min";
            else bucket=">30min";
            ages[bucket]++;
        }
    }
}
END {
    for (b in ages) {
        printf "%s: %d\n", b, ages[b];
    }
}
' | sort

echo ""
echo "=== Recent Issues (Last 5) ==="
logread | grep "charcoal-helper:" | grep -E "queue_timeout|query_expired|socket_closed|ERROR" | tail -5

echo ""
echo "=== Performance Summary ==="
logread | grep "charcoal-helper:" | tail -200 | awk '
BEGIN {
    hb_lat_sum = 0; hb_count = 0; total_queries = 0;
    slow_sum = 0; slow_count = 0; slow_max = 0; slow_min = 0;
}

# Heartbeat avg_lat
/msg="heartbeat"/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /^avg_lat=/) {
            sub(/avg_lat=/, "", $i);
            hb_lat_sum += ($i + 0);
            hb_count++;
        }
        if ($i ~ /^samples=/) {
            sub(/samples=/, "", $i);
            total_queries += ($i + 0);
        }
    }
}

# Slow response latency
/msg="slow_response"/ {
    for (i=1; i<=NF; i++) {
        if ($i ~ /^latency=/) {
            sub(/latency=/, "", $i);
            lat = $i + 0;
            slow_sum += lat;
            slow_count++;
            if (lat > slow_max) slow_max = lat;
            if (slow_min == 0 || lat < slow_min) slow_min = lat;
        }
    }
}

END {
    printf "Overall Health (last 200 events):\n";
    
    if (hb_count > 0 && total_queries > 0) {
        avg_hb = hb_lat_sum / hb_count;
        printf "  Normal queries: ~%d at %.4fs avg\n", total_queries, avg_hb;
    } else if (hb_count == 0 && total_queries == 0) {
        printf "  Normal queries: No heartbeat data\n";
    }
    
    if (slow_count > 0) {
        avg_slow = slow_sum / slow_count;
        if (total_queries > 0) {
            slow_pct = (slow_count * 100.0 / total_queries);
            printf "  Slow queries: %d (%.1f%% of total)\n", slow_count, slow_pct;
        } else {
            printf "  Slow queries: %d\n", slow_count;
        }
        printf "    Range: %.4fs - %.4fs (avg %.4fs)\n", slow_min, slow_max, avg_slow;
        
        # Health indicator
        if (total_queries > 0) {
            slow_pct = (slow_count * 100.0 / total_queries);
            if (slow_pct > 20) {
                printf "  ⚠️  WARNING: >20%% slow responses - server overloaded?\n";
            } else if (slow_pct > 10) {
                printf "  ⚠️  CAUTION: >10%% slow responses\n";
            } else if (avg_hb > 0.1) {
                printf "  ⚠️  INFO: Average latency >100ms but acceptable\n";
            } else {
                printf "  ✓ Performance looks good\n";
            }
        }
    } else {
        if (total_queries > 0) {
            printf "  ✓ No slow responses detected - excellent!\n";
        }
    }
    
    if (hb_count == 0 && slow_count == 0 && total_queries == 0) {
        printf "  ⚠️  No performance data in last 200 events\n";
    }
}
'

echo ""
echo "=== Connection Lifecycle ==="
echo "Connection Establishments:"
logread | grep "Connection established" | grep "charcoal-helper:" | tail -100

echo ""
echo "Connection Durations (from socket closures):"
logread | grep "socket_closed" | grep "charcoal-helper:" | \
  sed 's/.*age=\([0-9]*\).*/\1/' | \
  awk '{
    age = int($1/60);
    buckets[age]++;
  }
  END {
    for (b in buckets) {
      printf "  ~%d min: %d connections\n", b, buckets[b];
    }
  }' | sort -n
