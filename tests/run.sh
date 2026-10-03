#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'pkill -f "$WORK/hop watch" 2>/dev/null; rm -rf "$WORK"' EXIT
HOP=$WORK/hop
cp "$ROOT/hop" "$HOP"
export HOME=$WORK/home
export STATE=$WORK/state CALLS=$WORK/calls
mkdir -p "$STATE" "$WORK/bin" "$WORK/home"

stub() {
  cat >"$WORK/bin/$1"
  chmod +x "$WORK/bin/$1"
}

stub aws <<'STUB'
#!/usr/bin/env bash
echo "aws $*" >>"$CALLS"
[[ -f $STATE/offline ]] && exit 1
region=
args=("$@")
for ((i = 0; i < $#; i++)); do
  [[ ${args[i]} == --region ]] && region=${args[i + 1]}
done
case "$3 $4" in
  "sts get-caller-identity") echo '{}' ;;
  "ec2 describe-regions") printf 'us-east-1\teu-west-2\n' ;;
  "ec2 describe-instances")
    if [[ $* == *--instance-ids* ]]; then
      echo 203.0.113.7
    elif [[ $* == *shutting-down* ]]; then
      if [[ -f $STATE/dying && $region == eu-west-2 ]]; then echo '["i-dying"]'; else echo '[]'; fi
    elif [[ -f $STATE/instance && $region == "$(cut -d' ' -f1 "$STATE/instance")" ]]; then
      jq -n --arg zone "$(cut -d' ' -f2 "$STATE/instance")" --arg host "$(cut -d' ' -f3 "$STATE/instance")" \
        '[{id: "i-abc", ip: "203.0.113.7", type: "t4g.micro", launched: "2026-10-02T12:00:00+00:00", zone: $zone, host: $host}]'
    else
      echo '[]'
    fi
    ;;
  "ec2 describe-security-groups")
    if [[ -f $STATE/sg ]]; then echo sg-123; else echo None; fi
    ;;
  "ec2 describe-vpcs")
    if [[ -f $STATE/novpc ]]; then echo None; else printf 'vpc-1\t172.31.0.0/16\n'; fi
    ;;
  "ec2 describe-subnets")
    if [[ $* == *tag-key* ]]; then
      if [[ -f $STATE/subnet && $region == us-east-1 ]]; then echo '["subnet-z"]'; else echo '[]'; fi
    elif [[ -f $STATE/subnet ]]; then echo subnet-z; else echo None; fi
    ;;
  "ec2 create-subnet")
    if [[ -f $STATE/subnetdenied ]]; then
      echo "An error occurred (UnauthorizedOperation) when calling the CreateSubnet operation" >&2
      exit 254
    fi
    if [[ -f $STATE/subnettaken && $* == *172.31.255.0/24* ]]; then
      echo "An error occurred (InvalidSubnet.Conflict) when calling the CreateSubnet operation" >&2
      exit 254
    fi
    touch "$STATE/subnet"
    echo subnet-z
    ;;
  "ec2 describe-route-tables" | "ec2 describe-carrier-gateways") echo '[]' ;;
  "ec2 delete-subnet") rm -f "$STATE/subnet" ;;
  "ec2 describe-availability-zones")
    if [[ $* != *us-east-1-bue-1a* ]]; then
      echo None
    elif [[ -f $STATE/optedin ]]; then
      printf 'opted-in\tus-east-1-bue-1\tlocal-zone\n'
    else
      printf 'not-opted-in\tus-east-1-bue-1\tlocal-zone\n'
    fi
    ;;
  "ec2 modify-availability-zone-group") touch "$STATE/optedin" ;;
  "ec2 create-security-group")
    touch "$STATE/sg"
    echo sg-123
    ;;
  "ec2 describe-instance-type-offerings")
    if [[ $* == *availability-zone* ]]; then
      echo '["c5.large","t3.medium","g4dn.xlarge"]'
    else
      echo '["t3.micro","t4g.micro","t4g.nano","t3.nano","m7g.large"]'
    fi
    ;;
  "pricing get-products")
    [[ -f $STATE/noprices ]] && exit 1
    jq -n '{"t4g.nano": "0.0047", "t3.nano": "0.0059", "t4g.micro": "0.0094", "t3.micro": "0.0118", "m7g.large": "0.0900",
            "x9.nano": "0.0001", "c5.large": "0.2000", "t3.medium": "0.0773", "g4dn.xlarge": "0.9000", "t3.free": "0.0000"}
      | [to_entries[] | {product: {attributes: {instanceType: .key}},
                         terms: {OnDemand: {a: {priceDimensions: {b: {pricePerUnit: {USD: .value}}}}}}} | tojson]'
    ;;
  "ec2 describe-spot-price-history")
    echo '[{"type":"t4g.nano","az":"eu-west-2a","usd":"0.0030"},{"type":"t4g.nano","az":"eu-west-2b","usd":"0.0019"},
           {"type":"t3.nano","az":"eu-west-2a","usd":"0.0021"},{"type":"x9.nano","az":"eu-west-2a","usd":"0.0001"},
           {"type":"t3.nano","az":"eu-west-2-wl1-lon-wlz-1","usd":"0.0002"}]'
    ;;
  "ec2 describe-instance-types")
    cat <<'JSON'
