#!/usr/bin/env bash
set -uo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
export STATE=$WORK/state CALLS=$WORK/calls
mkdir -p "$STATE" "$WORK/bin"

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
    if [[ -f $STATE/instance && ! -f $STATE/nojoin ]]; then
      exit_node=false
      [[ -f $STATE/exit ]] && exit_node=true
      approved=true
      [[ -f $STATE/unapproved ]] && approved=false
      peers=$(jq -n --argjson e "$exit_node" --argjson a "$approved" \
        --arg h "$(cut -d' ' -f3 "$STATE/instance")" \
        '{k: {HostName: $h, TailscaleIPs: ["100.64.0.9"], ExitNode: $e, ExitNodeOption: $a}}')
    fi
    jq -n --argjson p "$peers" '{BackendState: "Running", Peer: $p}'
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
    echo '{"devices":[{"id":"d1","hostname":"hop-eu-west-2-beef","tags":["tag:hop"]},{"id":"d2","hostname":"laptop"},{"id":"d3","hostname":"hop-eu-west-2-beef","tags":["tag:other"]}]}'
    ;;
  *checkip*) echo 203.0.113.7 ;;
  *) echo '{}' ;;
esac
STUB

stub security <<'STUB'
#!/usr/bin/env bash
echo secret
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
out=$("$ROOT/hop" up eu-west-2 2>"$WORK/err")
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

: >"$CALLS"
"$ROOT/hop" up eu-west-2 >/dev/null 2>&1
refute "a second up reuses the running node" called "run-instances"

out=$("$ROOT/hop" status 2>/dev/null)
expect "status lists the node as in use" grep -qE "eu-west-2a +hop-eu-west-2-beef +203.0.113.7 +t4g.micro .* yes" <<<"$out"
expect "status --json is valid JSON" jq -e '.[0].in_use == true' <<<"$("$ROOT/hop" status --json 2>/dev/null)"

: >"$CALLS"
"$ROOT/hop" down >/dev/null 2>&1
expect "down stops routing first" called "tailscale set --exit-node="
expect "down terminates the instance" called "terminate-instances --region eu-west-2 --instance-ids i-abc"
expect "down deletes the tagged tailnet device" called "/device/d1"
refute "down leaves untagged devices alone" called "/device/d2"
refute "down leaves other tags alone" called "/device/d3"
expect "down deletes the security group" called "delete-security-group --region eu-west-2 --group-id sg-123"
expect "down leaves nothing behind" test ! -e "$STATE/instance" -a ! -e "$STATE/sg" -a ! -e "$STATE/exit"
expect "status reports nothing running" test "$("$ROOT/hop" status 2>/dev/null)" = "no nodes running"

reset
"$ROOT/hop" up eu-west-2 >/dev/null 2>&1
touch "$STATE/offline"
: >"$CALLS"
"$ROOT/hop" down >/dev/null 2>&1
expect "down stops routing even when AWS is unreachable" test ! -e "$STATE/exit"
touch "$STATE/exit"
"$ROOT/hop" down eu-west-2 >/dev/null 2>&1
expect "down by place stops routing even when AWS is unreachable" test ! -e "$STATE/exit"
touch "$STATE/exit"
"$ROOT/hop" down us-east-1 >/dev/null 2>&1
expect "down by place keeps routing through a node elsewhere" test -e "$STATE/exit"

reset
"$ROOT/hop" up eu-west-2 >/dev/null 2>&1
touch "$STATE/tsdown"
: >"$CALLS"
expect "status lists nodes while Tailscale is not running" grep -q hop-eu-west-2-beef <<<"$("$ROOT/hop" status 2>/dev/null)"
"$ROOT/hop" down >/dev/null 2>&1
expect "down destroys nodes while Tailscale is not running" test ! -e "$STATE/instance" -a ! -e "$STATE/sg"
"$ROOT/hop" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "up says when Tailscale is not running" grep -q "Tailscale is not running" "$WORK/err"
refute "up launches nothing while Tailscale is not running" called "run-instances"

reset
"$ROOT/hop" up eu-west-2 --ttl 2 >/dev/null 2>&1
expect "--ttl sets the self-destruct timer" grep -qF -- "--on-active=2h" "$STATE/userdata"
refute "--ttl rejects a non-number" "$ROOT/hop" up eu-west-2 --ttl soon

reset
HOP_MIN_MEMORY_MIB=1024 "$ROOT/hop" up eu-west-2 >/dev/null 2>&1
expect "a higher memory floor picks a larger type" called "--instance-type t4g.micro"

