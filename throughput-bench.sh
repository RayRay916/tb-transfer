#!/bin/bash
# TB5 interconnect throughput benchmark for the 3-node cluster.
# Replicates TBTransfer.app's exact transfer mechanics:
#   - rsync 3.x, flags  -aWL --inplace --no-compress --partial
#   - SSH cipher aes128-gcm@openssh.com, Compression=no
#   - trusted-mode plain-TCP rsync --daemon on port 8730 (module "home" -> $HOME)
# Targets the link-local TB IPs directly so we measure the Thunderbolt link,
# NOT Tailscale/Wi-Fi.
set -uo pipefail

KEY="$HOME/.ssh/tbtransfer_ed25519"
RSYNC=/opt/homebrew/bin/rsync
SSHBASE=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new \
         -o ConnectTimeout=6 -o BatchMode=yes -c aes128-gcm@openssh.com \
         -o Compression=no -o ControlMaster=no)

PAYLOAD="/tmp/tb_bench_payload.bin"      # 12 GiB random, reused by all tests
PAYLOAD8="/tmp/tb_bench_payload8.bin"    # 8 GiB head (for the nearly-full mbp1 disk test)
SIZE_GIB=${SIZE_GIB:-12}

now()   { python3 -c 'import time;print(time.time())'; }

# report NAME BYTES SECS  -> pretty rate line
report() {
  python3 - "$1" "$2" "$3" <<'PY'
import sys
name=sys.argv[1]; b=float(sys.argv[2]); s=float(sys.argv[3])
if s<=0: s=1e-9
print(f"  {name:30s} {b/1e9:6.2f} GB / {s:6.2f}s  =>  {b/s/1e9:5.2f} GB/s   {b*8/s/1e9:6.1f} Gbit/s")
PY
}

gen_payload() {
  local bytes=$(( SIZE_GIB * 1024 ))   # MiB count
  if [ ! -f "$PAYLOAD" ] || [ "$(stat -f%z "$PAYLOAD" 2>/dev/null||echo 0)" -lt $(( SIZE_GIB*1073741824 )) ]; then
    echo "==> generating ${SIZE_GIB} GiB random payload (one-time)…"
    dd if=/dev/urandom of="$PAYLOAD" bs=1m count="$bytes" 2>/dev/null
  fi
  if [ ! -f "$PAYLOAD8" ]; then
    echo "==> carving 8 GiB head payload for mbp1 (disk-constrained)…"
    dd if="$PAYLOAD" of="$PAYLOAD8" bs=1m count=8192 2>/dev/null
  fi
  echo "    payload: $(ls -lh "$PAYLOAD" | awk '{print $5}')  /  head: $(ls -lh "$PAYLOAD8" | awk '{print $5}')"
}

# --- 1. raw TCP ceiling: sender sendfile -> peer python sink (/dev/null, no disk)
raw_tcp_test() {
  local label=$1 user=$2 ip=$3 port=$4 file=$5
  local out; out=$(mktemp)
  ssh "${SSHBASE[@]}" "$user@$ip" "python3 - $port" >"$out" 2>/dev/null <<'PY' &
import sys,socket,time
port=int(sys.argv[1])
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind(('0.0.0.0',port)); s.listen(1); s.settimeout(30)
c,_=s.accept(); c.settimeout(120)
t=time.time(); n=0
while True:
    b=c.recv(1<<22)
    if not b: break
    n+=len(b)
print(n, round(time.time()-t,4))
PY
  local lpid=$!
  sleep 1.5
  python3 - "$ip" "$port" "$file" <<'PY'
import sys,socket,os
ip,port,path=sys.argv[1],int(sys.argv[2]),sys.argv[3]
s=socket.create_connection((ip,port)); f=open(path,'rb')
sz=os.fstat(f.fileno()).st_size; off=0
while off<sz: off+=s.sendfile(f,off)
s.close()
PY
  wait "$lpid" 2>/dev/null
  local N SECS; read -r N SECS < "$out"; rm -f "$out"
  [ -n "${N:-}" ] && report "$label  raw-TCP (->/dev/null)" "$N" "$SECS" || echo "  $label  raw-TCP: FAILED"
}

# --- 2. encrypted path: file | ssh(aes128-gcm) 'cat>/dev/null' (no receiver disk)
ssh_pipe_test() {
  local label=$1 user=$2 ip=$3 file=$4
  local sz t0 t1
  sz=$(stat -f%z "$file")
  t0=$(now)
  ssh "${SSHBASE[@]}" "$user@$ip" 'cat > /dev/null' < "$file"
  t1=$(now)
  report "$label  ssh aes128-gcm pipe" "$sz" "$(python3 -c "print($t1-$t0)")"
}