[{"type":"g4dn.xlarge","memory":2048,"vcpus":4,"archs":["x86_64"],"gpu":{"Gpus":[]}},
 {"type":"m7g.large","memory":8192,"vcpus":2,"archs":["arm64"],"gpu":null},
 {"type":"c5.large","memory":4096,"vcpus":2,"archs":["x86_64"],"gpu":null},
 {"type":"t3.medium","memory":4096,"vcpus":2,"archs":["i386","x86_64"],"gpu":null},
 {"type":"t3.micro","memory":1024,"vcpus":2,"archs":["x86_64"],"gpu":null},
 {"type":"t3.nano","memory":512,"vcpus":2,"archs":["x86_64"],"gpu":null},
 {"type":"t4g.micro","memory":1024,"vcpus":2,"archs":["arm64"],"gpu":null},
 {"type":"t4g.nano","memory":512,"vcpus":2,"archs":["arm64"],"gpu":null},
 {"type":"x9.nano","memory":256,"vcpus":1,"archs":["arm64"],"gpu":null}]
JSON
    ;;
  "ec2 run-instances")
    if [[ -f $STATE/denied ]]; then
      echo "An error occurred (UnauthorizedOperation) when calling the RunInstances operation" >&2
      exit 254
    fi
    if [[ -f $STATE/nocapacity && $* == *"--instance-type t4g.nano"* ]]; then
      echo "An error occurred (InsufficientInstanceCapacity) when calling the RunInstances operation" >&2
      exit 254
    fi
    for a in "$@"; do
      [[ $a == file://* ]] && cp "${a#file://}" "$STATE/userdata"
    done
    zone=${region}a
    [[ $* == *SubnetId=subnet-z* ]] && zone=us-east-1-bue-1a
    host=$(sed -n 's/.*Key=Name,Value=\([^}]*\)}.*/\1/p' <<<"$*" | head -1)
    echo "$region $zone $host" >"$STATE/instance"
    echo i-abc
    ;;
  "ec2 terminate-instances") rm -f "$STATE/instance" ;;
  "ec2 delete-security-group") rm -f "$STATE/sg" ;;
  "ec2 get-console-output") echo "console tail" ;;
esac
STUB

stub tailscale <<'STUB'
#!/usr/bin/env bash
echo "tailscale $*" >>"$CALLS"
case "$1" in
  status)
    [[ -f $STATE/tsdown ]] && exit 1
    peers='{}'
    if [[ -s $STATE/instance && ! -f $STATE/nojoin ]]; then
      exit_node=false
      [[ -f $STATE/exit ]] && exit_node=true
      approved=true
      [[ -f $STATE/unapproved ]] && approved=false
      peers=$(jq -n --argjson e "$exit_node" --argjson a "$approved" \
        --arg h "$(cut -d' ' -f3 "$STATE/instance")" \
        '{k: {ID: "n1", HostName: $h, TailscaleIPs: ["100.64.0.9"], ExitNode: $e, ExitNodeOption: $a}}')
    fi
    exit_status=null
    if [[ -f $STATE/exit ]]; then
      alive=true
      [[ -f $STATE/nodedead ]] && alive=false
      exit_status=$(jq -n --argjson o "$alive" '{ID: "n1", Online: $o, TailscaleIPs: ["100.64.0.9/32"]}')
    fi
    jq -n --argjson p "$peers" --argjson x "$exit_status" \
      '{BackendState: "Running", Peer: $p} + (if $x then {ExitNodeStatus: $x} else {} end)'
    ;;
  ping)
    if [[ $* == *"--c 0"* ]]; then
      while [[ -d $STATE ]]; do
        if [[ -f $STATE/nodedead || -f $STATE/stall ]]; then echo 'ping "100.64.0.9" timed out'; else echo "pong from node (100.64.0.9) in 20ms"; fi
        /bin/sleep 0.1
      done
    elif [[ -f $STATE/nodedead ]]; then
      exit 1
    fi
    ;;
  set)
    if [[ $2 == --exit-node= ]]; then rm -f "$STATE/exit"; else touch "$STATE/exit"; fi
    ;;
