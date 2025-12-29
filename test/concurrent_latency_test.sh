#!/bin/bash
# stress_test_wan_parallel.sh

HELPER_BIN=$1
API_KEY=$2
NUM_REQUESTS=1000
CONCURRENCY=50 # How many to fire at once over the WAN
LATENCY_CSV="latency_wan.csv"
DEBUG_LOG="debug.log"

if [ -z "$HELPER_BIN" ] || [ ! -f "$HELPER_BIN" ]  || [ -z "API_KEY" ]; then echo "Usage: $0 ./charcoal-helper API_KEY"; exit 1; fi

echo "id,timestamp,rtt_ms" > "$LATENCY_CSV"
echo "Starting Parallel WAN Stress Test ($NUM_REQUESTS requests)..."

# Use a temporary directory for parallel result tracking
TMP_DIR=$(mktemp -d)

run_task() {
    local id=$1
    local start_ns=$(date +%s%N)
    
    # We execute a single instance for this parallel test to measure connection setup + RTT
    local resp=$(echo "$id http://wan-${id}-test.com 1.2.3.4 - GET % 10.0.0.1 3128" | "$HELPER_BIN" -d "$API_KEY" &>>"$DEBUG_LOG")
    
    local end_ns=$(date +%s%N)
    local rtt_ms=$(echo "scale=3; ($end_ns - $start_ns) / 1000000" | bc -l)
    
    echo "$id,$(date +%H:%M:%S),$rtt_ms" >> "$TMP_DIR/res"
    printf "." # Progress dot
}

export -f run_task
export HELPER_BIN API_KEY DEBUG_LOG TMP_DIR

# Start Total Timer
start_total=$(date +%s%N)

for i in $(seq 1 $NUM_REQUESTS); do
    run_task "$i" &
    if (( i % CONCURRENCY == 0 )); then wait; fi
done
wait

end_total=$(date +%s%N)
cat "$TMP_DIR/res" >> "$LATENCY_CSV"
rm -rf "$TMP_DIR"

# Corrected Total Time Math
total_s=$(echo "scale=3; ($end_total - $start_total) / 1000000000" | bc -l)
throughput=$(echo "scale=2; $NUM_REQUESTS / $total_s" | bc -l)

# Stats
STATS=$(awk -F, 'NR>1 {if(min=="" || $3<min) min=$3; if($3>max) max=$3; sum+=$3; cnt++} 
    END {if(cnt>0) printf "%.3f %.3f %.3f", min, sum/cnt, max; else print "0 0 0"}' "$LATENCY_CSV")
read f_min f_avg f_max <<< "$STATS"

echo -e "\n--------------------------------------------------"
echo " WAN Parallel Summary (Concurrency: $CONCURRENCY)"
echo "   Total Time: ${total_s}s"
echo "   Throughput: $throughput req/sec"
echo "   Latency:    Min: ${f_min}ms | Avg: ${f_avg}ms | Max: ${f_max}ms"
echo "--------------------------------------------------"