# --- 3. trusted-mode rsync daemon (plain TCP, the app's real path) -> peer $HOME
daemon_test() {
  local label=$1 user=$2 ip=$3 port=$4 file=$5 recv="tb_bench_recv.bin"
  ssh "${SSHBASE[@]}" "$user@$ip" "bash -s" >/tmp/tb_daemon_${label}.log 2>&1 <<EOF &
set -e
CONF=\$(mktemp /tmp/tb_bench_rsyncd.XXXXXX.conf)
cat > "\$CONF" <<'CONF_EOF'
use chroot = no
read only = no
hosts allow = 169.254.0.0/16
hosts deny = *
max connections = 32
lock file = /tmp/tb_bench_rsyncd.lock
log file = /tmp/tb_bench_rsyncd.log
pid file = /tmp/tb_bench_rsyncd.pid
[home]
    path = HOMEPLACEHOLDER
    read only = no
    list = no
CONF_EOF
sed -i.bak "s|HOMEPLACEHOLDER|\$HOME|" "\$CONF" && rm -f "\$CONF.bak"
exec $RSYNC --daemon --no-detach --port $port --config "\$CONF" --address $ip
EOF
  local dpid=$!
  local up=0 i
  for i in $(seq 1 40); do nc -z -G 1 "$ip" "$port" 2>/dev/null && { up=1; break; }; sleep 0.2; done
  if [ "$up" != 1 ]; then echo "  $label  rsync-daemon: daemon never bound"; kill "$dpid" 2>/dev/null; cat /tmp/tb_daemon_${label}.log | sed 's/^/      /'; return; fi
  local sz t0 t1; sz=$(stat -f%z "$file")
  t0=$(now)
  "$RSYNC" -aWL --inplace --no-compress --partial "$file" "rsync://$ip:$port/home/$recv" >/dev/null 2>/tmp/tb_rsync_${label}.err
  local rc=$?; t1=$(now)
  if [ $rc -eq 0 ]; then report "$label  rsync-daemon (trusted)" "$sz" "$(python3 -c "print($t1-$t0)")"
  else echo "  $label  rsync-daemon: FAILED rc=$rc"; sed 's/^/      /' /tmp/tb_rsync_${label}.err; fi
  kill "$dpid" 2>/dev/null
  ssh "${SSHBASE[@]}" "$user@$ip" "rm -f ~/$recv /tmp/tb_bench_rsyncd.*" 2>/dev/null
}

echo "############################################################"
echo "# TB5 interconnect throughput  ($(date '+%Y-%m-%d %H:%M:%S'))"
echo "############################################################"
gen_payload

for spec in "mbp1|rd|169.254.204.227|en3|9101" "mbp2|ray|169.254.10.220|en4|9102"; do
  IFS='|' read -r L U IP IF PORT <<< "$spec"
  echo
  echo "=== $L  ($U@$IP via Studio $IF) ==="
  raw_tcp_test "$L" "$U" "$IP" "$PORT" "$PAYLOAD"
  ssh_pipe_test "$L" "$U" "$IP" "$PAYLOAD"
  if [ "$L" = "mbp1" ]; then daemon_test "$L" "$U" "$IP" 8730 "$PAYLOAD8"; else daemon_test "$L" "$U" "$IP" 8730 "$PAYLOAD"; fi
done

echo
echo "=== AGGREGATE: raw-TCP to BOTH links simultaneously (hub egress) ==="
A=$(mktemp); B=$(mktemp)
( raw_tcp_test "mbp1" "rd"  "169.254.204.227" 9201 "$PAYLOAD" ) >"$A" 2>&1 &
p1=$!
( raw_tcp_test "mbp2" "ray" "169.254.10.220"  9202 "$PAYLOAD" ) >"$B" 2>&1 &
p2=$!
wait $p1 $p2
cat "$A"; cat "$B"
python3 - "$A" "$B" <<'PY'
import sys,re
tot=0.0
for fn in sys.argv[1:]:
    s=open(fn).read()
    m=re.search(r'=>\s*([\d.]+)\s*GB/s', s)
    if m: tot+=float(m.group(1))
print(f"  {'AGGREGATE both links':30s} {'':17s}=>  {tot:5.2f} GB/s   {tot*8:6.1f} Gbit/s combined")
PY
rm -f "$A" "$B"
echo
echo "==> done. cleanup: rm -f $PAYLOAD $PAYLOAD8"