esac
STUB

stub curl <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
[[ $* == *@-* ]] && cat >/dev/null
case "$*" in
  *oauth/token*) echo '{"access_token":"tok"}' ;;
  *"-X POST"*tailnet/-/keys*) echo '{"id":"k1","key":"tskey-auth-test"}' ;;
  *"-X GET"*tailnet/-/devices*)
    echo '{"devices":[{"id":"d1","hostname":"hop-eu-west-2-beef","tags":["tag:hop"]},{"id":"d2","hostname":"laptop"},{"id":"d3","hostname":"hop-eu-west-2-beef","tags":["tag:other"]},{"id":"d4","hostname":"hop-us-west-2-cafe","tags":["tag:hop"]}]}'
    ;;
  *captive.apple.com* | *checkip*)
    if [[ -f $STATE/nointernet ]]; then exit 7; fi
    if [[ -f $STATE/noegress && -f $STATE/exit ]]; then exit 7; fi
    if [[ -f $STATE/wrongip ]]; then echo 198.51.100.1; else echo 203.0.113.7; fi
    ;;
  *) echo '{}' ;;
esac
STUB

stub security <<'STUB'
#!/usr/bin/env bash
echo secret
STUB

stub launchctl <<STUB
#!/usr/bin/env bash
echo "launchctl \$*" >>"\$CALLS"
case "\$1" in
  print) pgrep -f "$WORK/hop watch" >/dev/null ;;
  bootstrap) nohup "$WORK/hop" watch >/dev/null 2>&1 & ;;
esac
STUB

stub osascript <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

stub openssl <<'STUB'
#!/usr/bin/env bash
echo beef
STUB

stub sleep <<'STUB'
#!/usr/bin/env bash
exit 0
STUB

export PATH=$WORK/bin:$PATH
export HOP_CONFIG=$WORK/none HOP_AWS_PROFILE=test HOP_JOIN_TIMEOUT=2 HOP_ZONE_TIMEOUT=2 HOP_POLL_INTERVAL=1
unset TS_OAUTH_CLIENT_ID TS_OAUTH_CLIENT_SECRET

failures=0
pass() { echo "ok    $1"; }
fail() {
  echo "FAIL  $1"
  failures=$((failures + 1))
}
expect() {
  if "${@:2}" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi
}
refute() {
  if "${@:2}" >/dev/null 2>&1; then fail "$1"; else pass "$1"; fi
}
called() { grep -qF -- "$1" "$CALLS"; }
count() { grep -cF -- "$1" "$CALLS"; }
reset() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  : >"$CALLS"
}

reset
out=$("$HOP" up eu-west-2 2>"$WORK/err")
expect "up prints host, region and IP" test "$out" = "hop-eu-west-2-beef eu-west-2 203.0.113.7"
expect "up launches with terminate-on-shutdown" called "--instance-initiated-shutdown-behavior terminate"
expect "up requires IMDSv2" called "--metadata-options HttpTokens=required"
expect "up picks the cheapest type with enough memory" called "--instance-type t4g.nano"
expect "up prices the region" called "Field=regionCode,Value=eu-west-2"
expect "up picks the image for that type's architecture" called "al2023-ami-kernel-default-arm64"
refute "up attaches no key pair" called "--key-name"
refute "up attaches no instance role" called "--iam-instance-profile"
expect "up opens only UDP 41641" called "IpProtocol=udp,FromPort=41641,ToPort=41641"
expect "user-data joins with the minted key" grep -qF -- "--auth-key=tskey-auth-test --hostname=hop-eu-west-2-beef --advertise-exit-node" "$STATE/userdata"
expect "user-data schedules the default TTL" grep -qF -- "--on-active=8h" "$STATE/userdata"
refute "the auth key never appears on a command line" called "tskey-auth-test"
refute "the OAuth secret never appears on a command line" called "secret"
expect "up routes through the node's tailnet IP" called "tailscale set --exit-node=100.64.0.9"
expect "up installs a launch agent that runs the watcher" grep -q "<string>$HOP</string>" "$HOME/Library/LaunchAgents/hop.watch.plist"
expect "up loads the launch agent" called "launchctl bootstrap gui/$UID $HOME/Library/LaunchAgents/hop.watch.plist"

