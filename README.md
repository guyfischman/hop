# hop

An IP address in an AWS region, Local Zone or Wavelength Zone of your choice,
on demand. `hop up` launches the cheapest throwaway EC2 instance the place
offers, joins it to your tailnet as an exit node and routes this Mac through
it; `hop down` removes the instance, everything hop created around it, and
its tailnet device, along with the devices of nodes that died on their own.

```
hop up eu-west-2            # prints: <hostname> <region> <public ip>
hop up eu-west-2 --spot     # the same on spare capacity, at the spot price
hop status                  # running nodes, and which one is in use; --json for scripts
hop down                    # destroy every node; or: hop down eu-west-2
hop regions                 # regions the AWS account can launch in
hop zones                   # Local and Wavelength Zones under those regions
hop up us-east-1-bue-1a     # Buenos Aires (Local Zone)
hop up ca-central-1-wl1-yto-wlz-1   # Toronto (Wavelength Zone, Bell's network)
hop doctor                  # check tools, credentials and Tailscale access
```

A node destroys itself after 8 hours even if `down` never runs. Change that
per launch with `--ttl HOURS` or for good with `HOP_TTL_HOURS`.

Tailscale drops all traffic while its exit node is gone, so `hop up` leaves a
small watcher running on this Mac. It pings the node in use about once a
second. When two pings in a row go unanswered, because the node expired, was
reclaimed or was terminated, the watcher switches routing off, so the Mac is
back on its own connection and its own IP address within two or three
seconds. It then checks that the internet is reachable and the node still
does not answer: if so a notification says routing is off for good and the
node's tailnet device is removed, and if not, the fault was a stall or this Mac's own network, and routing through
the node is switched back on. The watcher ends when it has given the node up,
or when the Mac stops using that node. It does not survive a restart of the
Mac; `hop down` restores the connection then.

## Requirements

`aws` (v2), `tailscale`, `curl`, `jq` and `openssl` on the PATH, and Tailscale
running on this Mac. The script runs under the stock macOS bash.

## Setup

1. In the tailnet policy file, define the tag and let it approve itself as an
   exit node:

   ```json
   "tagOwners": {
     "tag:hop": [],
   },
   "autoApprovers": {
     "exitNode": ["tag:hop"],
   },
   ```

   Then keep the node out of the rest of the tailnet. Tailscale denies
   whatever no rule allows, but the default allow-all rule has `*` as its
   source, and `*` includes tagged devices. Give every rule a source that
   names people, not `*`, and add a test so the policy file refuses to save
   if a node could ever reach one of your machines:

   ```json
   "acls": [
     {"action": "accept", "src": ["autogroup:member"], "dst": ["*:*"]},
   ],
   "tests": [
     {"src": "tag:hop", "deny": ["<tailnet IP of one of your machines>:22"]},
   ],
   ```

2. Create a Tailscale OAuth client with the `auth_keys` and `devices:core`
   scopes (write), both restricted to `tag:hop`. Store it in the Keychain;
   each command prompts for the value:

   ```sh
   security add-generic-password -U -s hop -a ts-oauth-client-id -w
   security add-generic-password -U -s hop -a ts-oauth-client-secret -w
   ```

   `TS_OAUTH_CLIENT_ID` and `TS_OAUTH_CLIENT_SECRET` in the environment take
   precedence over the Keychain.

3. Name the AWS CLI profile to launch into, in `~/.config/hop/env`:

   ```sh
   HOP_AWS_PROFILE=personal
   ```

4. Run `hop doctor`.

## AWS permissions

The profile's identity needs these actions.

| For | Actions |
| --- | --- |
| Every launch | `ec2:RunInstances`, `TerminateInstances`, `CreateTags`, `DescribeInstances`, `DescribeRegions`, `DescribeVpcs`, `DescribeSubnets`, `DescribeRouteTables`, `DescribeCarrierGateways`, `DescribeSecurityGroups`, `CreateSecurityGroup`, `AuthorizeSecurityGroupIngress`, `DeleteSecurityGroup`, `GetConsoleOutput`; `ssm:GetParameters` on `arn:aws:ssm:*::parameter/aws/service/ami-amazon-linux-latest/*` |
| Choosing the cheapest type | `ec2:DescribeInstanceTypeOfferings`, `DescribeInstanceTypes`; `pricing:GetProducts`; for `--spot`, `ec2:DescribeSpotPriceHistory` |
| Local and Wavelength Zones | `ec2:DescribeAvailabilityZones`, `ModifyAvailabilityZoneGroup`, `CreateSubnet`, `DeleteSubnet` |
| Wavelength Zones only | `ec2:CreateCarrierGateway`, `DeleteCarrierGateway`, `CreateRouteTable`, `CreateRoute`, `AssociateRouteTable`, `DeleteRouteTable` |

The region needs a default VPC. Opt-in regions must be enabled on the account
before `hop regions` lists them.

## What a node is

The cheapest instance the target offers, running the current Amazon Linux
2023 image, with no key pair, no instance role, IMDSv2 only, and a security
group that admits UDP 41641 and nothing else. hop keeps
no state on disk: a node is any instance carrying the `hop` tag.

At launch hop asks AWS which instance types the region or zone offers and
what each costs per hour right now, and launches the cheapest with at least
`HOP_MIN_MEMORY_MIB` (default 512). If that launch fails for lack of
capacity it tries the next cheapest. Nothing about sizes or prices is stored
in hop. The node adds a swap file before installing Tailscale, because the
package install does not fit in 0.5 GB of memory on its own.

With `--spot` the ranking uses current spot prices, per availability zone,
and the node is a one-time spot instance in the cheapest zone. AWS can
reclaim a spot instance at two minutes' notice; if that happens while this
Mac is routed through it, the watcher puts the Mac back on its own
connection. The
Buenos Aires and Toronto zones have no spot prices, so `--spot` is refused
there.

If on-demand prices can't be read, hop says so and falls back to the least
memory.

## Zones

Countries without a full region are often covered by a zone attached to one.
`hop up <zone>` enables the zone on the account the first time (a few
minutes), creates a small subnet for it in the parent region's default VPC,
and `hop down <zone>` removes the subnet again along with every node in that
parent region. The zone stays enabled on the account.

Zones offer few instance sizes, often nothing below `t3.medium`, and the
small ones can be out of capacity, so hop moves on to the next cheapest. The
launch line and `hop status` show the size you got.

A Wavelength Zone sits inside a mobile carrier's network. The node reaches
the internet through a carrier gateway, websites see the carrier's address
and not an Amazon one, and nothing on the internet can connect in, so
Tailscale relays the traffic and it is slower than a direct connection.

## Tests

```sh
tests/run.sh
```

The suite replaces `aws`, `tailscale`, `curl` and `security` with stubs, so it
launches nothing and needs no credentials.