reset
"$ROOT/hop" up eu-west-2 --spot >/dev/null 2>&1
expect "--spot requests a spot instance" called "MarketType=spot"
expect "--spot picks the cheapest type and zone pair" called "--instance-type t4g.nano"
expect "--spot launches in the cheapest zone" called "--placement AvailabilityZone=eu-west-2b"
: >"$CALLS"
"$ROOT/hop" down >/dev/null 2>&1
"$ROOT/hop" up eu-west-2 >/dev/null 2>&1
refute "without --spot the launch is on demand" called "MarketType=spot"

reset
touch "$STATE/noprices"
"$ROOT/hop" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "without prices up falls back to the least memory" called "--instance-type t4g.nano"
expect "without prices up says so" grep -q "no prices" "$WORK/err"

reset
refute "up refuses a region that is not enabled" "$ROOT/hop" up ap-east-1
refute "a refused region launches nothing" called "run-instances"

reset
touch "$STATE/nojoin"
refute "up fails when the node never joins" "$ROOT/hop" up eu-west-2
expect "a node that never joins is terminated" called "terminate-instances"
expect "a node that never joins leaves no security group" test ! -e "$STATE/sg"

reset
touch "$STATE/unapproved"
"$ROOT/hop" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "an unapproved exit node names autoApprovers" grep -q autoApprovers "$WORK/err"
refute "an unapproved exit node is never routed through" called "tailscale set --exit-node=100"

reset
out=$("$ROOT/hop" up us-east-1-bue-1a 2>"$WORK/err")
expect "up in a Local Zone prints the zone" test "$out" = "hop-us-east-1-bue-1a-beef us-east-1-bue-1a 203.0.113.7"
expect "a Local Zone is enabled on first use" called "modify-availability-zone-group --region us-east-1 --group-name us-east-1-bue-1 --opt-in-status opted-in"
expect "a Local Zone gets its own subnet" called "create-subnet --region us-east-1 --vpc-id vpc-1 --availability-zone us-east-1-bue-1a --cidr-block 172.31.255.0/24"
expect "a Local Zone node gets a public IP in that subnet" called "SubnetId=subnet-z,Groups=sg-123,AssociatePublicIpAddress=true"
expect "a Local Zone gets the cheapest type it offers" called "--instance-type t3.medium"
expect "a Local Zone is priced under its group name" called "Field=regionCode,Value=us-east-1-bue-1 "
expect "a Local Zone node uses the x86 image" called "al2023-ami-kernel-default-x86_64"
: >"$CALLS"
"$ROOT/hop" up us-east-1 >/dev/null 2>&1
expect "a region launch does not reuse the Local Zone node" called "run-instances"
"$ROOT/hop" down us-east-1-bue-1a >/dev/null 2>&1
expect "down by zone name cleans the parent region" test ! -e "$STATE/instance" -a ! -e "$STATE/subnet" -a ! -e "$STATE/sg"
refute "an unknown zone is refused" "$ROOT/hop" up us-east-1-xyz-1a

reset
"$ROOT/hop" up us-east-1 >/dev/null 2>&1
: >"$CALLS"
refute "a failed up beside a running node fails" "$ROOT/hop" up us-east-1-xyz-1a
refute "a failed up leaves the running node alone" called "terminate-instances"
expect "a failed up leaves the running node's security group" test -e "$STATE/instance" -a -e "$STATE/sg" -a -e "$STATE/exit"

reset
touch "$STATE/novpc"
"$ROOT/hop" up eu-west-2 >/dev/null 2>"$WORK/err"
expect "a region without a default VPC says how to create one" grep -q create-default-vpc "$WORK/err"
refute "a region without a default VPC creates no security group" called "create-security-group"
refute "a region without a default VPC launches nothing" called "run-instances"

reset
"$ROOT/hop" up us-east-1-bue-1a --spot >/dev/null 2>"$WORK/err"
expect "--spot in a zone without spot prices is refused" grep -q "no spot prices" "$WORK/err"
refute "a refused --spot mints no auth key" called "tailnet/-/keys"
refute "a refused --spot launches nothing" called "run-instances"

reset
refute "a missing AWS profile is an error" env -u HOP_AWS_PROFILE "$ROOT/hop" regions
expect "doctor passes with everything in place" "$ROOT/hop" doctor
expect "doctor revokes its test key" called "-X DELETE"

echo
if ((failures)); then
  echo "$failures failed"
  exit 1
fi
echo "all passed"