: >"$CALLS"
"$HOP" up eu-west-2 >/dev/null 2>&1
refute "a second up reuses the running node" called "run-instances"
"$HOP" up eu-west-2 --ttl 2 --spot >/dev/null 2>"$WORK/err"
expect "a reused node says its flags were ignored" grep -qF -- "--ttl --spot only applies to a new node" "$WORK/err"

out=$("$HOP" status 2>/dev/null)
expect "status lists the node as in use" grep -qE "eu-west-2a +hop-eu-west-2-beef +203.0.113.7 +t4g.micro .* yes" <<<"$out"
expect "status --json is valid JSON" jq -e '.[0].in_use == true' <<<"$("$HOP" status --json 2>/dev/null)"

: >"$CALLS"
"$HOP" down >/dev/null 2>&1
expect "down stops routing first" called "tailscale set --exit-node="
expect "down terminates the instance" called "terminate-instances --region eu-west-2 --instance-ids i-abc"
expect "down deletes the tagged tailnet device" called "/device/d1"
refute "down leaves untagged devices alone" called "/device/d2"
refute "down leaves other tags alone" called "/device/d3"
expect "down removes the devices of nodes that died on their own" called "/device/d4"
expect "down looks for the security group by tag" called "describe-security-groups --region eu-west-2 --filters Name=group-name,Values=hop Name=tag-key,Values=hop"
expect "down deletes the security group" called "delete-security-group --region eu-west-2 --group-id sg-123"
expect "down leaves nothing behind" test ! -e "$STATE/instance" -a ! -e "$STATE/sg" -a ! -e "$STATE/exit"
expect "status reports nothing running" test "$("$HOP" status 2>/dev/null)" = "no nodes running"

reset
"$HOP" up eu-west-2 >/dev/null 2>&1
touch "$STATE/offline"
: >"$CALLS"
"$HOP" down >/dev/null 2>&1
expect "down stops routing even when AWS is unreachable" test ! -e "$STATE/exit"
refute "status fails when AWS is unreachable" "$HOP" status
refute "status does not claim nothing is running when AWS is unreachable" grep -q "no nodes running" <<<"$("$HOP" status 2>/dev/null)"
refute "zones fails when AWS is unreachable" "$HOP" zones
touch "$STATE/exit"
"$HOP" down eu-west-2 >/dev/null 2>&1
expect "down by place stops routing even when AWS is unreachable" test ! -e "$STATE/exit"
touch "$STATE/exit"
"$HOP" down us-east-1 >/dev/null 2>&1
expect "down by place keeps routing through a node elsewhere" test -e "$STATE/exit"
rm -f "$STATE/offline"
: >"$CALLS"
"$HOP" down us-east-1 >/dev/null 2>&1
refute "down by place leaves the devices of other regions" called "/device/d"
"$HOP" down us-west-2 >/dev/null 2>&1
expect "down by place removes that region's leftover devices" called "/device/d4"
refute "down by place removes only that region's devices" called "/device/d1"

reset
"$HOP" up eu-west-2 >/dev/null 2>&1
touch "$STATE/tsdown"
: >"$CALLS"
expect "status lists nodes while Tailscale is not running" grep -q hop-eu-west-2-beef <<<"$("$HOP" status 2>/dev/null)"
"$HOP" down >/dev/null 2>&1
expect "down destroys nodes while Tailscale is not running" test ! -e "$STATE/instance" -a ! -e "$STATE/sg"
"$HOP" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "up says when Tailscale is not running" grep -q "Tailscale is not running" "$WORK/err"
refute "up launches nothing while Tailscale is not running" called "run-instances"

reset
"$HOP" up eu-west-2 >/dev/null 2>&1
touch "$STATE/nodedead"
for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
  [[ -e $STATE/exit ]] || break
  /bin/sleep 0.5
done
expect "up leaves a watcher that stops routing when the node dies" test ! -e "$STATE/exit"
expect "a watcher that gave its node up removes the node's tailnet device" called "/device/d1"
refute "a watcher leaves other nodes' tailnet devices" called "/device/d4"
for _ in 1 2 3 4 5 6 7 8 9 10; do
  [[ -e $HOME/Library/LaunchAgents/hop.watch.plist ]] || break
  /bin/sleep 0.5
done
expect "a watcher with nothing left to watch removes its launch agent" test ! -e "$HOME/Library/LaunchAgents/hop.watch.plist"
expect "a watcher with nothing left to watch unloads itself" called "launchctl bootout gui/$UID/hop.watch"

