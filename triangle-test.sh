#!/bin/bash
# Map the full TB mesh + benchmark the mbp1<->mbp2 direct edge (the 3rd triangle side).
# Control plane uses the TB IPs themselves (pure TB, no Tailscale). Data plane is
# pinned to en6<->en6 by binding the sender's source address.
set -uo pipefail
KEY="$HOME/.ssh/tbtransfer_ed25519"
S=(-i "$KEY" -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o ConnectTimeout=6 -o BatchMode=yes -c aes128-gcm@openssh.com -o Compression=no)
MBP1=rd@169.254.204.227     # Studio<->mbp1 link IP (control)
MBP2=ray@169.254.10.220     # Studio<->mbp2 link IP (control)
MBP1_EN6=169.254.102.25     # mbp1 second TB iface
MBP2_EN6=169.254.47.184     # mbp2 second TB iface
PORT=9301
now(){ python3 -c 'import time;print(time.time())'; }
report(){ python3 - "$1" "$2" "$3" <<'PY'
import sys
name=sys.argv[1]; b=float(sys.argv[2]); s=float(sys.argv[3]); s=s if s>0 else 1e-9
print(f"  {name:34s} {b/1e9:6.2f} GB / {s:6.2f}s  =>  {b/s/1e9:5.2f} GB/s   {b*8/s/1e9:6.1f} Gbit/s")
PY
}
tbmap(){ # print iface -> ip / mac / peer for mtu-65518 ifaces
  for i in $(ifconfig -l); do
    ifconfig "$i" 2>/dev/null | grep -q 'mtu 65518' || continue
    ip=$(ifconfig "$i" | awk '/inet 169.254/{print $2}')
    mac=$(ifconfig "$i" | awk '/ether/{print $2}')
    [ -z "$ip" ] && continue
    peer=$(ndp -an 2>/dev/null | awk -v IF="$i" '$3==IF && $5!="permanent"{print $2}' | head -1)
    echo "   $i  ip=$ip  mac=${mac:-?}  ndp-peer=${peer:-none}"
  done
}

echo "================ TB MESH TOPOLOGY ================"
echo "STUDIO (local):"; tbmap
echo "mbp1:"; ssh "${S[@]}" "$MBP1" "$(declare -f tbmap); tbmap" 2>/dev/null
echo "mbp2:"; ssh "${S[@]}" "$MBP2" "$(declare -f tbmap); tbmap" 2>/dev/null
echo
echo "route mbp1->mbp2.en6 ($MBP2_EN6):"; ssh "${S[@]}" "$MBP1" "route -n get $MBP2_EN6 2>/dev/null | awk '/interface|gateway/{print \"   \"\$0}'" 2>/dev/null
echo "route mbp2->mbp1.en6 ($MBP1_EN6):"; ssh "${S[@]}" "$MBP2" "route -n get $MBP1_EN6 2>/dev/null | awk '/interface|gateway/{print \"   \"\$0}'" 2>/dev/null

echo
echo "================ GENERATE PAYLOADS (6 GiB each, parallel) ================"
ssh "${S[@]}" "$MBP1" '[ -f /tmp/tri_payload ] || dd if=/dev/urandom of=/tmp/tri_payload bs=1m count=6144 2>/dev/null; ls -lh /tmp/tri_payload|awk "{print \"   mbp1 \"\$5}"' 2>/dev/null &
ssh "${S[@]}" "$MBP2" '[ -f /tmp/tri_payload ] || dd if=/dev/urandom of=/tmp/tri_payload bs=1m count=6144 2>/dev/null; ls -lh /tmp/tri_payload|awk "{print \"   mbp2 \"\$5}"' 2>/dev/null &
wait

LISTENER='import sys,socket,time
bindip,port=sys.argv[1],int(sys.argv[2])
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1)
s.bind((bindip,port)); s.listen(1); s.settimeout(30)
c,_=s.accept(); c.settimeout(120)
t=time.time(); n=0
while True:
    b=c.recv(1<<22)
    if not b: break
    n+=len(b)
print(n, round(time.time()-t,4))'
SENDER='import sys,socket,os
srcip,dstip,port,path=sys.argv[1],sys.argv[2],int(sys.argv[3]),sys.argv[4]
s=socket.socket(); s.bind((srcip,0)); s.connect((dstip,port))
f=open(path,"rb"); sz=os.fstat(f.fileno()).st_size; off=0
while off<sz: off+=s.sendfile(f,off)
s.close()'

run_edge(){ # name  recv_node  recv_bindip  send_node  send_srcip  dst_ip
  local name=$1 rnode=$2 rip=$3 snode=$4 srcip=$5 dip=$6
  local out; out=$(mktemp)
  ssh "${S[@]}" "$rnode" "python3 - $rip $PORT" >"$out" 2>/dev/null <<<"$LISTENER" &
  local lpid=$!
  sleep 1.5
  ssh "${S[@]}" "$snode" "python3 - $srcip $dip $PORT /tmp/tri_payload" <<<"$SENDER" 2>/dev/null
  wait "$lpid" 2>/dev/null
  local N SS; read -r N SS < "$out"; rm -f "$out"
  [ -n "${N:-}" ] && report "$name" "$N" "$SS" || echo "  $name: FAILED (no direct path / bind error)"
}

echo
echo "================ mbp1 <-> mbp2 DIRECT EDGE (en6<->en6) ================"
run_edge "mbp1.en6 -> mbp2.en6" "$MBP2" "$MBP2_EN6" "$MBP1" "$MBP1_EN6" "$MBP2_EN6"
run_edge "mbp2.en6 -> mbp1.en6" "$MBP1" "$MBP1_EN6" "$MBP2" "$MBP2_EN6" "$MBP1_EN6"

echo
echo "================ CLEANUP ================"
ssh "${S[@]}" "$MBP1" 'rm -f /tmp/tri_payload' 2>/dev/null
ssh "${S[@]}" "$MBP2" 'rm -f /tmp/tri_payload' 2>/dev/null
echo "   done."