watch_for() {
  : >"$CALLS"
  "$HOP" watch >/dev/null 2>&1 &
  watcher=$!
  /bin/sleep "$1"
}
stop_watcher() {
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
}

echo "eu-west-2 eu-west-2a laptop" >"$STATE/instance"
touch "$STATE/exit" "$STATE/nodedead"
watch_for 1
expect "a watcher leaves an exit node that is not a hop node" test -e "$STATE/exit"
refute "a watcher is not left running for an exit node that is not a hop node" kill -0 "$watcher"
stop_watcher

rm -f "$STATE/nodedead"
echo "eu-west-2 eu-west-2a hop-eu-west-2-beef" >"$STATE/instance"
touch "$STATE/exit" "$STATE/stall"
watch_for 2
rm -f "$STATE/stall"
/bin/sleep 1
expect "a watcher pings the node's tailnet address" called "tailscale ping --until-direct=false --c 0 --timeout 750ms 100.64.0.9"
expect "a watcher switches routing back on when the node answers after a stall" called "tailscale set --exit-node=100.64.0.9"
expect "a watcher keeps routing through a node that only stalled" test -e "$STATE/exit"
stop_watcher

touch "$STATE/exit" "$STATE/nodedead" "$STATE/nointernet"
watch_for 2
expect "a watcher switches routing back on when the internet is unreachable without the node" called "tailscale set --exit-node=100.64.0.9"
rm -f "$STATE/nointernet"
wait "$watcher"
expect "a watcher gives the node up once the internet is back and the node is not" test ! -e "$STATE/exit"

rm -f "$STATE/nodedead"
touch "$STATE/exit" "$STATE/noegress"
watch_for 0
wait "$watcher"
expect "a watcher gives up a node that answers pings but carries no traffic" test ! -e "$STATE/exit"

rm -f "$STATE/noegress" "$STATE/instance"
touch "$STATE/exit"
watch_for 0
wait "$watcher"
expect "a watcher stops routing through a node that left the tailnet" test ! -e "$STATE/exit"
touch "$STATE/exit"
"$HOP" down eu-west-2 >/dev/null 2>&1
expect "down stops routing through a node that left the tailnet" test ! -e "$STATE/exit"

reset
"$HOP" up eu-west-2 --ttl 2 >/dev/null 2>&1
expect "--ttl sets the self-destruct timer" grep -qF -- "--on-active=2h" "$STATE/userdata"
refute "--ttl rejects a non-number" "$HOP" up eu-west-2 --ttl soon

reset
HOP_MIN_MEMORY_MIB=1024 "$HOP" up eu-west-2 >/dev/null 2>&1
expect "a higher memory floor picks a larger type" called "--instance-type t4g.micro"

reset
"$HOP" up eu-west-2 --spot >/dev/null 2>&1
expect "--spot requests a spot instance" called "MarketType=spot"
expect "--spot picks the cheapest type and zone pair" called "--instance-type t4g.nano"
expect "--spot launches in the cheapest zone" called "--placement AvailabilityZone=eu-west-2b"
: >"$CALLS"
"$HOP" down >/dev/null 2>&1
"$HOP" up eu-west-2 >/dev/null 2>&1
refute "without --spot the launch is on demand" called "MarketType=spot"

reset
touch "$STATE/noprices"
"$HOP" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "without prices up falls back to the least memory" called "--instance-type t4g.nano"
expect "without prices up says so" grep -q "no prices" "$WORK/err"

reset
refute "up refuses a region that is not enabled" "$HOP" up ap-east-1
refute "a refused region launches nothing" called "run-instances"

reset
touch "$STATE/nojoin"
refute "up fails when the node never joins" "$HOP" up eu-west-2
expect "a node that never joins is terminated" called "terminate-instances"
expect "a node that never joins leaves no security group" test ! -e "$STATE/sg"

reset
touch "$STATE/wrongip"
refute "up fails when the public IP is not the node's" "$HOP" up eu-west-2
expect "a failed IP check switches routing back off" test ! -e "$STATE/exit"
expect "a failed IP check keeps the node" test -e "$STATE/instance"

reset
touch "$STATE/unapproved"
"$HOP" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "an unapproved exit node names autoApprovers" grep -q autoApprovers "$WORK/err"
refute "an unapproved exit node is never routed through" called "tailscale set --exit-node=100"

reset
out=$("$HOP" up us-east-1-bue-1a 2>"$WORK/err")
expect "up in a Local Zone prints the zone" test "$out" = "hop-us-east-1-bue-1a-beef us-east-1-bue-1a 203.0.113.7"
expect "a Local Zone is enabled on first use" called "modify-availability-zone-group --region us-east-1 --group-name us-east-1-bue-1 --opt-in-status opted-in"
expect "a Local Zone gets its own subnet" called "create-subnet --region us-east-1 --vpc-id vpc-1 --availability-zone us-east-1-bue-1a --cidr-block 172.31.255.0/24"
expect "a Local Zone node gets a public IP in that subnet" called "SubnetId=subnet-z,Groups=sg-123,AssociatePublicIpAddress=true"
expect "a Local Zone gets the cheapest type it offers" called "--instance-type t3.medium"
expect "a Local Zone is priced under its group name" called "Field=regionCode,Value=us-east-1-bue-1 "
expect "a Local Zone node uses the x86 image" called "al2023-ami-kernel-default-x86_64"
: >"$CALLS"
"$HOP" up us-east-1 >/dev/null 2>&1
expect "a region launch does not reuse the Local Zone node" called "run-instances"
"$HOP" down us-east-1-bue-1a >/dev/null 2>&1
expect "down by zone name cleans the parent region" test ! -e "$STATE/instance" -a ! -e "$STATE/subnet" -a ! -e "$STATE/sg"
refute "an unknown zone is refused" "$HOP" up us-east-1-xyz-1a

reset
"$HOP" up us-east-1 >/dev/null 2>&1
: >"$CALLS"
refute "a failed up beside a running node fails" "$HOP" up us-east-1-xyz-1a
refute "a failed up leaves the running node alone" called "terminate-instances"
expect "a failed up leaves the running node's security group" test -e "$STATE/instance" -a -e "$STATE/sg" -a -e "$STATE/exit"

reset
touch "$STATE/novpc"
"$HOP" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "a region without a default VPC says how to create one" grep -q create-default-vpc "$WORK/err"
refute "a region without a default VPC creates no security group" called "create-security-group"
refute "a region without a default VPC launches nothing" called "run-instances"

reset
"$HOP" up us-east-1-bue-1a --spot >/dev/null 2>"$WORK/err"
expect "--spot in a zone without spot prices is refused" grep -q "no spot prices" "$WORK/err"
refute "a refused --spot mints no auth key" called "tailnet/-/keys"
refute "a refused --spot launches nothing" called "run-instances"

reset
"$HOP" down us-gov-west-1 >/dev/null 2>&1
expect "a region with a four-part name is not taken for a zone" called "describe-instances --region us-gov-west-1"
"$HOP" down us-gov-west-1-xyz-1a >/dev/null 2>&1
refute "a zone of such a region resolves to it" called "--region us-gov-west "

reset
touch "$STATE/subnetdenied"
"$HOP" up us-east-1-bue-1a >/dev/null 2>"$WORK/err"
expect "a refused subnet shows the AWS error" grep -q "could not create a subnet.*UnauthorizedOperation" "$WORK/err"
expect "a refused subnet is not retried on other ranges" test "$(count create-subnet)" = 1

reset
touch "$STATE/subnettaken"
"$HOP" up us-east-1-bue-1a >/dev/null 2>&1
expect "a taken subnet range moves on to the next" called "--cidr-block 172.31.254.0/24"

reset
touch "$STATE/nocapacity"
"$HOP" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "no capacity moves on to the next cheapest type" called "--instance-type t3.nano"
expect "no capacity shows the AWS error" grep -q InsufficientInstanceCapacity "$WORK/err"

reset
touch "$STATE/denied"
refute "a launch AWS will not authorize fails" "$HOP" up eu-west-2
expect "a launch AWS will not authorize is tried once" test "$(count run-instances)" = 1
expect "a launch AWS will not authorize leaves no security group" test ! -e "$STATE/sg"

reset
touch "$STATE/dying" "$STATE/sg"
"$HOP" down eu-west-2 >/dev/null 2>&1
expect "down waits for a node that is still shutting down before deleting its security group" called "wait instance-terminated --region eu-west-2 --instance-ids i-dying"
expect "down then deletes the security group" test ! -e "$STATE/sg"

reset
refute "a missing AWS profile is an error" env -u HOP_AWS_PROFILE "$HOP" regions
expect "doctor passes with everything in place" "$HOP" doctor
expect "doctor revokes its test key" called "-X DELETE"

echo
if ((failures)); then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
